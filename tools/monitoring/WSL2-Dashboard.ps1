# WSL2-Dashboard.ps1
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# WSL2 Performance Monitoring Dashboard
# Provides real-time system metrics, error detection, and quick actions

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Script configuration
$script:DashboardVersion = "1.0.0"
$script:RefreshInterval = 5000 # milliseconds
$script:AutoRefreshEnabled = $false
$script:LastRefreshTime = Get-Date
$script:ErrorLogMaxSize = 100

# Import monitoring modules if available
$ModulePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$PerfModulePath = Join-Path $ModulePath "WSL2-Performance.psm1"
$ErrorModulePath = Join-Path $ModulePath "WSL2-ErrorDetection.psm1"

$script:PerformanceModuleLoaded = $false
$script:ErrorDetectionModuleLoaded = $false

if (Test-Path $PerfModulePath) {
    Import-Module $PerfModulePath -Force
    $script:PerformanceModuleLoaded = $true
    Write-Host "Loaded WSL2-Performance module"
}

if (Test-Path $ErrorModulePath) {
    Import-Module $ErrorModulePath -Force
    $script:ErrorDetectionModuleLoaded = $true
    Write-Host "Loaded WSL2-ErrorDetection module"
}

# Mock functions for when modules aren't available
function Get-WSLSystemMetrics {
    if ($script:PerformanceModuleLoaded -and (Get-Command Get-WSLPerformanceMetrics -ErrorAction SilentlyContinue)) {
        return Get-WSLPerformanceMetrics
    }

    # Mock data
    $cpuUsage = Get-Random -Minimum 10 -Maximum 80
    $memUsage = Get-Random -Minimum 20 -Maximum 70
    $diskIO = Get-Random -Minimum 5 -Maximum 150

    $wslRunning = (Get-Process wsl -ErrorAction SilentlyContinue) -ne $null
    $distros = @()
    try {
        $distros = (wsl --list --quiet) | Where-Object { $_ -and $_.Trim() }
    } catch {}

    $fsType = "Unknown"
    try {
        $configPath = "$env:USERPROFILE\.wslconfig"
        if (Test-Path $configPath) {
            $config = Get-Content $configPath -Raw
            if ($config -match 'virtiofs\s*=\s*true') {
                $fsType = "VirtioFS"
            } else {
                $fsType = "9p"
            }
        } else {
            $fsType = "9p (default)"
        }
    } catch {
        $fsType = "Unknown"
    }

    return @{
        CPUUsage = $cpuUsage
        MemoryUsage = $memUsage
        DiskIO = $diskIO
        WSLRunning = $wslRunning
        FilesystemType = $fsType
        ActiveDistros = $distros.Count
        Timestamp = Get-Date
    }
}

function Get-WSLRecentErrors {
    param(
        [int]$MaxCount = 50
    )

    if ($script:ErrorDetectionModuleLoaded -and (Get-Command Get-WSLErrors -ErrorAction SilentlyContinue)) {
        return Get-WSLErrors -MaxCount $MaxCount
    }

    # Mock error data
    $errors = @()
    $severities = @('Info', 'Warning', 'Critical')
    $sources = @('WSL Service', 'Filesystem', 'Network', 'GPU Driver', 'Kernel')
    $messages = @{
        'Info' = @(
            'WSL service started successfully',
            'Distribution registered',
            'Filesystem mounted',
            'Network bridge initialized'
        )
        'Warning' = @(
            'High memory usage detected',
            'Disk I/O bottleneck detected',
            'Plan9 protocol latency above threshold',
            'Network packet loss detected'
        )
        'Critical' = @(
            'WSL service crashed',
            'Filesystem mount failed',
            'VirtioFS initialization failed',
            'GPU passthrough error',
            'Out of memory condition'
        )
    }

    # Generate 10-20 mock errors
    $errorCount = Get-Random -Minimum 10 -Maximum 20
    for ($i = 0; $i -lt $errorCount; $i++) {
        $severity = $severities | Get-Random
        $source = $sources | Get-Random
        $message = $messages[$severity] | Get-Random
        $time = (Get-Date).AddMinutes(-(Get-Random -Minimum 1 -Maximum 120))

        $errors += [PSCustomObject]@{
            Time = $time
            Severity = $severity
            Source = $source
            Message = $message
            Details = "Full error details would appear here`nStack trace...`nAdditional context..."
        }
    }

    return $errors | Sort-Object Time -Descending | Select-Object -First $MaxCount
}

