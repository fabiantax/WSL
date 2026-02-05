# WSL2-ErrorDetection.psm1
# PowerShell module for comprehensive WSL2 error detection and monitoring
# Copyright (c) Microsoft Corporation.

#Requires -Version 5.1

<#
.SYNOPSIS
    WSL2 Error Detection and Monitoring Module
.DESCRIPTION
    Provides functions to detect, categorize, and analyze WSL2 errors from Windows Event Log,
    Linux systemd journal, service restarts, virtiofs status, and performance anomalies.
#>

# Error categories
enum ErrorSeverity {
    Critical
    Warning
    Info
}

# Error object structure
class WSL2Error {
    [DateTime]$Timestamp
    [ErrorSeverity]$Severity
    [string]$Source
    [string]$Message
    [hashtable]$Details
}

<#
.SYNOPSIS
    Retrieves WSL2-related errors from Windows Event Log for the last 24 hours.
.DESCRIPTION
    Queries Application and System logs for WslService, wsl.exe, and wslhost.exe events.
    Categorizes by severity: Critical (crashes), Warning (restarts), Info (normal events).
.PARAMETER Hours
    Number of hours to look back (default: 24)
.EXAMPLE
    Get-WSL2Errors -Hours 48
#>
function Get-WSL2Errors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [int]$Hours = 24
    )

    $errors = @()
    $startTime = (Get-Date).AddHours(-$Hours)

    # WSL-related providers and sources
    $wslSources = @('WslService', 'wsl.exe', 'wslhost.exe', 'wslrelay.exe', 'wslg.exe')

    # Query Application and System logs
    $logNames = @('Application', 'System')

    foreach ($logName in $logNames) {
        try {
            # Build filter for WSL-related events
            $filterXml = @"
<QueryList>
  <Query Id="0" Path="$logName">
    <Select Path="$logName">*[System[TimeCreated[@SystemTime&gt;='$($startTime.ToUniversalTime().ToString('o'))']]]</Select>
  </Query>
</QueryList>
"@

            $events = Get-WinEvent -FilterXml $filterXml -ErrorAction SilentlyContinue

            foreach ($event in $events) {
                # Filter for WSL-related events
                $isWslRelated = $false
                foreach ($source in $wslSources) {
                    if ($event.ProviderName -like "*$source*" -or
                        $event.Message -like "*$source*" -or
                        $event.Message -like "*WSL*" -or
                        $event.Message -like "*Windows Subsystem for Linux*") {
                        $isWslRelated = $true
                        break
                    }
                }

                if (-not $isWslRelated) { continue }

                # Categorize by severity
                $severity = switch ($event.LevelDisplayName) {
                    'Critical' { [ErrorSeverity]::Critical }
                    'Error' { [ErrorSeverity]::Critical }
                    'Warning' { [ErrorSeverity]::Warning }
                    default { [ErrorSeverity]::Info }
                }

                # Upgrade severity for specific error patterns
                if ($event.Message -match 'crash|fatal|terminated unexpectedly|stopped working') {
                    $severity = [ErrorSeverity]::Critical
                } elseif ($event.Message -match 'restart|recover|retry') {
                    $severity = [ErrorSeverity]::Warning
                }

                $error = [WSL2Error]@{
                    Timestamp = $event.TimeCreated
                    Severity = $severity
                    Source = "$logName/$($event.ProviderName)"
                    Message = $event.Message
                    Details = @{
                        EventId = $event.Id
                        Level = $event.LevelDisplayName
                        ProcessId = $event.ProcessId
                        ThreadId = $event.ThreadId
                        MachineName = $event.MachineName
                    }
                }

                $errors += $error
            }
        } catch {
            Write-Warning "Failed to query $logName log: $_"
        }
    }

    # Sort by timestamp descending
    return $errors | Sort-Object -Property Timestamp -Descending
}

<#
.SYNOPSIS
    Retrieves WSL2 Linux-side errors from systemd journal.
.DESCRIPTION
    Executes journalctl in WSL to retrieve systemd failures, kernel errors, and mount failures.
    Parses and structures error information.
.PARAMETER Hours
    Number of hours to look back (default: 24)
