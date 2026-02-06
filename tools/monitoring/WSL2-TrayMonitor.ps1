<#
.SYNOPSIS
    WSL2 System Tray Monitor for Strix Halo performance tracking

.DESCRIPTION
    Windows Forms system tray application that monitors WSL2 performance metrics,
    displays status icons, provides quick actions, and sends critical notifications.

    PERFORMANCE OPTIMIZATIONS:
    - Caching: Expensive operations (WSL calls, Event Log queries, WMI) are cached
    - WSL subprocess calls: Cached for 30 seconds (distro list)
    - Event Log queries: Cached for 60 seconds (error detection)
    - VirtioFS status: Cached for 60 seconds
    - Process queries: Cached for 5 seconds (CPU/memory metrics)
    - Total memory: Cached for 5 minutes (rarely changes)
    - Background monitoring: Reduced from 5s to 10s default refresh
    - Error log viewing: On-demand only (not automatic on tooltip hover)
    - Dashboard refresh: Forces fresh error data when explicitly opened

.PARAMETER StartMinimized
    Start the application minimized to system tray without showing dashboard

.EXAMPLE
    .\WSL2-TrayMonitor.ps1
    Start monitor with dashboard visible

.EXAMPLE
    .\WSL2-TrayMonitor.ps1 -StartMinimized
    Start monitor minimized to tray only

.EXAMPLE
    powershell.exe -STA -ExecutionPolicy Bypass -File .\WSL2-TrayMonitor.ps1
    Recommended launch method with STA mode enforcement

.NOTES
    Requires: Windows 10/11, PowerShell 5.1+, WSL2
    Auto-imports: WSL2-Performance.psm1, WSL2-ErrorDetection.psm1

    IMPORTANT: This script works best with Windows PowerShell 5.1
    PowerShell 7+ may experience PipelineStoppedException and other compatibility issues
    with Windows Forms controls. The script will offer to relaunch in PowerShell 5.1 if needed.

    Must run in STA (Single-Threaded Apartment) mode for Windows Forms compatibility.
    All errors are logged to: $env:TEMP\WSL2-TrayMonitor-YYYYMMDD.log

    TIMER SAFETY:
    - Timer event handlers have comprehensive error handling to prevent PipelineStoppedException
    - All exceptions in timer context are caught, logged, and suppressed
    - StrictMode is disabled in timer handlers to prevent variable errors
    - All cmdlet calls use -ErrorAction SilentlyContinue
    - Null checks prevent NullReferenceException
    - Timer NEVER throws exceptions to Windows Forms message loop
#>

param(
    [switch]$StartMinimized
)

#Requires -Version 5.1

# Log file for error tracking
$script:LogFile = Join-Path $env:TEMP "WSL2-TrayMonitor-$(Get-Date -Format 'yyyyMMdd').log"

# Initialize logging function early
function Write-ErrorLog {
    param([string]$Message, [System.Management.Automation.ErrorRecord]$ErrorRecord)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"

    if ($ErrorRecord) {
        $logEntry += "`nException: $($ErrorRecord.Exception.Message)"
        $logEntry += "`nStackTrace: $($ErrorRecord.ScriptStackTrace)"
    }

    try {
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    } catch {
        # If logging fails, at least try to output to console
        Write-Warning "Failed to write to log: $_"
    }
}