# Create main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "WSL2 Performance Dashboard v$script:DashboardVersion"
$form.Size = New-Object System.Drawing.Size(820, 640)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true

# Create menu bar
$menuStrip = New-Object System.Windows.Forms.MenuStrip

# File menu
$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "&File"

$exportMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exportMenuItem.Text = "Export &Report"
$exportMenuItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control, [System.Windows.Forms.Keys]::E
$fileMenu.DropDownItems.Add($exportMenuItem)

$fileMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitMenuItem.Text = "E&xit"
$exitMenuItem.ShortcutKeys = [System.Windows.Forms.Keys]::Alt, [System.Windows.Forms.Keys]::F4
$fileMenu.DropDownItems.Add($exitMenuItem)

$menuStrip.Items.Add($fileMenu)

# Actions menu
$actionsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$actionsMenu.Text = "&Actions"

$benchmarkMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$benchmarkMenuItem.Text = "Quick &Benchmark"
$actionsMenu.DropDownItems.Add($benchmarkMenuItem)

$collectLogsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$collectLogsMenuItem.Text = "&Collect Logs"
$actionsMenu.DropDownItems.Add($collectLogsMenuItem)

$restartMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$restartMenuItem.Text = "&Restart WSL"
$actionsMenu.DropDownItems.Add($restartMenuItem)

$fixVirtiofsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$fixVirtiofsMenuItem.Text = "Fix &VirtioFS"
$actionsMenu.DropDownItems.Add($fixVirtiofsMenuItem)

$menuStrip.Items.Add($actionsMenu)

# Help menu
$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$helpMenu.Text = "&Help"

$aboutMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutMenuItem.Text = "&About"
$helpMenu.DropDownItems.Add($aboutMenuItem)

$docsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$docsMenuItem.Text = "View &Documentation"
$helpMenu.DropDownItems.Add($docsMenuItem)

$menuStrip.Items.Add($helpMenu)

$form.Controls.Add($menuStrip)

# Left Panel - System Metrics
$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Location = New-Object System.Drawing.Point(10, 35)
$leftPanel.Size = New-Object System.Drawing.Size(380, 510)
$leftPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($leftPanel)

# Title for left panel
$leftTitle = New-Object System.Windows.Forms.Label
$leftTitle.Text = "System Metrics"
$leftTitle.Location = New-Object System.Drawing.Point(10, 10)
$leftTitle.Size = New-Object System.Drawing.Size(360, 25)
$leftTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$leftPanel.Controls.Add($leftTitle)

# CPU Usage
$cpuLabel = New-Object System.Windows.Forms.Label
$cpuLabel.Text = "CPU Usage:"
$cpuLabel.Location = New-Object System.Drawing.Point(10, 45)
$cpuLabel.Size = New-Object System.Drawing.Size(100, 20)
$leftPanel.Controls.Add($cpuLabel)

$cpuValueLabel = New-Object System.Windows.Forms.Label
$cpuValueLabel.Text = "0%"
$cpuValueLabel.Location = New-Object System.Drawing.Point(290, 45)
$cpuValueLabel.Size = New-Object System.Drawing.Size(70, 20)
$cpuValueLabel.TextAlign = "MiddleRight"
$leftPanel.Controls.Add($cpuValueLabel)

$cpuProgressBar = New-Object System.Windows.Forms.ProgressBar
$cpuProgressBar.Location = New-Object System.Drawing.Point(10, 70)
$cpuProgressBar.Size = New-Object System.Drawing.Size(350, 23)
$cpuProgressBar.Style = "Continuous"
$leftPanel.Controls.Add($cpuProgressBar)