.PARAMETER Distribution
    WSL distribution name (default: default distribution)
.EXAMPLE
    Get-WSL2LinuxErrors -Distribution Ubuntu-22.04
#>
function Get-WSL2LinuxErrors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [int]$Hours = 24,

        [Parameter(Mandatory=$false)]
        [string]$Distribution
    )

    $errors = @()

    # Check if WSL is running
    try {
        $wslStatus = wsl --status 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WSL is not available or not running"
            return $errors
        }
    } catch {
        Write-Warning "Failed to check WSL status: $_"
        return $errors
    }

    # Build WSL command
    $distroArg = if ($Distribution) { "-d $Distribution" } else { "" }
    $sinceArg = "$Hours hours ago"

    try {
        # Query journalctl for errors
        $journalCmd = "journalctl --since `"$sinceArg`" -p err --no-pager -o json"
        $output = Invoke-Expression "wsl $distroArg -- $journalCmd" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to query journalctl: $output"
            return $errors
        }

        # Parse JSON output (each line is a JSON object)
        $lines = $output -split "`n" | Where-Object { $_.Trim() -ne "" }

        foreach ($line in $lines) {
            try {
                $entry = $line | ConvertFrom-Json

                # Determine severity based on priority
                $severity = switch ([int]$entry.PRIORITY) {
                    0 { [ErrorSeverity]::Critical }  # emerg
                    1 { [ErrorSeverity]::Critical }  # alert
                    2 { [ErrorSeverity]::Critical }  # crit
                    3 { [ErrorSeverity]::Critical }  # err
                    4 { [ErrorSeverity]::Warning }   # warning
                    default { [ErrorSeverity]::Info }
                }

                # Extract timestamp (microseconds since epoch)
                $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$entry.__REALTIME_TIMESTAMP / 1000).DateTime

                $error = [WSL2Error]@{
                    Timestamp = $timestamp
                    Severity = $severity
                    Source = "Linux/systemd/$($entry._SYSTEMD_UNIT)"
                    Message = $entry.MESSAGE
                    Details = @{
                        Priority = $entry.PRIORITY
                        Unit = $entry._SYSTEMD_UNIT
                        Command = $entry._COMM
                        PID = $entry._PID
                        UID = $entry._UID
                        Hostname = $entry._HOSTNAME
                    }
                }

                $errors += $error
            } catch {
                Write-Verbose "Failed to parse journal entry: $_"
            }
        }

        # Also check dmesg for kernel errors
        $dmesgCmd = "dmesg -T --level=err,crit,alert,emerg --time-format iso"
        $dmesgOutput = Invoke-Expression "wsl $distroArg -- $dmesgCmd" 2>&1

        if ($LASTEXITCODE -eq 0) {
            $dmesgLines = $dmesgOutput -split "`n" | Where-Object { $_.Trim() -ne "" }

            foreach ($line in $dmesgLines) {
                # Parse dmesg format: [timestamp] message
                if ($line -match '^\[(.+?)\]\s+(.+)$') {
                    $timestamp = $matches[1]
                    $message = $matches[2]

                    try {
                        $dt = [DateTime]::Parse($timestamp)

                        # Filter by time range
                        if ($dt -gt (Get-Date).AddHours(-$Hours)) {
                            $error = [WSL2Error]@{
                                Timestamp = $dt
                                Severity = [ErrorSeverity]::Critical
                                Source = "Linux/kernel"
                                Message = $message
                                Details = @{
                                    Type = "kernel"
                                }
                            }

                            $errors += $error
                        }
                    } catch {
                        Write-Verbose "Failed to parse dmesg timestamp: $timestamp"
                    }
                }
            }
        }

    } catch {
        Write-Warning "Failed to retrieve Linux errors: $_"
    }

    return $errors | Sort-Object -Property Timestamp -Descending
}

<#
.SYNOPSIS
    Retrieves WSL2 service restart information.
.DESCRIPTION
    Checks for service restart monitor log and parses restart counts and auto-masked services.
.PARAMETER Distribution
    WSL distribution name (default: default distribution)
