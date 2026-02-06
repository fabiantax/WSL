#Requires -Version 5.1

<#
.SYNOPSIS
    Balanced WSL2 Tray Monitor - Lightweight background monitoring with on-demand details.

.DESCRIPTION
    Background monitoring (10s interval):
      - Process metrics only (CPU%, Memory MB, Count)
      - Tray icon color updates
      - Tooltip with basic stats

    On-demand details (user clicks):
      - Fresh distro list
      - Virtiofs status
      - Event log errors
      - Actionable buttons

.NOTES
    Performance targets:
      - Background CPU: < 0.5%
      - Background Memory: < 10 MB
      - Startup: < 2 seconds
      - On-demand load: < 3 seconds
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ========== Configuration ==========
$script:Config = @{
    BackgroundIntervalMs = 10000  # 10 seconds for lightweight process checks
    ProcessNames = @('wsl', 'wslservice', 'wslhost', 'wslrelay', 'vmmem')
    EventLogHours = 24
    EventLogMaxErrors = 10
}

# ========== State Management ==========
$script:State = @{
    Metrics = @{
        CpuPercent = 0
        MemoryMB = 0
        ProcessCount = 0
        Status = "Initializing"
        LastUpdate = Get-Date
    }
    Dashboard = $null
    DashboardData = $null
}

# ========== Tray Icon & Context Menu ==========
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Text = "WSL2 Monitor - Initializing..."
$script:TrayIcon.Visible = $true

# Create context menu
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$menuRefresh = $contextMenu.Items.Add("Refresh Now")
$menuRefresh.Add_Click({ Update-BackgroundMetrics -Force })

$contextMenu.Items.Add("-")  # Separator

$menuDistros = $contextMenu.Items.Add("View Distros")
$menuDistros.Add_Click({ Show-DistroList })

$menuErrors = $contextMenu.Items.Add("Check Errors")
$menuErrors.Add_Click({ Show-ErrorList })

$contextMenu.Items.Add("-")  # Separator

$menuRestart = $contextMenu.Items.Add("Restart WSL")
$menuRestart.Add_Click({ Restart-WSL })

$menuLogs = $contextMenu.Items.Add("Collect Logs")
$menuLogs.Add_Click({ Collect-DiagnosticLogs })

$contextMenu.Items.Add("-")  # Separator

$menuExit = $contextMenu.Items.Add("Exit")
$menuExit.Add_Click({ Exit-Monitor })

$script:TrayIcon.ContextMenuStrip = $contextMenu

# Left-click opens dashboard
$script:TrayIcon.Add_Click({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-Dashboard
    }
})

# ========== Icon Generation ==========
function New-StatusIcon {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Green', 'Yellow', 'Red', 'Gray')]
        [string]$Color
    )

    $bitmap = New-Object System.Drawing.Bitmap(16, 16)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $colorMap = @{
        'Green'  = [System.Drawing.Color]::LimeGreen
        'Yellow' = [System.Drawing.Color]::Gold
        'Red'    = [System.Drawing.Color]::OrangeRed
        'Gray'   = [System.Drawing.Color]::Gray
    }

    $brush = New-Object System.Drawing.SolidBrush($colorMap[$Color])
    $graphics.FillEllipse($brush, 2, 2, 12, 12)

    $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())

    $graphics.Dispose()
    $brush.Dispose()

    return $icon
}