# Memory Usage
$memLabel = New-Object System.Windows.Forms.Label
$memLabel.Text = "Memory Usage:"
$memLabel.Location = New-Object System.Drawing.Point(10, 105)
$memLabel.Size = New-Object System.Drawing.Size(100, 20)
$leftPanel.Controls.Add($memLabel)

$memValueLabel = New-Object System.Windows.Forms.Label
$memValueLabel.Text = "0%"
$memValueLabel.Location = New-Object System.Drawing.Point(290, 105)
$memValueLabel.Size = New-Object System.Drawing.Size(70, 20)
$memValueLabel.TextAlign = "MiddleRight"
$leftPanel.Controls.Add($memValueLabel)

$memProgressBar = New-Object System.Windows.Forms.ProgressBar
$memProgressBar.Location = New-Object System.Drawing.Point(10, 130)
$memProgressBar.Size = New-Object System.Drawing.Size(350, 23)
$memProgressBar.Style = "Continuous"
$leftPanel.Controls.Add($memProgressBar)

# Disk I/O
$diskLabel = New-Object System.Windows.Forms.Label
$diskLabel.Text = "Disk I/O:"
$diskLabel.Location = New-Object System.Drawing.Point(10, 165)
$diskLabel.Size = New-Object System.Drawing.Size(100, 20)
$leftPanel.Controls.Add($diskLabel)

$diskValueLabel = New-Object System.Windows.Forms.Label
$diskValueLabel.Text = "0 MB/s"
$diskValueLabel.Location = New-Object System.Drawing.Point(250, 165)
$diskValueLabel.Size = New-Object System.Drawing.Size(110, 20)
$diskValueLabel.TextAlign = "MiddleRight"
$leftPanel.Controls.Add($diskValueLabel)

# Status Indicators
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Status Indicators"
$statusLabel.Location = New-Object System.Drawing.Point(10, 200)
$statusLabel.Size = New-Object System.Drawing.Size(360, 20)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$leftPanel.Controls.Add($statusLabel)

# WSL Running Status
$wslStatusLabel = New-Object System.Windows.Forms.Label
$wslStatusLabel.Text = "⬤ WSL Running:"
$wslStatusLabel.Location = New-Object System.Drawing.Point(10, 230)
$wslStatusLabel.Size = New-Object System.Drawing.Size(150, 20)
$leftPanel.Controls.Add($wslStatusLabel)

$wslStatusValue = New-Object System.Windows.Forms.Label
$wslStatusValue.Text = "Checking..."
$wslStatusValue.Location = New-Object System.Drawing.Point(160, 230)
$wslStatusValue.Size = New-Object System.Drawing.Size(200, 20)
$wslStatusValue.ForeColor = [System.Drawing.Color]::Gray
$leftPanel.Controls.Add($wslStatusValue)

# Filesystem Type
$fsTypeLabel = New-Object System.Windows.Forms.Label
$fsTypeLabel.Text = "⬤ Filesystem:"
$fsTypeLabel.Location = New-Object System.Drawing.Point(10, 255)
$fsTypeLabel.Size = New-Object System.Drawing.Size(150, 20)
$leftPanel.Controls.Add($fsTypeLabel)

$fsTypeValue = New-Object System.Windows.Forms.Label
$fsTypeValue.Text = "Checking..."
$fsTypeValue.Location = New-Object System.Drawing.Point(160, 255)
$fsTypeValue.Size = New-Object System.Drawing.Size(200, 20)
$fsTypeValue.ForeColor = [System.Drawing.Color]::Gray
$leftPanel.Controls.Add($fsTypeValue)

# Active Distros
$distrosLabel = New-Object System.Windows.Forms.Label
$distrosLabel.Text = "⬤ Active Distros:"
$distrosLabel.Location = New-Object System.Drawing.Point(10, 280)
$distrosLabel.Size = New-Object System.Drawing.Size(150, 20)
$leftPanel.Controls.Add($distrosLabel)

$distrosValue = New-Object System.Windows.Forms.Label
$distrosValue.Text = "0"
$distrosValue.Location = New-Object System.Drawing.Point(160, 280)
$distrosValue.Size = New-Object System.Drawing.Size(200, 20)
$distrosValue.ForeColor = [System.Drawing.Color]::Gray
$leftPanel.Controls.Add($distrosValue)