.EXAMPLE
    Get-WSL2ServiceRestarts -Distribution Ubuntu-22.04
#>
function Get-WSL2ServiceRestarts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Distribution
    )

    $restarts = @()
    $logPath = "/var/log/service-restart-monitor.log"

    # Check if WSL is running
    try {
        $wslStatus = wsl --status 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WSL is not available or not running"
            return $restarts
        }
    } catch {
        Write-Warning "Failed to check WSL status: $_"
        return $restarts
    }

    # Build WSL command
    $distroArg = if ($Distribution) { "-d $Distribution" } else { "" }

    try {
        # Check if log file exists
        $checkCmd = "test -f $logPath && echo 'exists' || echo 'missing'"
        $checkResult = Invoke-Expression "wsl $distroArg -- $checkCmd" 2>&1

        if ($checkResult -notmatch 'exists') {
            Write-Verbose "Service restart monitor log not found at $logPath"
            return $restarts
        }

        # Read the log file
        $logContent = Invoke-Expression "wsl $distroArg -- cat $logPath" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to read service restart log: $logContent"
            return $restarts
        }

        # Parse log entries
        # Expected format: [timestamp] service_name: restart_count restarts (status: auto-masked/active)
        $lines = $logContent -split "`n" | Where-Object { $_.Trim() -ne "" }

        foreach ($line in $lines) {
            if ($line -match '^\[(.+?)\]\s+(.+?):\s+(\d+)\s+restarts?\s+\(status:\s+(.+?)\)') {
                $timestamp = $matches[1]
                $serviceName = $matches[2]
                $restartCount = [int]$matches[3]
                $status = $matches[4]

                try {
                    $dt = [DateTime]::Parse($timestamp)

                    $severity = if ($status -eq 'auto-masked') {
                        [ErrorSeverity]::Critical
                    } elseif ($restartCount -gt 5) {
                        [ErrorSeverity]::Warning
                    } else {
                        [ErrorSeverity]::Info
                    }

                    $error = [WSL2Error]@{
                        Timestamp = $dt
                        Severity = $severity
                        Source = "Linux/systemd/restart-monitor"
                        Message = "$serviceName has restarted $restartCount time(s), status: $status"
                        Details = @{
                            ServiceName = $serviceName
                            RestartCount = $restartCount
                            Status = $status
                            AutoMasked = ($status -eq 'auto-masked')
                        }
                    }

                    $restarts += $error
                } catch {
                    Write-Verbose "Failed to parse timestamp: $timestamp"
                }
            }
        }

    } catch {
        Write-Warning "Failed to retrieve service restart information: $_"
    }

    return $restarts | Sort-Object -Property Timestamp -Descending
}

<#
.SYNOPSIS
    Checks WSL2 virtiofs status and detects mount failures.
.DESCRIPTION
    Executes dmesg to detect virtiofs errors and checks current mounts.
    Returns status: OK, Degraded (using 9p), Failed.
.PARAMETER Distribution
    WSL distribution name (default: default distribution)
.EXAMPLE
    Get-WSL2VirtiofsStatus -Distribution Ubuntu-22.04