# Check PowerShell version and apartment state
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Warning "PowerShell 7+ detected. Windows Forms works best with Windows PowerShell 5.1"
    Write-Warning "Common issues in PowerShell 7: PipelineStoppedException, control rendering problems"

    $response = Read-Host "Relaunch in Windows PowerShell 5.1? (Y/N)"
    if ($response -eq 'Y' -or $response -eq 'y') {
        $scriptPath = $PSCommandPath
        $args = if($StartMinimized) { '-StartMinimized' } else { '' }

        try {
            Start-Process powershell.exe -ArgumentList "-STA -ExecutionPolicy Bypass -File `"$scriptPath`" $args" -WindowStyle Normal
            Write-Host "Relaunching in Windows PowerShell 5.1..."
            exit 0
        } catch {
            Write-Error "Failed to relaunch: $_"
            Write-Warning "Continuing with PowerShell 7 (may have issues)..."
        }
    } else {
        Write-Warning "Continuing with PowerShell 7. If you experience errors, relaunch with Windows PowerShell 5.1"
    }
}

# Verify STA apartment state
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "This script must run in STA (Single-Threaded Apartment) mode."
    Write-Error "Restart PowerShell with: powershell.exe -STA"
    Write-Error "Or use: powershell.exe -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 1
}

# Import required assemblies with error handling
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Write-Host "Windows Forms assemblies loaded successfully"
} catch {
    Write-Error "Failed to load Windows Forms assemblies: $_"
    Write-Error "This may indicate a corrupted .NET installation or missing dependencies"
    exit 1
}

# Script-level variables
$script:NotifyIcon = $null
$script:MainTimer = $null
$script:ContextMenu = $null
$script:LastNotificationTime = [DateTime]::MinValue
$script:CurrentStatus = "Unknown"
$script:DashboardForm = $null

# Performance cache - reduces expensive operations
$script:Cache = @{
    LastDistroRefresh = [DateTime]::MinValue
    LastErrorRefresh = [DateTime]::MinValue
    LastVirtiofsCheck = [DateTime]::MinValue
    LastProcessQuery = [DateTime]::MinValue
    LastTotalMemoryQuery = [DateTime]::MinValue
    Distros = @()
    DistroCount = 0
    ErrorCount = 0
    ErrorStatus = $null
    VirtiofsStatus = $null
    ProcessData = $null
    TotalMemoryGB = 32
}

# Configuration
$script:Config = @{
    RefreshIntervalNormal = 10000   # 10 seconds (was 5s)
    RefreshIntervalHigh = 5000      # 5 seconds (was 2s)
    RefreshIntervalIdle = 30000     # 30 seconds
    CpuThresholdWarning = 70
    CpuThresholdCritical = 90
    CpuThresholdIdle = 20
    NotificationCooldown = 300      # 5 minutes in seconds
    CacheDistroSeconds = 30         # Cache distro list for 30 seconds
    CacheErrorSeconds = 60          # Cache errors for 60 seconds
    CacheVirtiofsSeconds = 60       # Cache virtiofs status for 60 seconds
    CacheProcessSeconds = 5         # Cache process data for 5 seconds
    CacheTotalMemorySeconds = 300   # Cache total memory for 5 minutes
}

#region Module Imports and Fallbacks

# Try to import performance monitoring module
$performanceModulePath = Join-Path $PSScriptRoot "WSL2-Performance.psm1"
if (Test-Path $performanceModulePath) {
    Import-Module $performanceModulePath -Force
    $script:HasPerformanceModule = $true
} else {
    Write-Warning "WSL2-Performance.psm1 not found. Using fallback metrics."
    $script:HasPerformanceModule = $false
}

# Try to import error detection module
$errorModulePath = Join-Path $PSScriptRoot "WSL2-ErrorDetection.psm1"
if (Test-Path $errorModulePath) {
    Import-Module $errorModulePath -Force
    $script:HasErrorModule = $true
} else {
    Write-Warning "WSL2-ErrorDetection.psm1 not found. Using fallback detection."
    $script:HasErrorModule = $false
}

#endregion

#region Safety Wrappers for Timer Context

function Invoke-SafeTimerAction {
    <#
    .SYNOPSIS
        Safety wrapper for executing code in timer context.
        Ensures all exceptions are caught and never propagate to Windows Forms message loop.

    .DESCRIPTION
        Timer event handlers in Windows Forms must NEVER throw exceptions.
        PipelineStoppedException will crash the entire application if it reaches the message loop.
        This function provides a safety boundary that catches all exceptions and logs them.

    .PARAMETER Action
        ScriptBlock to execute safely

    .PARAMETER FallbackValue
        Value to return if the action fails (default: $null)
    #>
    param(
        [Parameter(Mandatory)]
        [ScriptBlock]$Action,

        [Parameter()]
        $FallbackValue = $null
    )

    try {
        # Disable StrictMode to prevent variable errors
        Set-StrictMode -Off

        # Suppress all cmdlet errors
        $ErrorActionPreference = 'SilentlyContinue'

        # Execute the action
        $result = & $Action

        return $result

    } catch {
        # Log error but NEVER re-throw
        Write-ErrorLog -Message "Safe timer action failed (suppressed)" -ErrorRecord $_

        # Try to write to console if available (never throw)
        try {
            Write-Warning "Timer action error: $_"
        } catch {
            # Even console write failed - silently continue
        }

        return $FallbackValue
    }
}

#endregion

#region Module Adapter Functions

function Get-AdaptedWSLMetrics {
    <#
    .SYNOPSIS
        Adapter function that converts Get-WSL2Performance output to the format expected by the tray monitor.
        Uses caching to reduce expensive operations.
    #>
    try {
        # Disable StrictMode and suppress errors to prevent timer crashes
        Set-StrictMode -Off
        $ErrorActionPreference = 'SilentlyContinue'

        $perfData = Get-WSL2Performance -ErrorAction SilentlyContinue

        if (-not $perfData) {
            return Get-FallbackWSLMetrics
        }

        # Get running distros count (CACHED - expensive WSL subprocess call)
        $now = Get-Date
        if (($now - $script:Cache.LastDistroRefresh).TotalSeconds -gt $script:Config.CacheDistroSeconds) {
            try {
                $distros = & wsl --list --running 2>$null | Select-Object -Skip 1 -ErrorAction SilentlyContinue
                $script:Cache.DistroCount = ($distros | Where-Object { $_.Trim() -ne "" } -ErrorAction SilentlyContinue).Count
                $script:Cache.LastDistroRefresh = $now
            } catch {
                $script:Cache.DistroCount = 0
                Write-ErrorLog -Message "Failed to query WSL distros (cached as 0)" -ErrorRecord $_
            }
        }

        $distroCount = $script:Cache.DistroCount
        $isRunning = $distroCount -gt 0

        # Calculate CPU percentage from performance data
        $cpuPercent = 0
        if ($perfData.Cpu) {
            if ($perfData.Cpu.vmmem -and $perfData.Cpu.vmmem.AverageCpuPercent) {
                $cpuPercent += $perfData.Cpu.vmmem.AverageCpuPercent
            }
            if ($perfData.Cpu.wslservice -and $perfData.Cpu.wslservice.AverageCpuPercent) {
                $cpuPercent += $perfData.Cpu.wslservice.AverageCpuPercent
            }
            if ($perfData.Cpu.wslhost -and $perfData.Cpu.wslhost.AverageCpuPercent) {
                $cpuPercent += $perfData.Cpu.wslhost.AverageCpuPercent
            }
        }

        # Get memory data
        $memoryMB = 0
        $memoryGB = 0
        if ($perfData.Memory -and $perfData.Memory.WorkingSetMB) {
            $memoryMB = $perfData.Memory.WorkingSetMB
            $memoryGB = [math]::Round($memoryMB / 1024, 1)
        }

        # Get disk I/O data
        $diskIOMBps = 0
        if ($perfData.DiskIO -and $perfData.DiskIO.TotalMBPerSec) {
            $diskIOMBps = $perfData.DiskIO.TotalMBPerSec
        }

        # Check virtiofs status (CACHED - expensive check)
        if (($now - $script:Cache.LastVirtiofsCheck).TotalSeconds -gt $script:Config.CacheVirtiofsSeconds) {
            try {
                $status = Get-WSL2Status -ErrorAction SilentlyContinue
                if ($status -and $status.Filesystem) {
                    $script:Cache.VirtiofsStatus = ($status.Filesystem | Where-Object { $_.HasVirtiofs -eq $true } -ErrorAction SilentlyContinue).Count -gt 0
                } else {
                    $script:Cache.VirtiofsStatus = $false
                }
                $script:Cache.LastVirtiofsCheck = $now
            } catch {
                $script:Cache.VirtiofsStatus = $false
                Write-ErrorLog -Message "Failed to check VirtioFS status (cached as false)" -ErrorRecord $_
            }
        }
        $virtiofsEnabled = $script:Cache.VirtiofsStatus

        # Get total system memory (CACHED - rarely changes)
        if (($now - $script:Cache.LastTotalMemoryQuery).TotalSeconds -gt $script:Config.CacheTotalMemorySeconds) {
            try {
                $memoryInfo = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum -ErrorAction SilentlyContinue
                if ($memoryInfo -and $memoryInfo.Sum) {
                    $script:Cache.TotalMemoryGB = [math]::Round($memoryInfo.Sum / 1GB, 1)
                } else {
                    $script:Cache.TotalMemoryGB = 32
                }
                $script:Cache.LastTotalMemoryQuery = $now
            } catch {
                $script:Cache.TotalMemoryGB = 32
                Write-ErrorLog -Message "Failed to query system memory (cached as 32GB)" -ErrorRecord $_
            }
        }
        $totalMemoryGB = $script:Cache.TotalMemoryGB

        return @{
            IsRunning = $isRunning
            DistroCount = $distroCount
            CpuPercent = [math]::Round($cpuPercent, 1)
            MemoryMB = $memoryMB
            MemoryGB = $memoryGB
            DiskIOMBps = $diskIOMBps
            VirtiofsEnabled = $virtiofsEnabled
            TotalMemoryGB = $totalMemoryGB
        }
    }
    catch {
        Write-ErrorLog -Message "Failed to get adapted WSL metrics, using fallback" -ErrorRecord $_
        return Get-FallbackWSLMetrics
    }
}

function Get-AdaptedWSLErrorStatus {
    <#
    .SYNOPSIS
        Adapter function that converts Get-WSL2Errors output to the format expected by the tray monitor.
        Uses caching to avoid expensive Event Log queries on every refresh.
    #>
    try {
        # Disable StrictMode and suppress errors to prevent timer crashes
        Set-StrictMode -Off
        $ErrorActionPreference = 'SilentlyContinue'

        # CACHED - expensive Event Log query
        $now = Get-Date
        if (($now - $script:Cache.LastErrorRefresh).TotalSeconds -gt $script:Config.CacheErrorSeconds) {
            $errors = Get-WSL2Errors -Hours 1 -ErrorAction SilentlyContinue

            if (-not $errors -or $errors.Count -eq 0) {
                $script:Cache.ErrorStatus = @{
                    HasErrors = $false
                    LastErrorTime = $null
                    LastErrorMessage = "None"
                    TimeAgo = "None"
                }
            } else {
                # Get most recent critical/warning error
                $lastError = $errors | Where-Object {
                    $_.Severity -eq [ErrorSeverity]::Critical -or $_.Severity -eq [ErrorSeverity]::Warning
                } | Select-Object -First 1

                if (-not $lastError) {
                    $script:Cache.ErrorStatus = @{
                        HasErrors = $false
                        LastErrorTime = $null
                        LastErrorMessage = "None"
                        TimeAgo = "None"
                    }
                } else {
                    $script:Cache.ErrorStatus = @{
                        HasErrors = $true
                        LastErrorTime = $lastError.Timestamp
                        LastErrorMessage = $lastError.Message.Substring(0, [Math]::Min(100, $lastError.Message.Length))
                        TimeAgo = $null  # Will be recalculated dynamically
                    }
                }
            }

            $script:Cache.LastErrorRefresh = $now
        }

        # Return cached status with dynamically calculated TimeAgo
        $errorStatus = $script:Cache.ErrorStatus.Clone()
        if ($errorStatus.HasErrors -and $errorStatus.LastErrorTime) {
            $timeSince = (Get-Date) - $errorStatus.LastErrorTime
            $errorStatus.TimeAgo = if ($timeSince.TotalDays -gt 1) {
                "{0}d ago" -f [int]$timeSince.TotalDays
            } elseif ($timeSince.TotalHours -gt 1) {
                "{0}h ago" -f [int]$timeSince.TotalHours
            } else {
                "{0}m ago" -f [int]$timeSince.TotalMinutes
            }
        } else {
            $errorStatus.TimeAgo = "None"
        }

        return $errorStatus
    }
    catch {
        Write-ErrorLog -Message "Failed to get adapted WSL error status, using fallback" -ErrorRecord $_
        return Get-FallbackErrorStatus
    }
}

#endregion

#region Fallback Functions (when modules not available)

function Get-FallbackWSLMetrics {
    try {
        # Disable StrictMode and suppress errors to prevent timer crashes
        Set-StrictMode -Off
        $ErrorActionPreference = 'SilentlyContinue'

        $now = Get-Date

        # CACHED - expensive WSL subprocess call
        if (($now - $script:Cache.LastDistroRefresh).TotalSeconds -gt $script:Config.CacheDistroSeconds) {
            try {
                $runningList = wsl --list --running 2>$null | Select-Object -Skip 1 -ErrorAction SilentlyContinue
                $distros = $runningList | Where-Object { $_.Trim() -ne "" } -ErrorAction SilentlyContinue
                $script:Cache.DistroCount = if ($distros) { $distros.Count } else { 0 }
                $script:Cache.LastDistroRefresh = $now
            } catch {
                $script:Cache.DistroCount = 0
                Write-ErrorLog -Message "Fallback: Failed to query WSL distros (cached as 0)" -ErrorRecord $_
            }
        }

        $wslRunning = $script:Cache.DistroCount -gt 0

        # CACHED - expensive process queries
        if (($now - $script:Cache.LastProcessQuery).TotalSeconds -gt $script:Config.CacheProcessSeconds) {
            try {
                # Get WSL processes once and cache
                $wslProcesses = Get-Process -Name "wsl*", "vmmem" -ErrorAction SilentlyContinue
                $vmmem = Get-Process -Name "vmmem" -ErrorAction SilentlyContinue

                $cpuMeasure = $wslProcesses | Measure-Object -Property CPU -Sum -ErrorAction SilentlyContinue

                $script:Cache.ProcessData = @{
                    CpuSum = if ($cpuMeasure -and $cpuMeasure.Sum) { $cpuMeasure.Sum } else { 0 }
                    VmmemMemoryMB = if ($vmmem -and $vmmem.WorkingSet64) { [math]::Round($vmmem.WorkingSet64 / 1MB, 1) } else { 0 }
                }
                $script:Cache.LastProcessQuery = $now
            } catch {
                $script:Cache.ProcessData = @{
                    CpuSum = 0
                    VmmemMemoryMB = 0
                }
                Write-ErrorLog -Message "Fallback: Failed to query processes (cached as 0)" -ErrorRecord $_
            }
        }

        $cpuPercent = $script:Cache.ProcessData.CpuSum
        if ($cpuPercent -gt 100) { $cpuPercent = 100 }

        # CACHED - total system memory (rarely changes)
        if (($now - $script:Cache.LastTotalMemoryQuery).TotalSeconds -gt $script:Config.CacheTotalMemorySeconds) {
            try {
                $memoryInfo = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum -ErrorAction SilentlyContinue
                if ($memoryInfo -and $memoryInfo.Sum) {
                    $script:Cache.TotalMemoryGB = [math]::Round($memoryInfo.Sum / 1GB, 1)
                } else {
                    $script:Cache.TotalMemoryGB = 32
                }
                $script:Cache.LastTotalMemoryQuery = $now
            } catch {
                $script:Cache.TotalMemoryGB = 32
                Write-ErrorLog -Message "Fallback: Failed to query system memory (cached as 32GB)" -ErrorRecord $_
            }
        }

        return @{
            IsRunning = $wslRunning
            DistroCount = $script:Cache.DistroCount
            CpuPercent = [math]::Round($cpuPercent, 1)
            MemoryMB = $script:Cache.ProcessData.VmmemMemoryMB
            MemoryGB = [math]::Round($script:Cache.ProcessData.VmmemMemoryMB / 1024, 1)
            DiskIOMBps = 0  # Not available without module
            VirtiofsEnabled = $false  # Not available without module
            TotalMemoryGB = $script:Cache.TotalMemoryGB
        }
    } catch {
        return @{
            IsRunning = $false
            DistroCount = 0
            CpuPercent = 0
            MemoryMB = 0
            MemoryGB = 0
            DiskIOMBps = 0
            VirtiofsEnabled = $false
            TotalMemoryGB = 32
        }
    }
}

function Get-FallbackErrorStatus {
    try {
        # Disable StrictMode and suppress errors to prevent timer crashes
        Set-StrictMode -Off
        $ErrorActionPreference = 'SilentlyContinue'

        # CACHED - expensive Event Log query
        $now = Get-Date
        if (($now - $script:Cache.LastErrorRefresh).TotalSeconds -gt $script:Config.CacheErrorSeconds) {
            $lastError = Get-EventLog -LogName Application -Source "WSL" -Newest 1 -ErrorAction SilentlyContinue

            if ($lastError -and $lastError.EntryType -eq "Error") {
                $script:Cache.ErrorStatus = @{
                    HasErrors = $true
                    LastErrorTime = $lastError.TimeGenerated
                    LastErrorMessage = $lastError.Message.Substring(0, [Math]::Min(100, $lastError.Message.Length))
                    TimeAgo = $null  # Will be recalculated dynamically
                }
            } else {
                $script:Cache.ErrorStatus = @{
                    HasErrors = $false
                    LastErrorTime = $null
                    LastErrorMessage = "None"
                    TimeAgo = "None"
                }
            }

            $script:Cache.LastErrorRefresh = $now
        }

        # Return cached status with dynamically calculated TimeAgo
        $errorStatus = $script:Cache.ErrorStatus.Clone()
        if ($errorStatus.HasErrors -and $errorStatus.LastErrorTime) {
            $timeSince = (Get-Date) - $errorStatus.LastErrorTime
            $errorStatus.TimeAgo = if ($timeSince.TotalDays -gt 1) {
                "{0}d ago" -f [int]$timeSince.TotalDays
            } elseif ($timeSince.TotalHours -gt 1) {
                "{0}h ago" -f [int]$timeSince.TotalHours
            } else {
                "{0}m ago" -f [int]$timeSince.TotalMinutes
            }
        } else {
            $errorStatus.TimeAgo = "None"
        }

        return $errorStatus
    } catch {
        return @{
            HasErrors = $false
            LastErrorTime = $null
            LastErrorMessage = "Unknown"
            TimeAgo = "Unknown"
        }
    }
}

#endregion

#region Status Determination

function Get-StatusLevel {
    param($metrics, $errors)

    if (-not $metrics.IsRunning) {
        return "Stopped"
    }

    if ($metrics.CpuPercent -gt $script:Config.CpuThresholdCritical -or $errors.HasErrors) {
        return "Critical"
    }

    if ($metrics.CpuPercent -gt $script:Config.CpuThresholdWarning) {
        return "Warning"
    }

    return "Good"
}

function Get-StatusIcon {
    param([string]$status)

    switch ($status) {
        "Good" { return [System.Drawing.SystemIcons]::Information }
        "Warning" { return [System.Drawing.SystemIcons]::Warning }
        "Critical" { return [System.Drawing.SystemIcons]::Error }
        "Stopped" { return [System.Drawing.SystemIcons]::Shield }
        default { return [System.Drawing.SystemIcons]::Question }
    }
}

function Get-StatusEmoji {
    param([string]$status)

    switch ($status) {
        "Good" { return "[OK]" }
        "Warning" { return "[!]" }
        "Critical" { return "[ERR]" }
        "Stopped" { return "[OFF]" }
        default { return "[?]" }
    }
}

#endregion

#region Tooltip Generation

function New-ProgressBar {
    param(
        [double]$percent,
        [int]$width = 10
    )

    $filled = [Math]::Floor($width * $percent / 100)
    $empty = $width - $filled

    return ("#" * $filled) + ("." * $empty)
}

function Update-TooltipText {
    param($metrics, $errors)

    # Lightweight tooltip update - no expensive queries here
    # All data comes from already-cached metrics

    $status = Get-StatusLevel -metrics $metrics -errors $errors
    $statusEmoji = Get-StatusEmoji -status $status

    $cpuBar = New-ProgressBar -percent $metrics.CpuPercent
    $memPercent = if ($metrics.TotalMemoryGB -gt 0) {
        [math]::Round(($metrics.MemoryGB / $metrics.TotalMemoryGB) * 100, 0)
    } else { 0 }
    $memBar = New-ProgressBar -percent $memPercent

    $virtiofsStatus = if ($metrics.VirtiofsEnabled) { "[YES]" } else { "[NO]" }
    $diskInfo = if ($metrics.DiskIOMBps -gt 0) {
        "Disk I/O: $($metrics.DiskIOMBps) MB/s (virtiofs)"
    } else {
        "Disk I/O: N/A"
    }

    $tooltip = @"
WSL2 Monitor - Strix Halo
CPU: $($metrics.CpuPercent)% $cpuBar
RAM: $($metrics.MemoryGB) GB / $($metrics.TotalMemoryGB) GB ($memPercent%)
$diskInfo

Status: $statusEmoji $status ($($metrics.DistroCount) distros)
Filesystem: VirtioFS $virtiofsStatus

Last Error: $($errors.TimeAgo)
Click for details...
"@

    return $tooltip
}

#endregion

#region Notification System

function Send-CriticalNotification {
    param(
        [string]$title,
        [string]$message
    )

    $now = Get-Date
    $timeSinceLastNotification = ($now - $script:LastNotificationTime).TotalSeconds

    # Throttle notifications
    if ($timeSinceLastNotification -lt $script:Config.NotificationCooldown) {
        return
    }

    $script:LastNotificationTime = $now
    $script:NotifyIcon.ShowBalloonTip(
        10000,
        $title,
        $message,
        [System.Windows.Forms.ToolTipIcon]::Error
    )
}

#endregion

#region Quick Actions

function Invoke-QuickBenchmark {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Run quick benchmark? This will test filesystem and CPU performance (30-60 seconds).",
            "Quick Benchmark",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Run benchmark in background job
            $benchmarkScript = Join-Path $PSScriptRoot "..\strix-turbo\benchmark-suite.sh"
            if (Test-Path $benchmarkScript) {
                Start-Process "wsl" -ArgumentList "bash $benchmarkScript --quick" -WindowStyle Normal
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "Benchmark script not found at: $benchmarkScript",
                    "Benchmark Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    } catch {
        Write-ErrorLog -Message "Failed to start benchmark" -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to start benchmark: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Invoke-CollectLogs {
    try {
        $logScript = Join-Path (Split-Path $PSScriptRoot -Parent) "diagnostics\collect-wsl-logs.ps1"
        if (Test-Path $logScript) {
            Start-Process "powershell" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$logScript`"" -Verb RunAs
        } else {
            # Fallback: collect basic logs
            $outputPath = Join-Path $env:TEMP "wsl2-logs-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            $logs = @(
                "=== WSL Version ==="
                wsl --version 2>&1
                ""
                "=== Running Distros ==="
                wsl --list --running 2>&1
                ""
                "=== Recent WSL Events ==="
                Get-EventLog -LogName Application -Source "WSL" -Newest 20 -ErrorAction SilentlyContinue | Format-List
            )
            $logs | Out-File -FilePath $outputPath -Encoding UTF8
            Start-Process "notepad" -ArgumentList $outputPath
        }
    } catch {
        Write-ErrorLog -Message "Failed to collect logs" -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to collect logs: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Invoke-FixVirtiofs {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Attempt to fix VirtioFS? This will restart WSL and update .wslconfig.",
            "Fix VirtioFS",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Update .wslconfig
            $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
            $configContent = @"
[wsl2]
# VirtioFS for 3-10x filesystem performance
# See: docs/wsl-virtiofs-troubleshooting.md
kernel=C:\\tools\\wsl\\bzImage
virtiofs=true

# Memory and CPU tuning for Strix Halo
memory=32GB
processors=16

# Network optimizations
networkingMode=mirrored
dnsTunneling=true
"@
            $configContent | Out-File -FilePath $wslConfigPath -Encoding UTF8 -Force

            # Restart WSL
            wsl --shutdown
            Start-Sleep -Seconds 2

            [System.Windows.Forms.MessageBox]::Show(
                "VirtioFS configuration updated and WSL restarted.",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    } catch {
        Write-ErrorLog -Message "Failed to fix VirtioFS" -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to fix VirtioFS: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Invoke-RestartWSL {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Restart WSL? All running distros will be shut down.",
            "Restart WSL",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            wsl --shutdown
            [System.Windows.Forms.MessageBox]::Show(
                "WSL has been shut down. It will restart on next use.",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    } catch {
        Write-ErrorLog -Message "Failed to restart WSL" -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to restart WSL: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-ErrorLog {
    try {
        # Only query Event Log when user explicitly requests it (expensive operation)
        $errors = Get-EventLog -LogName Application -Source "WSL" -Newest 50 -ErrorAction SilentlyContinue
        if ($errors) {
            $outputPath = Join-Path $env:TEMP "wsl2-errors-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
            $errors | Format-List TimeGenerated, EntryType, Message | Out-File -FilePath $outputPath -Encoding UTF8
            Start-Process "notepad" -ArgumentList $outputPath
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "No recent WSL errors found in Event Log.",
                "Error Log",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    } catch {
        Write-ErrorLog -Message "Failed to open error log" -ErrorRecord $_
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to open error log: $_",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-Settings {
    # Placeholder for settings dialog
    [System.Windows.Forms.MessageBox]::Show(
        "Settings dialog coming soon...`n`nCurrent Configuration:`n" +
        "Normal Refresh: $($script:Config.RefreshIntervalNormal)ms`n" +
        "High Load Refresh: $($script:Config.RefreshIntervalHigh)ms`n" +
        "Idle Refresh: $($script:Config.RefreshIntervalIdle)ms",
        "Settings",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

#endregion

#region Dashboard Window

function Show-Dashboard {
    if ($script:DashboardForm -ne $null -and -not $script:DashboardForm.IsDisposed) {
        $script:DashboardForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:DashboardForm.Activate()
        return
    }

    # Create dashboard form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "WSL2 Monitor Dashboard - Strix Halo"
    $form.Size = New-Object System.Drawing.Size(600, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false

    # Create rich text box for metrics display
    $richTextBox = New-Object System.Windows.Forms.RichTextBox
    $richTextBox.Location = New-Object System.Drawing.Point(10, 10)
    $richTextBox.Size = New-Object System.Drawing.Size(560, 400)
    $richTextBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $richTextBox.ReadOnly = $true
    $richTextBox.BackColor = [System.Drawing.Color]::Black
    $richTextBox.ForeColor = [System.Drawing.Color]::LimeGreen
    $form.Controls.Add($richTextBox)

    # Refresh button
    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Location = New-Object System.Drawing.Point(10, 420)
    $refreshButton.Size = New-Object System.Drawing.Size(100, 30)
    $refreshButton.Text = "Refresh"
    $refreshButton.Add_Click({
        try {
            Update-DashboardContent -richTextBox $richTextBox
        } catch {
            Write-ErrorLog -Message "Dashboard refresh button error" -ErrorRecord $_
        }
    })
    $form.Controls.Add($refreshButton)

    # Close button
    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Location = New-Object System.Drawing.Point(470, 420)
    $closeButton.Size = New-Object System.Drawing.Size(100, 30)
    $closeButton.Text = "Close"
    $closeButton.Add_Click({
        try {
            $form.Hide()
        } catch {
            Write-ErrorLog -Message "Dashboard close button error" -ErrorRecord $_
        }
    })
    $form.Controls.Add($closeButton)

    # Handle form closing (hide instead of dispose)
    $form.Add_FormClosing({
        param($sender, $e)
        try {
            $e.Cancel = $true
            $sender.Hide()
        } catch {
            Write-ErrorLog -Message "Dashboard form closing error" -ErrorRecord $_
        }
    })

    # Initial content update
    Update-DashboardContent -richTextBox $richTextBox

    $script:DashboardForm = $form
    $form.Show()
}

function Update-DashboardContent {
    param($richTextBox)

    # Force cache refresh when dashboard is explicitly opened (user-initiated action)
    $script:Cache.LastErrorRefresh = [DateTime]::MinValue

    # Get current metrics
    if ($script:HasPerformanceModule) {
        $metrics = Get-AdaptedWSLMetrics
    } else {
        $metrics = Get-FallbackWSLMetrics
    }

    if ($script:HasErrorModule) {
        $errors = Get-AdaptedWSLErrorStatus
    } else {
        $errors = Get-FallbackErrorStatus
    }

    $status = Get-StatusLevel -metrics $metrics -errors $errors

    # Build dashboard content
    $content = @"
===============================================================
          WSL2 MONITOR DASHBOARD - STRIX HALO
===============================================================

Status: $status
Last Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

---------------------------------------------------------------
PERFORMANCE METRICS
---------------------------------------------------------------

CPU Usage:        $($metrics.CpuPercent)% $(New-ProgressBar -percent $metrics.CpuPercent -width 20)
Memory Usage:     $($metrics.MemoryGB) GB / $($metrics.TotalMemoryGB) GB
Disk I/O:         $($metrics.DiskIOMBps) MB/s
VirtioFS:         $(if($metrics.VirtiofsEnabled){'Enabled [YES]'}else{'Disabled [NO]'})

---------------------------------------------------------------
WSL STATUS
---------------------------------------------------------------

Running:          $(if($metrics.IsRunning){'Yes'}else{'No'})
Active Distros:   $($metrics.DistroCount)

---------------------------------------------------------------
ERROR STATUS
---------------------------------------------------------------

Last Error:       $($errors.TimeAgo)
Has Errors:       $(if($errors.HasErrors){'Yes'}else{'No'})

$(if ($errors.HasErrors) {
"Last Error Message:
$($errors.LastErrorMessage)"
})

---------------------------------------------------------------
QUICK INFO
---------------------------------------------------------------

Refresh Interval: $($script:MainTimer.Interval)ms
Next Refresh:     $(Get-Date).AddMilliseconds($script:MainTimer.Interval).ToString('HH:mm:ss')

"@

    $richTextBox.Text = $content
}

#endregion

#region Timer and Updates

function Update-MonitorStatus {
    # CRITICAL: This function runs in timer context - NEVER throw exceptions
    # All errors must be caught, logged, and suppressed to prevent PipelineStoppedException

    try {
        # Disable StrictMode to prevent variable errors from stopping the timer
        Set-StrictMode -Off

        # Set error action to prevent cmdlet errors from propagating
        $ErrorActionPreference = 'SilentlyContinue'

        # Get current metrics with safety wrappers
        $metrics = $null
        try {
            if ($script:HasPerformanceModule) {
                $metrics = Get-AdaptedWSLMetrics -ErrorAction SilentlyContinue
            } else {
                $metrics = Get-FallbackWSLMetrics -ErrorAction SilentlyContinue
            }
        } catch {
            Write-ErrorLog -Message "Failed to get metrics (suppressed)" -ErrorRecord $_
            $metrics = $null
        }

        # Fallback to safe default metrics if retrieval failed
        if (-not $metrics) {
            $metrics = @{
                IsRunning = $false
                DistroCount = 0
                CpuPercent = 0
                MemoryMB = 0
                MemoryGB = 0
                DiskIOMBps = 0
                VirtiofsEnabled = $false
                TotalMemoryGB = 32
            }
        }

        # Get error status with safety wrappers
        $errors = $null
        try {
            if ($script:HasErrorModule) {
                $errors = Get-AdaptedWSLErrorStatus -ErrorAction SilentlyContinue
            } else {
                $errors = Get-FallbackErrorStatus -ErrorAction SilentlyContinue
            }
        } catch {
            Write-ErrorLog -Message "Failed to get error status (suppressed)" -ErrorRecord $_
            $errors = $null
        }

        # Fallback to safe default error status if retrieval failed
        if (-not $errors) {
            $errors = @{
                HasErrors = $false
                LastErrorTime = $null
                LastErrorMessage = "Unknown"
                TimeAgo = "Unknown"
            }
        }

        # Determine status and update icon (with null checks)
        try {
            $status = Get-StatusLevel -metrics $metrics -errors $errors
            $icon = Get-StatusIcon -status $status

            if ($script:NotifyIcon -and $script:CurrentStatus -ne $status) {
                $script:NotifyIcon.Icon = $icon
                $script:CurrentStatus = $status

                # Send notification for critical status changes (never throw)
                if ($status -eq "Critical") {
                    try {
                        Send-CriticalNotification -title "WSL2 Critical Alert" `
                            -message "CPU: $($metrics.CpuPercent)% | Check dashboard for details"
                    } catch {
                        Write-ErrorLog -Message "Failed to send notification (suppressed)" -ErrorRecord $_
                    }
                }
            }
        } catch {
            Write-ErrorLog -Message "Failed to update icon/status (suppressed)" -ErrorRecord $_
        }

        # Update tooltip (with null checks and error handling)
        try {
            if ($script:NotifyIcon) {
                $tooltipText = Update-TooltipText -metrics $metrics -errors $errors
                if ($tooltipText) {
                    $script:NotifyIcon.Text = $tooltipText.Substring(0, [Math]::Min(63, $tooltipText.Length))
                }
            }
        } catch {
            Write-ErrorLog -Message "Failed to update tooltip (suppressed)" -ErrorRecord $_
        }

        # Adjust refresh interval based on CPU usage (with null checks)
        try {
            if ($script:MainTimer -and $metrics.CpuPercent -ne $null) {
                $newInterval = if ($metrics.CpuPercent -gt 80) {
                    $script:Config.RefreshIntervalHigh
                } elseif ($metrics.CpuPercent -lt 20) {
                    $script:Config.RefreshIntervalIdle
                } else {
                    $script:Config.RefreshIntervalNormal
                }

                if ($script:MainTimer.Interval -ne $newInterval) {
                    $script:MainTimer.Interval = $newInterval
                }
            }
        } catch {
            Write-ErrorLog -Message "Failed to adjust refresh interval (suppressed)" -ErrorRecord $_
        }

        # Update dashboard if visible (with null checks and error handling)
        try {
            if ($script:DashboardForm -ne $null -and -not $script:DashboardForm.IsDisposed -and $script:DashboardForm.Visible) {
                $richTextBox = $script:DashboardForm.Controls[0]
                if ($richTextBox) {
                    Update-DashboardContent -richTextBox $richTextBox
                }
            }
        } catch {
            Write-ErrorLog -Message "Failed to update dashboard (suppressed)" -ErrorRecord $_
        }

    } catch {
        # CRITICAL: Final catch-all - log but NEVER re-throw
        Write-ErrorLog -Message "Timer tick error (all exceptions suppressed)" -ErrorRecord $_
        # DO NOT throw - this would crash the entire application
    }
}

#endregion

#region Context Menu Setup

function New-ContextMenu {
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    # Show Dashboard
    $menuShowDashboard = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuShowDashboard.Text = "Show Dashboard"
    $menuShowDashboard.Font = New-Object System.Drawing.Font($menuShowDashboard.Font, [System.Drawing.FontStyle]::Bold)
    $menuShowDashboard.Add_Click({
        try { Show-Dashboard } catch { Write-ErrorLog -Message "Menu: Show Dashboard error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuShowDashboard) | Out-Null

    # Refresh Now
    $menuRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuRefresh.Text = "Refresh Now"
    $menuRefresh.Add_Click({
        try { Update-MonitorStatus } catch { Write-ErrorLog -Message "Menu: Refresh error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuRefresh) | Out-Null

    # Separator
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Quick Benchmark
    $menuBenchmark = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuBenchmark.Text = "Quick Benchmark"
    $menuBenchmark.Add_Click({
        try { Invoke-QuickBenchmark } catch { Write-ErrorLog -Message "Menu: Benchmark error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuBenchmark) | Out-Null

    # Collect Logs
    $menuLogs = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuLogs.Text = "Collect Logs"
    $menuLogs.Add_Click({
        try { Invoke-CollectLogs } catch { Write-ErrorLog -Message "Menu: Collect Logs error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuLogs) | Out-Null

    # Fix Virtiofs
    $menuVirtiofs = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuVirtiofs.Text = "Fix Virtiofs"
    $menuVirtiofs.Add_Click({
        try { Invoke-FixVirtiofs } catch { Write-ErrorLog -Message "Menu: Fix Virtiofs error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuVirtiofs) | Out-Null

    # Restart WSL
    $menuRestart = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuRestart.Text = "Restart WSL"
    $menuRestart.Add_Click({
        try { Invoke-RestartWSL } catch { Write-ErrorLog -Message "Menu: Restart WSL error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuRestart) | Out-Null

    # Separator
    $contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    # Settings
    $menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuSettings.Text = "Settings"
    $menuSettings.Add_Click({
        try { Show-Settings } catch { Write-ErrorLog -Message "Menu: Settings error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuSettings) | Out-Null

    # View Error Log
    $menuErrorLog = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuErrorLog.Text = "View Error Log"
    $menuErrorLog.Add_Click({
        try { Show-ErrorLog } catch { Write-ErrorLog -Message "Menu: View Error Log error" -ErrorRecord $_ }
    })
    $contextMenu.Items.Add($menuErrorLog) | Out-Null

    # Exit
    $menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuExit.Text = "Exit"
    $menuExit.Add_Click({
        try {
            $script:NotifyIcon.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        } catch {
            Write-ErrorLog -Message "Menu: Exit error" -ErrorRecord $_
        }
    })
    $contextMenu.Items.Add($menuExit) | Out-Null

    return $contextMenu
}

#endregion

#region Main Application Setup

function Initialize-TrayMonitor {
    try {
        # Create notify icon
        $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        $script:NotifyIcon.Text = "WSL2 Monitor - Initializing..."
        $script:NotifyIcon.Visible = $true

        # Create context menu
        $script:ContextMenu = New-ContextMenu
        $script:NotifyIcon.ContextMenuStrip = $script:ContextMenu

        # Left-click handler
        $script:NotifyIcon.Add_Click({
            param($sender, $e)
            try {
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                    Show-Dashboard
                }
            } catch {
                Write-ErrorLog -Message "NotifyIcon click handler error" -ErrorRecord $_
            }
        })

        # Create and start timer with comprehensive error handling
        $script:MainTimer = New-Object System.Windows.Forms.Timer
        $script:MainTimer.Interval = $script:Config.RefreshIntervalNormal
        $script:MainTimer.Add_Tick({
            # CRITICAL: Timer event handler - NEVER throw exceptions
            # PipelineStoppedException will crash the entire application
            try {
                # Disable StrictMode and suppress all cmdlet errors
                Set-StrictMode -Off
                $ErrorActionPreference = 'SilentlyContinue'

                # Call main update function (already has comprehensive error handling)
                Update-MonitorStatus

            } catch {
                # CRITICAL: Log but NEVER re-throw - this would crash the app
                Write-ErrorLog -Message "Timer tick event handler error (suppressed to prevent crash)" -ErrorRecord $_

                # Try to write to console if available (never throw)
                try {
                    Write-Warning "Timer error suppressed: $_"
                } catch {
                    # Even console write failed - silently continue
                }
            }
        })
        $script:MainTimer.Start()

        # Initial update
        Update-MonitorStatus

        # Show dashboard if not starting minimized
        if (-not $StartMinimized) {
            Show-Dashboard
        }

        # Show startup notification
        $script:NotifyIcon.ShowBalloonTip(
            5000,
            "WSL2 Monitor Started",
            "Monitoring Strix Halo performance. Click icon for dashboard.",
            [System.Windows.Forms.ToolTipIcon]::Info
        )

        Write-Host "WSL2 Tray Monitor initialized successfully"
        Write-Host "Log file: $script:LogFile"
    } catch {
        Write-ErrorLog -Message "Failed to initialize tray monitor" -ErrorRecord $_
        throw
    }
}

function Stop-TrayMonitor {
    Write-Host "Shutting down WSL2 Tray Monitor..."
    Write-ErrorLog -Message "Tray monitor shutdown initiated"

    try {
        # Stop timer
        if ($script:MainTimer -ne $null) {
            $script:MainTimer.Stop()
            $script:MainTimer.Dispose()
        }

        # Close dashboard
        if ($script:DashboardForm -ne $null -and -not $script:DashboardForm.IsDisposed) {
            $script:DashboardForm.Close()
            $script:DashboardForm.Dispose()
        }

        # Remove tray icon
        if ($script:NotifyIcon -ne $null) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }

        # Dispose context menu
        if ($script:ContextMenu -ne $null) {
            $script:ContextMenu.Dispose()
        }

        Write-Host "Cleanup completed successfully"
        Write-ErrorLog -Message "Tray monitor shutdown completed"
    } catch {
        Write-ErrorLog -Message "Error during shutdown" -ErrorRecord $_
        Write-Warning "Error during cleanup: $_"
    }
}

#endregion

#region Main Entry Point

try {
    Write-Host "Starting WSL2 Tray Monitor for Strix Halo..."
    Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-Host "Apartment State: $([Threading.Thread]::CurrentThread.GetApartmentState())"
    Write-Host "Press Ctrl+C or use Exit menu to stop."
    Write-Host "Log file: $script:LogFile"

    Write-ErrorLog -Message "=== WSL2 Tray Monitor Started ==="
    Write-ErrorLog -Message "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-ErrorLog -Message "Apartment State: $([Threading.Thread]::CurrentThread.GetApartmentState())"

    Initialize-TrayMonitor

    # Run message loop
    [System.Windows.Forms.Application]::Run()

} catch {
    $errorMsg = "Fatal error in tray monitor: $_"
    Write-Error $errorMsg
    Write-Error $_.ScriptStackTrace
    Write-ErrorLog -Message $errorMsg -ErrorRecord $_

    # Try to show error dialog if possible
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Fatal error occurred. Check log file at:`n$script:LogFile`n`nError: $_",
            "WSL2 Monitor Fatal Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {
        Write-Warning "Could not show error dialog: $_"
    }
} finally {
    Stop-TrayMonitor
    Write-Host "Log file saved to: $script:LogFile"
}

#endregion