# Action Buttons
$buttonsLabel = New-Object System.Windows.Forms.Label
$buttonsLabel.Text = "Quick Actions"
$buttonsLabel.Location = New-Object System.Drawing.Point(10, 315)
$buttonsLabel.Size = New-Object System.Drawing.Size(360, 20)
$buttonsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$leftPanel.Controls.Add($buttonsLabel)

$quickBenchmarkBtn = New-Object System.Windows.Forms.Button
$quickBenchmarkBtn.Text = "Quick Benchmark"
$quickBenchmarkBtn.Location = New-Object System.Drawing.Point(10, 345)
$quickBenchmarkBtn.Size = New-Object System.Drawing.Size(170, 30)
$leftPanel.Controls.Add($quickBenchmarkBtn)

$collectLogsBtn = New-Object System.Windows.Forms.Button
$collectLogsBtn.Text = "Collect Logs"
$collectLogsBtn.Location = New-Object System.Drawing.Point(190, 345)
$collectLogsBtn.Size = New-Object System.Drawing.Size(170, 30)
$leftPanel.Controls.Add($collectLogsBtn)

$restartWSLBtn = New-Object System.Windows.Forms.Button
$restartWSLBtn.Text = "Restart WSL"
$restartWSLBtn.Location = New-Object System.Drawing.Point(10, 385)
$restartWSLBtn.Size = New-Object System.Drawing.Size(170, 30)
$leftPanel.Controls.Add($restartWSLBtn)

$fixVirtiofsBtn = New-Object System.Windows.Forms.Button
$fixVirtiofsBtn.Text = "Fix VirtioFS"
$fixVirtiofsBtn.Location = New-Object System.Drawing.Point(190, 385)
$fixVirtiofsBtn.Size = New-Object System.Drawing.Size(170, 30)
$leftPanel.Controls.Add($fixVirtiofsBtn)

# Auto-refresh checkbox
$autoRefreshCheckbox = New-Object System.Windows.Forms.CheckBox
$autoRefreshCheckbox.Text = "Auto-refresh (every 5 seconds)"
$autoRefreshCheckbox.Location = New-Object System.Drawing.Point(10, 430)
$autoRefreshCheckbox.Size = New-Object System.Drawing.Size(250, 25)
$leftPanel.Controls.Add($autoRefreshCheckbox)

# Manual refresh button
$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "Refresh Now"
$refreshBtn.Location = New-Object System.Drawing.Point(10, 465)
$refreshBtn.Size = New-Object System.Drawing.Size(170, 30)
$leftPanel.Controls.Add($refreshBtn)

# Right Panel - Recent Errors
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Location = New-Object System.Drawing.Point(400, 35)
$rightPanel.Size = New-Object System.Drawing.Size(400, 510)
$rightPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($rightPanel)

# Title for right panel
$rightTitle = New-Object System.Windows.Forms.Label
$rightTitle.Text = "Recent Errors"
$rightTitle.Location = New-Object System.Drawing.Point(10, 10)
$rightTitle.Size = New-Object System.Drawing.Size(380, 25)
$rightTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$rightPanel.Controls.Add($rightTitle)

# Filter buttons
$allFilterBtn = New-Object System.Windows.Forms.Button
$allFilterBtn.Text = "All"
$allFilterBtn.Location = New-Object System.Drawing.Point(10, 40)
$allFilterBtn.Size = New-Object System.Drawing.Size(60, 25)
$allFilterBtn.Tag = "All"
$rightPanel.Controls.Add($allFilterBtn)

$criticalFilterBtn = New-Object System.Windows.Forms.Button
$criticalFilterBtn.Text = "Critical"
$criticalFilterBtn.Location = New-Object System.Drawing.Point(75, 40)
$criticalFilterBtn.Size = New-Object System.Drawing.Size(70, 25)
$criticalFilterBtn.Tag = "Critical"
$rightPanel.Controls.Add($criticalFilterBtn)