#>
function Get-WSL2VirtiofsStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Distribution
    )

    $result = [PSCustomObject]@{
        Status = "Unknown"
        Errors = @()
        CurrentMounts = @()
        UsingVirtiofs = $false
        Using9p = $false
    }

    # Check if WSL is running
    try {
        $wslStatus = wsl --status 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WSL is not available or not running"
            $result.Status = "WSL Not Running"
            return $result
        }
    } catch {
        Write-Warning "Failed to check WSL status: $_"
        $result.Status = "WSL Not Running"
        return $result
    }

    # Build WSL command
    $distroArg = if ($Distribution) { "-d $Distribution" } else { "" }

    try {
        # Check dmesg for virtiofs errors
        $dmesgCmd = "dmesg | grep -i virtiofs"
        $dmesgOutput = Invoke-Expression "wsl $distroArg -- $dmesgCmd" 2>&1

        $virtiofsErrors = @()

        if ($LASTEXITCODE -eq 0 -and $dmesgOutput) {
            $dmesgLines = $dmesgOutput -split "`n" | Where-Object { $_.Trim() -ne "" }

            foreach ($line in $dmesgLines) {
                # Detect errors
                if ($line -match 'error|fail|timeout|transport') {
                    # Parse dmesg format
                    if ($line -match '^\[\s*(\d+\.\d+)\]\s+(.+)$') {
                        $uptime = [double]$matches[1]
                        $message = $matches[2]

                        # Calculate approximate timestamp
                        $bootTime = (Get-Date) - (New-TimeSpan -Seconds ([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency))
                        $timestamp = $bootTime.AddSeconds($uptime)

                        $error = [WSL2Error]@{
                            Timestamp = $timestamp
                            Severity = [ErrorSeverity]::Critical
                            Source = "Linux/kernel/virtiofs"
                            Message = $message
                            Details = @{
                                UptimeSeconds = $uptime
                            }
                        }

                        $virtiofsErrors += $error
                    }
                }
            }
        }

        $result.Errors = $virtiofsErrors

        # Check current mounts
        $mountCmd = "mount | grep -E '(virtiofs|9p)'"
        $mountOutput = Invoke-Expression "wsl $distroArg -- $mountCmd" 2>&1

        if ($LASTEXITCODE -eq 0 -and $mountOutput) {
            $mountLines = $mountOutput -split "`n" | Where-Object { $_.Trim() -ne "" }

            foreach ($line in $mountLines) {
                $result.CurrentMounts += $line

                if ($line -match 'virtiofs') {
                    $result.UsingVirtiofs = $true
                } elseif ($line -match '9p') {
                    $result.Using9p = $true
                }
            }
        }

        # Determine overall status
        if ($virtiofsErrors.Count -gt 0) {
            if ($result.Using9p) {
                $result.Status = "Degraded"
            } else {
                $result.Status = "Failed"
            }
        } elseif ($result.UsingVirtiofs) {
            $result.Status = "OK"
        } elseif ($result.Using9p) {
            $result.Status = "Degraded"
        } else {
            $result.Status = "Unknown"
        }

    } catch {
        Write-Warning "Failed to check virtiofs status: $_"
        $result.Status = "Error"
    }

    return $result
}

<#
.SYNOPSIS
    Tests for WSL2 performance anomalies.
.DESCRIPTION
    Checks for sustained high CPU, memory usage, and disk I/O latency.
    Returns anomalies with timestamps.
.PARAMETER Distribution
    WSL distribution name (default: default distribution)
.PARAMETER DurationMinutes
    Duration to check for sustained issues (default: 5)
.EXAMPLE
    Test-WSL2PerformanceAnomaly -DurationMinutes 10