# ========== Background Monitoring (Lightweight) ==========
function Update-BackgroundMetrics {
    param([switch]$Force)

    try {
        # Fast: Only query process metrics
        $wslProcesses = Get-Process -Name $script:Config.ProcessNames -ErrorAction SilentlyContinue

        if ($wslProcesses) {
            $totalCpu = ($wslProcesses | Measure-Object -Property CPU -Sum).Sum
            $totalMemoryMB = [math]::Round(($wslProcesses | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB, 0)
            $processCount = $wslProcesses.Count

            # Simple CPU calculation (average over last interval)
            $cpuPercent = [math]::Round($totalCpu / $processCount, 1)

            $script:State.Metrics.CpuPercent = $cpuPercent
            $script:State.Metrics.MemoryMB = $totalMemoryMB
            $script:State.Metrics.ProcessCount = $processCount
            $script:State.Metrics.Status = "Running"
        } else {
            $script:State.Metrics.CpuPercent = 0
            $script:State.Metrics.MemoryMB = 0
            $script:State.Metrics.ProcessCount = 0
            $script:State.Metrics.Status = "Stopped"
        }

        $script:State.Metrics.LastUpdate = Get-Date

        # Update tray icon and tooltip
        Update-TrayIcon

    } catch {
        $script:State.Metrics.Status = "Error"
        $script:TrayIcon.Icon = New-StatusIcon -Color Gray
        $script:TrayIcon.Text = "WSL2 Monitor - Error: $($_.Exception.Message)"
    }
}

function Update-TrayIcon {
    $metrics = $script:State.Metrics

    # Determine icon color based on status and metrics
    $iconColor = switch ($metrics.Status) {
        "Running" {
            if ($metrics.CpuPercent -gt 50 -or $metrics.MemoryMB -gt 8192) { "Yellow" }
            elseif ($metrics.CpuPercent -gt 80 -or $metrics.MemoryMB -gt 16384) { "Red" }
            else { "Green" }
        }
        "Stopped" { "Gray" }
        default { "Gray" }
    }

    $script:TrayIcon.Icon = New-StatusIcon -Color $iconColor

    # Update tooltip with basic metrics
    $tooltip = @"
WSL2 Monitor
Status: [$iconColor] $($metrics.Status)
CPU: $($metrics.CpuPercent)%
Memory: $($metrics.MemoryMB) MB
Processes: $($metrics.ProcessCount)

Click for details...
"@

    $script:TrayIcon.Text = $tooltip
}

# ========== On-Demand Data Loading ==========
function Get-DistroList {
    try {
        $output = wsl --list --verbose 2>&1 | Out-String

        # Parse distro information
        $distros = @()
        $lines = $output -split "`n" | Select-Object -Skip 1

        foreach ($line in $lines) {
            if ($line -match '^\s*([*]?)\s*(\S+)\s+(Stopped|Running)\s+(\d+)') {
                $distros += [PSCustomObject]@{
                    Default = $matches[1] -eq '*'
                    Name = $matches[2]
                    State = $matches[3]
                    Version = $matches[4]
                }
            }
        }

        return $distros
    } catch {
        return @([PSCustomObject]@{
            Name = "Error"
            State = $_.Exception.Message
            Version = "N/A"
            Default = $false
        })
    }
}

function Get-VirtiofsStatus {
    try {
        # Check if virtiofs is mounted
        $mountOutput = wsl -e bash -c "mount | grep -i virtiofs" 2>$null

        if ($mountOutput) {
            return "YES"
        } else {
            return "NO (Plan9)"
        }
    } catch {
        return "Unknown"
    }
}

function Get-RecentErrors {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            ProviderName = 'WSL'
            Level = 2  # Error
            StartTime = (Get-Date).AddHours(-$script:Config.EventLogHours)
        } -MaxEvents $script:Config.EventLogMaxErrors -ErrorAction SilentlyContinue

        if ($events) {
            return $events | ForEach-Object {
                [PSCustomObject]@{
                    Time = $_.TimeCreated
                    Message = $_.Message
                    Id = $_.Id
                }
            }
        } else {
            return @([PSCustomObject]@{
                Time = Get-Date
                Message = "No errors in last $($script:Config.EventLogHours) hours"
                Id = 0
            })
        }
    } catch {
        return @([PSCustomObject]@{
            Time = Get-Date
            Message = "Unable to query event log: $($_.Exception.Message)"
            Id = -1
        })
    }
}

function Load-DashboardData {
    # Show loading state
    $script:State.DashboardData = @{
        Loading = $true
        Distros = @()
        Virtiofs = "Loading..."
        Errors = @()
    }

    # Load data asynchronously (but still blocking for simplicity)
    $script:State.DashboardData.Distros = Get-DistroList
    $script:State.DashboardData.Virtiofs = Get-VirtiofsStatus
    $script:State.DashboardData.Errors = Get-RecentErrors
    $script:State.DashboardData.Loading = $false
}