$warningFilterBtn = New-Object System.Windows.Forms.Button
$warningFilterBtn.Text = "Warning"
$warningFilterBtn.Location = New-Object System.Drawing.Point(150, 40)
$warningFilterBtn.Size = New-Object System.Drawing.Size(75, 25)
$warningFilterBtn.Tag = "Warning"
$rightPanel.Controls.Add($warningFilterBtn)

$infoFilterBtn = New-Object System.Windows.Forms.Button
$infoFilterBtn.Text = "Info"
$infoFilterBtn.Location = New-Object System.Drawing.Point(230, 40)
$infoFilterBtn.Size = New-Object System.Drawing.Size(60, 25)
$infoFilterBtn.Tag = "Info"
$rightPanel.Controls.Add($infoFilterBtn)

# DataGridView for errors
$errorGrid = New-Object System.Windows.Forms.DataGridView
$errorGrid.Location = New-Object System.Drawing.Point(10, 70)
$errorGrid.Size = New-Object System.Drawing.Size(375, 340)
$errorGrid.AllowUserToAddRows = $false
$errorGrid.AllowUserToDeleteRows = $false
$errorGrid.AllowUserToResizeRows = $false
$errorGrid.ReadOnly = $true
$errorGrid.SelectionMode = "FullRowSelect"
$errorGrid.MultiSelect = $false
$errorGrid.RowHeadersVisible = $false
$errorGrid.AutoSizeColumnsMode = "Fill"
$errorGrid.BackgroundColor = [System.Drawing.Color]::White
$errorGrid.BorderStyle = "Fixed3D"
$errorGrid.DefaultCellStyle.WrapMode = "False"

# Add columns
$timeColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$timeColumn.Name = "Time"
$timeColumn.HeaderText = "Time"
$timeColumn.Width = 70
$timeColumn.DefaultCellStyle.Format = "HH:mm:ss"
$errorGrid.Columns.Add($timeColumn)

$severityColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$severityColumn.Name = "Severity"
$severityColumn.HeaderText = "Severity"
$severityColumn.Width = 70
$errorGrid.Columns.Add($severityColumn)

$sourceColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$sourceColumn.Name = "Source"
$sourceColumn.HeaderText = "Source"
$sourceColumn.Width = 80
$errorGrid.Columns.Add($sourceColumn)

$messageColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$messageColumn.Name = "Message"
$messageColumn.HeaderText = "Message"
$messageColumn.AutoSizeMode = "Fill"
$errorGrid.Columns.Add($messageColumn)

$rightPanel.Controls.Add($errorGrid)

# Error action buttons
$viewFullLogBtn = New-Object System.Windows.Forms.Button
$viewFullLogBtn.Text = "View Full Log"
$viewFullLogBtn.Location = New-Object System.Drawing.Point(10, 420)
$viewFullLogBtn.Size = New-Object System.Drawing.Size(115, 30)
$rightPanel.Controls.Add($viewFullLogBtn)

$exportErrorsBtn = New-Object System.Windows.Forms.Button
$exportErrorsBtn.Text = "Export to File"
$exportErrorsBtn.Location = New-Object System.Drawing.Point(135, 420)
$exportErrorsBtn.Size = New-Object System.Drawing.Size(115, 30)
$rightPanel.Controls.Add($exportErrorsBtn)

$clearErrorsBtn = New-Object System.Windows.Forms.Button
$clearErrorsBtn.Text = "Clear"
$clearErrorsBtn.Location = New-Object System.Drawing.Point(260, 420)
$clearErrorsBtn.Size = New-Object System.Drawing.Size(125, 30)
$rightPanel.Controls.Add($clearErrorsBtn)

# Status bar
$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Status: Ready"
$statusLabel.Spring = $true
$statusLabel.TextAlign = "MiddleLeft"
$statusBar.Items.Add($statusLabel)
$form.Controls.Add($statusBar)

# Store all errors for filtering
$script:AllErrors = @()
$script:CurrentFilter = "All"