#>
function Test-WSL2PerformanceAnomaly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Distribution,

        [Parameter(Mandatory=$false)]
        [int]$DurationMinutes = 5
    )

    $anomalies = @()

    # Check if WSL is running
    try {
        $wslStatus = wsl --status 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WSL is not available or not running"
            return $anomalies
        }
    } catch {
        Write-Warning "Failed to check WSL status: $_"
        return $anomalies
    }

    # Build WSL command
    $distroArg = if ($Distribution) { "-d $Distribution" } else { "" }

    try {
        # Check CPU usage (sustained > 90%)
        $cpuCmd = "top -bn2 -d 1 | grep 'Cpu(s)' | tail -1 | awk '{print `$2}' | cut -d'%' -f1"
        $cpuUsage = Invoke-Expression "wsl $distroArg -- bash -c `"$cpuCmd`"" 2>&1

        if ($LASTEXITCODE -eq 0 -and $cpuUsage) {
            $cpuPercent = [double]$cpuUsage

            if ($cpuPercent -gt 90) {
                $error = [WSL2Error]@{
                    Timestamp = Get-Date
                    Severity = [ErrorSeverity]::Warning
                    Source = "Performance/CPU"
                    Message = "High CPU usage detected: $([math]::Round($cpuPercent, 2))%"
                    Details = @{
                        Type = "CPU"
                        Value = $cpuPercent
                        Threshold = 90
                        Unit = "percent"
                    }
                }

                $anomalies += $error
            }
        }

        # Check memory usage (> 95%)
        $memCmd = "free | grep Mem | awk '{print (`$3/`$2) * 100.0}'"
        $memUsage = Invoke-Expression "wsl $distroArg -- bash -c `"$memCmd`"" 2>&1

        if ($LASTEXITCODE -eq 0 -and $memUsage) {
            $memPercent = [double]$memUsage

            if ($memPercent -gt 95) {
                $error = [WSL2Error]@{
                    Timestamp = Get-Date
                    Severity = [ErrorSeverity]::Critical
                    Source = "Performance/Memory"
                    Message = "High memory usage detected: $([math]::Round($memPercent, 2))%"
                    Details = @{
                        Type = "Memory"
                        Value = $memPercent
                        Threshold = 95
                        Unit = "percent"
                    }
                }

                $anomalies += $error
            }
        }

        # Check disk I/O latency (write test > 1 second)
        $ioCmd = "dd if=/dev/zero of=/tmp/test_io bs=1M count=100 oflag=direct 2>&1 | grep 'copied' | awk '{print `$(NF-1)}'"
        $ioTime = Invoke-Expression "wsl $distroArg -- bash -c `"$ioCmd`"" 2>&1

        if ($LASTEXITCODE -eq 0 -and $ioTime) {
            $ioSeconds = [double]$ioTime

            if ($ioSeconds -gt 1.0) {
                $error = [WSL2Error]@{
                    Timestamp = Get-Date
                    Severity = [ErrorSeverity]::Warning
                    Source = "Performance/DiskIO"
                    Message = "High disk I/O latency detected: $([math]::Round($ioSeconds, 2))s for 100MB write"
                    Details = @{
                        Type = "DiskIO"
                        Value = $ioSeconds
                        Threshold = 1.0
                        Unit = "seconds"
                        Operation = "100MB sequential write"
                    }
                }

                $anomalies += $error
            }

            # Clean up test file
            Invoke-Expression "wsl $distroArg -- rm -f /tmp/test_io" 2>&1 | Out-Null
        }

        # Check for WSL processes consuming excessive resources
        $topCmd = "ps aux --sort=-%cpu | head -11 | tail -10"
        $topProcesses = Invoke-Expression "wsl $distroArg -- $topCmd" 2>&1

        if ($LASTEXITCODE -eq 0 -and $topProcesses) {
            $processLines = $topProcesses -split "`n" | Where-Object { $_.Trim() -ne "" }

            foreach ($line in $processLines) {
                # Parse ps output: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
                $fields = $line -split '\s+', 11

                if ($fields.Count -ge 11) {
                    $cpuUsageProc = [double]$fields[2]
                    $memUsageProc = [double]$fields[3]
                    $command = $fields[10]

                    if ($cpuUsageProc -gt 50 -or $memUsageProc -gt 30) {
                        $error = [WSL2Error]@{
                            Timestamp = Get-Date
                            Severity = [ErrorSeverity]::Info
                            Source = "Performance/Process"
                            Message = "High resource usage by process: $command (CPU: $cpuUsageProc%, MEM: $memUsageProc%)"
                            Details = @{
                                Type = "Process"
                                Command = $command
                                CPU = $cpuUsageProc
                                Memory = $memUsageProc
                                PID = $fields[1]
                            }
                        }

                        $anomalies += $error
                    }
                }
            }
        }

    } catch {
        Write-Warning "Failed to check performance anomalies: $_"
    }

    return $anomalies
}

<#
.SYNOPSIS
    Generates a comprehensive WSL2 error report.
.DESCRIPTION
    Combines all error detection functions into a single report.
.PARAMETER Hours
    Number of hours to look back (default: 24)
.PARAMETER Distribution
    WSL distribution name (default: default distribution)
.PARAMETER IncludePerformance
    Include performance anomaly checks (default: true)
.EXAMPLE
    Get-WSL2ErrorReport -Hours 48 -Distribution Ubuntu-22.04