# ========== Dashboard Window ==========
function Show-Dashboard {
    if ($script:State.Dashboard -and -not $script:State.Dashboard.IsDisposed) {
        $script:State.Dashboard.BringToFront()
        $script:State.Dashboard.Activate()
        return
    }

    # Create dashboard form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WSL2 Performance Dashboard"
    $form.Size = New-Object System.Drawing.Size(600, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Main text box
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ScrollBars = "Vertical"
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $textBox.Location = New-Object System.Drawing.Point(10, 10)
    $textBox.Size = New-Object System.Drawing.Size(560, 380)
    $textBox.ReadOnly = $true
    $textBox.Text = "Loading dashboard data..."
    $form.Controls.Add($textBox)

    # Button panel
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Location = New-Object System.Drawing.Point(10, 400)
    $buttonPanel.Size = New-Object System.Drawing.Size(560, 40)
    $buttonPanel.FlowDirection = "LeftToRight"
    $form.Controls.Add($buttonPanel)

    # Restart WSL button
    $btnRestart = New-Object System.Windows.Forms.Button
    $btnRestart.Text = "Restart WSL"
    $btnRestart.Size = New-Object System.Drawing.Size(110, 30)
    $btnRestart.Add_Click({
        Restart-WSL
        Start-Sleep -Seconds 2
        Refresh-Dashboard
    })
    $buttonPanel.Controls.Add($btnRestart)

    # Collect Logs button
    $btnLogs = New-Object System.Windows.Forms.Button
    $btnLogs.Text = "Collect Logs"
    $btnLogs.Size = New-Object System.Drawing.Size(110, 30)
    $btnLogs.Add_Click({ Collect-DiagnosticLogs })
    $buttonPanel.Controls.Add($btnLogs)

    # Quick Benchmark button
    $btnBenchmark = New-Object System.Windows.Forms.Button
    $btnBenchmark.Text = "Quick Benchmark"
    $btnBenchmark.Size = New-Object System.Drawing.Size(120, 30)
    $btnBenchmark.Add_Click({ Run-QuickBenchmark })
    $buttonPanel.Controls.Add($btnBenchmark)

    # Refresh button
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"
    $btnRefresh.Size = New-Object System.Drawing.Size(80, 30)
    $btnRefresh.Add_Click({ Refresh-Dashboard })
    $buttonPanel.Controls.Add($btnRefresh)

    # Close button
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Size = New-Object System.Drawing.Size(80, 30)
    $btnClose.Add_Click({ $form.Close() })
    $buttonPanel.Controls.Add($btnClose)

    $script:State.Dashboard = $form

    # Load data and update display
    $form.Add_Shown({
        Refresh-Dashboard
    })

    $form.ShowDialog()
}

function Refresh-Dashboard {
    if (-not $script:State.Dashboard -or $script:State.Dashboard.IsDisposed) {
        return
    }

    $textBox = $script:State.Dashboard.Controls[0]
    $textBox.Text = "Loading fresh data...`r`n"
    $textBox.Refresh()

    # Load fresh data
    Load-DashboardData

    # Build dashboard content
    $metrics = $script:State.Metrics
    $data = $script:State.DashboardData

    $content = @"
=== WSL2 Performance Dashboard ===

Current Metrics:
  CPU: $($metrics.CpuPercent)%
  Memory: $($metrics.MemoryMB) MB
  Processes: $($metrics.ProcessCount)
  Status: $($metrics.Status)
  Last Update: $($metrics.LastUpdate.ToString('HH:mm:ss'))

Distros:
"@

    foreach ($distro in $data.Distros) {
        $icon = if ($distro.State -eq "Running") { "✓" } else { "○" }
        $default = if ($distro.Default) { " (Default)" } else { "" }
        $content += "`r`n  $icon $($distro.Name) ($($distro.State), WSL$($distro.Version))$default"
    }

    $content += "`r`n`r`nFilesystem: VirtioFS [$($data.Virtiofs)]"

    $content += "`r`n`r`nRecent Errors:"
    if ($data.Errors.Count -gt 0 -and $data.Errors[0].Id -eq 0) {
        $content += "`r`n  None in last $($script:Config.EventLogHours) hours"
    } else {
        foreach ($error in $data.Errors | Select-Object -First 5) {
            $content += "`r`n  [$($error.Time.ToString('HH:mm:ss'))] $($error.Message.Substring(0, [Math]::Min(80, $error.Message.Length)))"
        }
    }

    $textBox.Text = $content
}

# ========== Action Handlers ==========
function Show-DistroList {
    $distros = Get-DistroList

    $message = "WSL Distributions:`r`n`r`n"
    foreach ($distro in $distros) {
        $icon = if ($distro.State -eq "Running") { "✓" } else { "○" }
        $default = if ($distro.Default) { " (Default)" } else { "" }
        $message += "$icon $($distro.Name) - $($distro.State) - WSL$($distro.Version)$default`r`n"
    }

    [System.Windows.Forms.MessageBox]::Show($message, "WSL Distributions", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Show-ErrorList {
    $errors = Get-RecentErrors

    $message = "Recent WSL Errors (Last $($script:Config.EventLogHours) hours):`r`n`r`n"

    if ($errors[0].Id -eq 0) {
        $message += $errors[0].Message
    } else {
        foreach ($error in $errors | Select-Object -First 5) {
            $message += "[$($error.Time.ToString('yyyy-MM-dd HH:mm:ss'))]`r`n$($error.Message)`r`n`r`n"
        }
    }

    [System.Windows.Forms.MessageBox]::Show($message, "Recent Errors", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Restart-WSL {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will shut down all WSL distributions. Continue?",
        "Restart WSL",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            wsl --shutdown
            [System.Windows.Forms.MessageBox]::Show("WSL has been shut down. It will restart automatically when needed.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error shutting down WSL: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
}

function Collect-DiagnosticLogs {
    $scriptPath = Join-Path $PSScriptRoot "..\..\diagnostics\collect-wsl-logs.ps1"

    if (Test-Path $scriptPath) {
        try {
            Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-File `"$scriptPath`"" -Verb RunAs
            [System.Windows.Forms.MessageBox]::Show("Diagnostic log collection started in new window.", "Logs", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error starting log collection: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Diagnostic script not found at: $scriptPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function Run-QuickBenchmark {
    $benchmarkPath = Join-Path $PSScriptRoot "..\strix-turbo\benchmark-suite.sh"

    if (Test-Path $benchmarkPath) {
        try {
            Start-Process wsl -ArgumentList "-e", "bash", "`"$benchmarkPath`"", "--quick"
            [System.Windows.Forms.MessageBox]::Show("Quick benchmark started in WSL terminal.", "Benchmark", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error starting benchmark: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Benchmark script not found at: $benchmarkPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function Exit-Monitor {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Exit WSL2 Monitor?",
        "Confirm Exit",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:TrayIcon.Visible = $false
        $script:TrayIcon.Dispose()

        if ($script:State.Dashboard -and -not $script:State.Dashboard.IsDisposed) {
            $script:State.Dashboard.Close()
        }

        [System.Windows.Forms.Application]::Exit()
    }
}

# ========== Background Timer ==========
$script:BackgroundTimer = New-Object System.Windows.Forms.Timer
$script:BackgroundTimer.Interval = $script:Config.BackgroundIntervalMs
$script:BackgroundTimer.Add_Tick({ Update-BackgroundMetrics })
$script:BackgroundTimer.Start()

# ========== Initialization ==========
Write-Host "Starting WSL2 Tray Monitor (Balanced Edition)..."
Write-Host "Background monitoring: Every $($script:Config.BackgroundIntervalMs / 1000) seconds"
Write-Host "On-demand details: Click tray icon for dashboard"

# Initial metrics update
Update-BackgroundMetrics -Force

# Start application loop
[System.Windows.Forms.Application]::Run()