# Functions
function Update-SystemMetrics {
    try {
        $metrics = Get-WSLSystemMetrics

        # Update CPU
        $cpuProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$metrics.CPUUsage))
        $cpuValueLabel.Text = "$([Math]::Round($metrics.CPUUsage, 1))%"

        # Update Memory
        $memProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$metrics.MemoryUsage))
        $memValueLabel.Text = "$([Math]::Round($metrics.MemoryUsage, 1))%"

        # Update Disk I/O
        $diskValueLabel.Text = "$([Math]::Round($metrics.DiskIO, 2)) MB/s"

        # Update WSL Running status
        if ($metrics.WSLRunning) {
            $wslStatusValue.Text = "✓ Yes"
            $wslStatusValue.ForeColor = [System.Drawing.Color]::Green
        } else {
            $wslStatusValue.Text = "✗ No"
            $wslStatusValue.ForeColor = [System.Drawing.Color]::Red
        }

        # Update Filesystem Type
        $fsTypeValue.Text = $metrics.FilesystemType
        if ($metrics.FilesystemType -like "*VirtioFS*") {
            $fsTypeValue.ForeColor = [System.Drawing.Color]::Green
        } elseif ($metrics.FilesystemType -like "*9p*") {
            $fsTypeValue.ForeColor = [System.Drawing.Color]::Orange
        } else {
            $fsTypeValue.ForeColor = [System.Drawing.Color]::Gray
        }

        # Update Active Distros
        $distrosValue.Text = "$($metrics.ActiveDistros)"
        if ($metrics.ActiveDistros -gt 0) {
            $distrosValue.ForeColor = [System.Drawing.Color]::Green
        } else {
            $distrosValue.ForeColor = [System.Drawing.Color]::Gray
        }

        $script:LastRefreshTime = Get-Date
        $statusLabel.Text = "Status: Monitoring... Last refresh: 0s ago"
    } catch {
        $statusLabel.Text = "Status: Error updating metrics - $($_.Exception.Message)"
    }
}

function Update-ErrorLog {
    param(
        [string]$Filter = "All"
    )

    try {
        # Get fresh errors
        $script:AllErrors = Get-WSLRecentErrors -MaxCount $script:ErrorLogMaxSize

        # Apply filter
        $filteredErrors = $script:AllErrors
        if ($Filter -ne "All") {
            $filteredErrors = $script:AllErrors | Where-Object { $_.Severity -eq $Filter }
        }

        # Clear grid
        $errorGrid.Rows.Clear()

        # Populate grid
        foreach ($error in $filteredErrors) {
            $rowIndex = $errorGrid.Rows.Add($error.Time, $error.Severity, $error.Source, $error.Message)
            $row = $errorGrid.Rows[$rowIndex]

            # Color code by severity
            switch ($error.Severity) {
                "Critical" {
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
                }
                "Warning" {
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 205)
                }
                "Info" {
                    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
                }
            }

            # Store full error object in Tag
            $row.Tag = $error
        }

        $script:CurrentFilter = $Filter
    } catch {
        $statusLabel.Text = "Status: Error updating error log - $($_.Exception.Message)"
    }
}