#>
function Get-WSL2ErrorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [int]$Hours = 24,

        [Parameter(Mandatory=$false)]
        [string]$Distribution,

        [Parameter(Mandatory=$false)]
        [switch]$IncludePerformance = $true
    )

    Write-Host "Generating WSL2 Error Report..." -ForegroundColor Cyan
    Write-Host "Time Range: Last $Hours hours" -ForegroundColor Gray
    Write-Host ""

    $report = [PSCustomObject]@{
        GeneratedAt = Get-Date
        TimeRangeHours = $Hours
        Distribution = if ($Distribution) { $Distribution } else { "Default" }
        WindowsErrors = @()
        LinuxErrors = @()
        ServiceRestarts = @()
        VirtiofsStatus = $null
        PerformanceAnomalies = @()
        Summary = @{
            TotalErrors = 0
            CriticalCount = 0
            WarningCount = 0
            InfoCount = 0
        }
    }

    # Collect Windows errors
    Write-Host "Checking Windows Event Log..." -ForegroundColor Yellow
    $report.WindowsErrors = Get-WSL2Errors -Hours $Hours
    Write-Host "  Found $($report.WindowsErrors.Count) Windows events" -ForegroundColor Gray

    # Collect Linux errors
    Write-Host "Checking Linux systemd journal..." -ForegroundColor Yellow
    $linuxParams = @{ Hours = $Hours }
    if ($Distribution) { $linuxParams.Distribution = $Distribution }
    $report.LinuxErrors = Get-WSL2LinuxErrors @linuxParams
    Write-Host "  Found $($report.LinuxErrors.Count) Linux errors" -ForegroundColor Gray

    # Collect service restarts
    Write-Host "Checking service restarts..." -ForegroundColor Yellow
    $restartParams = @{}
    if ($Distribution) { $restartParams.Distribution = $Distribution }
    $report.ServiceRestarts = Get-WSL2ServiceRestarts @restartParams
    Write-Host "  Found $($report.ServiceRestarts.Count) service restart events" -ForegroundColor Gray

    # Check virtiofs status
    Write-Host "Checking virtiofs status..." -ForegroundColor Yellow
    $virtiofsParams = @{}
    if ($Distribution) { $virtiofsParams.Distribution = $Distribution }
    $report.VirtiofsStatus = Get-WSL2VirtiofsStatus @virtiofsParams
    Write-Host "  Status: $($report.VirtiofsStatus.Status)" -ForegroundColor Gray

    # Check performance anomalies
    if ($IncludePerformance) {
        Write-Host "Checking performance anomalies..." -ForegroundColor Yellow
        $perfParams = @{}
        if ($Distribution) { $perfParams.Distribution = $Distribution }
        $report.PerformanceAnomalies = Test-WSL2PerformanceAnomaly @perfParams
        Write-Host "  Found $($report.PerformanceAnomalies.Count) anomalies" -ForegroundColor Gray
    }

    # Calculate summary
    $allErrors = $report.WindowsErrors + $report.LinuxErrors + $report.ServiceRestarts + $report.VirtiofsStatus.Errors + $report.PerformanceAnomalies
    $report.Summary.TotalErrors = $allErrors.Count
    $report.Summary.CriticalCount = ($allErrors | Where-Object { $_.Severity -eq [ErrorSeverity]::Critical }).Count
    $report.Summary.WarningCount = ($allErrors | Where-Object { $_.Severity -eq [ErrorSeverity]::Warning }).Count
    $report.Summary.InfoCount = ($allErrors | Where-Object { $_.Severity -eq [ErrorSeverity]::Info }).Count

    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Total Errors: $($report.Summary.TotalErrors)" -ForegroundColor White
    Write-Host "  Critical: $($report.Summary.CriticalCount)" -ForegroundColor Red
    Write-Host "  Warning: $($report.Summary.WarningCount)" -ForegroundColor Yellow
    Write-Host "  Info: $($report.Summary.InfoCount)" -ForegroundColor Gray

    return $report
}

# Export module members
Export-ModuleMember -Function @(
    'Get-WSL2Errors',
    'Get-WSL2LinuxErrors',
    'Get-WSL2ServiceRestarts',
    'Get-WSL2VirtiofsStatus',
    'Test-WSL2PerformanceAnomaly',
    'Get-WSL2ErrorReport'
)