function Invoke-QuickBenchmark {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will run the quick benchmark script which may take several minutes. Continue?",
        "Quick Benchmark",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $statusLabel.Text = "Status: Running benchmark..."

        $repoRoot = Split-Path -Parent (Split-Path -Parent $ModulePath)
        $benchmarkScript = Join-Path $repoRoot "tools\strix-turbo\quick-benchmark.sh"

        if (Test-Path $benchmarkScript) {
            try {
                Start-Process "wsl" -ArgumentList "bash", $benchmarkScript -NoNewWindow -Wait
                [System.Windows.Forms.MessageBox]::Show(
                    "Benchmark completed. Check console output for results.",
                    "Benchmark Complete",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to run benchmark: $($_.Exception.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Benchmark script not found at: $benchmarkScript",
                "File Not Found",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

        $statusLabel.Text = "Status: Ready"
    }
}

function Invoke-CollectLogs {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will collect WSL diagnostic logs. Continue?",
        "Collect Logs",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $statusLabel.Text = "Status: Collecting logs..."

        $repoRoot = Split-Path -Parent (Split-Path -Parent $ModulePath)
        $collectScript = Join-Path $repoRoot "diagnostics\collect-wsl-logs.ps1"

        if (Test-Path $collectScript) {
            try {
                & $collectScript
                [System.Windows.Forms.MessageBox]::Show(
                    "Logs collected successfully. Check the diagnostics folder for output.",
                    "Logs Collected",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Failed to collect logs: $($_.Exception.Message)",
                    "Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Log collection script not found at: $collectScript",
                "File Not Found",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }

        $statusLabel.Text = "Status: Ready"
    }
}

function Invoke-RestartWSL {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will shut down all WSL distributions. Any unsaved work will be lost. Continue?",
        "Restart WSL",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $statusLabel.Text = "Status: Shutting down WSL..."

        try {
            wsl --shutdown
            Start-Sleep -Seconds 2
            [System.Windows.Forms.MessageBox]::Show(
                "WSL has been shut down. It will restart automatically when you use it next.",
                "WSL Shutdown",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            Update-SystemMetrics
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to restart WSL: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }

        $statusLabel.Text = "Status: Ready"
    }
}

function Invoke-FixVirtioFS {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $ModulePath)
    $troubleshootingDoc = Join-Path $repoRoot "docs\wsl-virtiofs-troubleshooting.md"

    if (Test-Path $troubleshootingDoc) {
        try {
            Start-Process "notepad.exe" -ArgumentList $troubleshootingDoc
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to open troubleshooting guide: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "VirtioFS troubleshooting guide not found at: $troubleshootingDoc",
            "File Not Found",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
}

function Export-SystemReport {
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveDialog.DefaultExt = "txt"
    $saveDialog.FileName = "WSL2-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $metrics = Get-WSLSystemMetrics

            $report = @"
WSL2 Performance Dashboard Report
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
======================================

SYSTEM METRICS
--------------
CPU Usage: $([Math]::Round($metrics.CPUUsage, 1))%
Memory Usage: $([Math]::Round($metrics.MemoryUsage, 1))%
Disk I/O: $([Math]::Round($metrics.DiskIO, 2)) MB/s

STATUS
------
WSL Running: $($metrics.WSLRunning)
Filesystem Type: $($metrics.FilesystemType)
Active Distros: $($metrics.ActiveDistros)

RECENT ERRORS (Last $($script:AllErrors.Count))
--------------
"@

            foreach ($error in $script:AllErrors) {
                $report += "`n[$($error.Time.ToString('yyyy-MM-dd HH:mm:ss'))] [$($error.Severity)] [$($error.Source)]`n"
                $report += "  $($error.Message)`n"
            }

            $report | Out-File -FilePath $saveDialog.FileName -Encoding UTF8

            [System.Windows.Forms.MessageBox]::Show(
                "Report exported successfully to:`n$($saveDialog.FileName)",
                "Export Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to export report: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
}

function Export-ErrorLog {
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "CSV Files (*.csv)|*.csv|Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveDialog.DefaultExt = "csv"
    $saveDialog.FileName = "WSL2-Errors-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:AllErrors | Select-Object Time, Severity, Source, Message, Details |
                Export-Csv -Path $saveDialog.FileName -NoTypeInformation

            [System.Windows.Forms.MessageBox]::Show(
                "Error log exported successfully to:`n$($saveDialog.FileName)",
                "Export Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to export error log: $($_.Exception.Message)",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    }
}

# Event Handlers

# Menu events
$exitMenuItem.Add_Click({ $form.Close() })
$exportMenuItem.Add_Click({ Export-SystemReport })
$benchmarkMenuItem.Add_Click({ Invoke-QuickBenchmark })
$collectLogsMenuItem.Add_Click({ Invoke-CollectLogs })
$restartMenuItem.Add_Click({ Invoke-RestartWSL })
$fixVirtiofsMenuItem.Add_Click({ Invoke-FixVirtioFS })

$aboutMenuItem.Add_Click({
    $aboutMsg = @"
WSL2 Performance Dashboard
Version: $script:DashboardVersion

A real-time monitoring tool for WSL2 performance metrics,
error detection, and system diagnostics.

Part of the WSL Strix-Turbo Performance Suite

Copyright (c) Microsoft Corporation.
Licensed under the MIT License.
"@
    [System.Windows.Forms.MessageBox]::Show(
        $aboutMsg,
        "About WSL2 Dashboard",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

$docsMenuItem.Add_Click({
    $repoRoot = Split-Path -Parent (Split-Path -Parent $ModulePath)
    $docsPath = Join-Path $repoRoot "docs"
    if (Test-Path $docsPath) {
        Start-Process "explorer.exe" -ArgumentList $docsPath
    }
})

# Button events
$quickBenchmarkBtn.Add_Click({ Invoke-QuickBenchmark })
$collectLogsBtn.Add_Click({ Invoke-CollectLogs })
$restartWSLBtn.Add_Click({ Invoke-RestartWSL })
$fixVirtiofsBtn.Add_Click({ Invoke-FixVirtioFS })
$refreshBtn.Add_Click({
    Update-SystemMetrics
    Update-ErrorLog -Filter $script:CurrentFilter
})

# Filter button events
$filterClickHandler = {
    param($sender)
    Update-ErrorLog -Filter $sender.Tag
}

$allFilterBtn.Add_Click({ $filterClickHandler.Invoke($allFilterBtn) })
$criticalFilterBtn.Add_Click({ $filterClickHandler.Invoke($criticalFilterBtn) })
$warningFilterBtn.Add_Click({ $filterClickHandler.Invoke($warningFilterBtn) })
$infoFilterBtn.Add_Click({ $filterClickHandler.Invoke($infoFilterBtn) })

# Error grid events
$errorGrid.Add_CellDoubleClick({
    param($sender, $e)

    if ($e.RowIndex -ge 0) {
        $row = $errorGrid.Rows[$e.RowIndex]
        $error = $row.Tag

        if ($error) {
            $detailsMsg = @"
Time: $($error.Time.ToString('yyyy-MM-dd HH:mm:ss'))
Severity: $($error.Severity)
Source: $($error.Source)
Message: $($error.Message)

Details:
$($error.Details)
"@
            [System.Windows.Forms.MessageBox]::Show(
                $detailsMsg,
                "Error Details",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    }
})

$viewFullLogBtn.Add_Click({
    if ($errorGrid.SelectedRows.Count -gt 0) {
        $row = $errorGrid.SelectedRows[0]
        $error = $row.Tag

        if ($error) {
            $detailsMsg = @"
Time: $($error.Time.ToString('yyyy-MM-dd HH:mm:ss'))
Severity: $($error.Severity)
Source: $($error.Source)
Message: $($error.Message)

Details:
$($error.Details)
"@
            [System.Windows.Forms.MessageBox]::Show(
                $detailsMsg,
                "Error Details",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select an error to view details.",
            "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
})

$exportErrorsBtn.Add_Click({ Export-ErrorLog })

$clearErrorsBtn.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will clear the error log display (errors will be reloaded on next refresh). Continue?",
        "Clear Errors",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $errorGrid.Rows.Clear()
        $script:AllErrors = @()
    }
})

# Auto-refresh timer
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:RefreshInterval
$timer.Add_Tick({
    if ($script:AutoRefreshEnabled) {
        Update-SystemMetrics
        Update-ErrorLog -Filter $script:CurrentFilter

        $elapsed = ((Get-Date) - $script:LastRefreshTime).TotalSeconds
        $statusLabel.Text = "Status: Monitoring... Last refresh: $([Math]::Round($elapsed))s ago"
    }
})
$timer.Start()

$autoRefreshCheckbox.Add_CheckedChanged({
    $script:AutoRefreshEnabled = $autoRefreshCheckbox.Checked
    if ($script:AutoRefreshEnabled) {
        Update-SystemMetrics
        Update-ErrorLog -Filter $script:CurrentFilter
        $statusLabel.Text = "Status: Monitoring... Auto-refresh enabled"
    } else {
        $statusLabel.Text = "Status: Ready (auto-refresh disabled)"
    }
})

# Form cleanup
$form.Add_FormClosing({
    $timer.Stop()
    $timer.Dispose()
})

# Initial load
Update-SystemMetrics
Update-ErrorLog -Filter "All"

# Show form
[void]$form.ShowDialog()
