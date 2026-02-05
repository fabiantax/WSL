<#
.SYNOPSIS
    WSL2 Performance Monitoring Module

.DESCRIPTION
    Provides comprehensive performance monitoring for WSL2 including CPU, memory,
    disk I/O, network I/O, process states, and health checks.

.NOTES
    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.
#>

# Performance counter cache to track historical data
$script:PerformanceHistory = @{
    CpuSamples = [System.Collections.Generic.List[object]]::new()
    LastCheck = $null
}

<#
.SYNOPSIS
    Gets current WSL2 performance metrics

.DESCRIPTION
    Retrieves CPU usage, memory usage, disk I/O, and network I/O for WSL2 processes
    and the WSL2 VM (Vmmem).

.PARAMETER IncludeHistory
    Include historical samples for trend analysis

.EXAMPLE
    Get-WSL2Performance
    Returns current performance metrics

.EXAMPLE
    Get-WSL2Performance -IncludeHistory
    Returns current metrics with historical trend data
#>
function Get-WSL2Performance {
    [CmdletBinding()]
    param(
        [switch]$IncludeHistory
    )

    try {
        $result = [PSCustomObject]@{
            Timestamp = Get-Date
            Cpu = Get-WSL2CpuUsage
            Memory = Get-WSL2MemoryUsage
            DiskIO = Get-WSL2DiskIO
            NetworkIO = Get-WSL2NetworkIO
            ProcessStates = Get-WSL2ProcessStates
        }

        # Store in history
        if ($script:PerformanceHistory.CpuSamples.Count -ge 60) {
            $script:PerformanceHistory.CpuSamples.RemoveAt(0)
        }
        $script:PerformanceHistory.CpuSamples.Add($result)
        $script:PerformanceHistory.LastCheck = Get-Date

        if ($IncludeHistory) {
            $result | Add-Member -MemberType NoteProperty -Name History -Value $script:PerformanceHistory.CpuSamples
        }

        return $result
    }
    catch {
        Write-Error "Failed to get WSL2 performance: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Gets WSL2 status and health information

.DESCRIPTION
    Returns running distros, filesystem types, service status, and overall health rating.

.EXAMPLE
    Get-WSL2Status
    Returns comprehensive WSL2 status information
#>
function Get-WSL2Status {
    [CmdletBinding()]
    param()

    try {
        $distros = Get-WSL2Distros
        $filesystem = Get-WSL2FilesystemType
        $serviceStatus = Get-WSL2ServiceStatus
        $healthStatus = Get-WSL2HealthStatus

        $result = [PSCustomObject]@{
            Timestamp = Get-Date
            Distros = $distros
            Filesystem = $filesystem
            Services = $serviceStatus
            Health = $healthStatus
        }

        return $result
    }
    catch {
        Write-Error "Failed to get WSL2 status: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Tests if WSL2 is hung or experiencing issues

.DESCRIPTION
    Detects processes in uninterruptible sleep (D state), zombie processes,
    non-responsive services, and sustained high CPU usage.

.PARAMETER CpuThresholdPercent
    CPU threshold percentage for sustained high usage detection (default: 80)

.PARAMETER DurationMinutes
    Duration in minutes for sustained high CPU detection (default: 5)

.EXAMPLE
    Test-WSL2Hung
    Tests for WSL2 hang conditions with default thresholds

.EXAMPLE
    Test-WSL2Hung -CpuThresholdPercent 90 -DurationMinutes 10
    Tests with custom thresholds
#>
function Test-WSL2Hung {
    [CmdletBinding()]
    param(
        [int]$CpuThresholdPercent = 80,
        [int]$DurationMinutes = 5
    )

    try {
        $issues = [System.Collections.Generic.List[object]]::new()

        # Check for D state processes (uninterruptible sleep) via WSL
        $dStateProcesses = Test-WSL2DStateProcesses
        if ($dStateProcesses.Count -gt 0) {
            $issues.Add([PSCustomObject]@{
                Type = "DStateProcesses"
                Severity = "High"
                Description = "Processes stuck in uninterruptible sleep (D state)"
                Count = $dStateProcesses.Count
                Details = $dStateProcesses
            })
        }

        # Check for zombie processes
        $zombieProcesses = Test-WSL2ZombieProcesses
        if ($zombieProcesses.Count -gt 0) {
            $issues.Add([PSCustomObject]@{
                Type = "ZombieProcesses"
                Severity = "Medium"
                Description = "Zombie processes detected"
                Count = $zombieProcesses.Count
                Details = $zombieProcesses
            })
        }

        # Check for non-responsive services
        $serviceIssues = Test-WSL2ServiceResponsiveness
        if ($serviceIssues.Count -gt 0) {
            $issues.Add([PSCustomObject]@{
                Type = "UnresponsiveServices"
                Severity = "Critical"
                Description = "WSL services not responding"
                Count = $serviceIssues.Count
                Details = $serviceIssues
            })
        }

        # Check for sustained high CPU
        $highCpuIssue = Test-WSL2SustainedHighCpu -ThresholdPercent $CpuThresholdPercent -DurationMinutes $DurationMinutes
        if ($highCpuIssue) {
            $issues.Add($highCpuIssue)
        }

        $isHung = $issues.Count -gt 0

        $result = [PSCustomObject]@{
            Timestamp = Get-Date
            IsHung = $isHung
            IssueCount = $issues.Count
            Issues = $issues
            Summary = if ($isHung) { "WSL2 is experiencing issues" } else { "WSL2 is operating normally" }
        }

        return $result
    }
    catch {
        Write-Error "Failed to test WSL2 hung state: $_"
        return $null
    }
}

#region Private Helper Functions

function Get-WSL2CpuUsage {
    $wslProcesses = @('wslservice', 'wslhost', 'wsl', 'vmmem')
    $cpuData = @{}

    foreach ($procName in $wslProcesses) {
        try {
            $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if ($processes) {
                $totalCpu = ($processes | Measure-Object -Property CPU -Sum).Sum
                $cpuData[$procName] = [PSCustomObject]@{
                    ProcessCount = $processes.Count
                    TotalCpuSeconds = [math]::Round($totalCpu, 2)
                    AverageCpuPercent = if ($processes.Count -gt 0) {
                        [math]::Round(($processes | Measure-Object -Property CPU -Average).Average, 2)
                    } else { 0 }
                }
            }
            else {
                $cpuData[$procName] = $null
            }
        }
        catch {
            $cpuData[$procName] = $null
        }
    }

    return [PSCustomObject]$cpuData
}

function Get-WSL2MemoryUsage {
    try {
        $vmmem = Get-Process -Name vmmem -ErrorAction SilentlyContinue
        if ($vmmem) {
            return [PSCustomObject]@{
                WorkingSetMB = [math]::Round($vmmem.WorkingSet64 / 1MB, 2)
                PrivateMemoryMB = [math]::Round($vmmem.PrivateMemorySize64 / 1MB, 2)
                VirtualMemoryMB = [math]::Round($vmmem.VirtualMemorySize64 / 1MB, 2)
                PeakWorkingSetMB = [math]::Round($vmmem.PeakWorkingSet64 / 1MB, 2)
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-WSL2DiskIO {
    try {
        $wslProcesses = Get-Process -Name wslservice, wslhost, wsl, vmmem -ErrorAction SilentlyContinue
        if (-not $wslProcesses) {
            return $null
        }

        $totalReadBytes = 0
        $totalWriteBytes = 0

        foreach ($proc in $wslProcesses) {
            try {
                $perfCounter = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess = $($proc.Id)" -ErrorAction SilentlyContinue
                if ($perfCounter) {
                    # Note: These counters may not be available for all processes
                    $totalReadBytes += if ($perfCounter.IOReadBytesPerSec) { $perfCounter.IOReadBytesPerSec } else { 0 }
                    $totalWriteBytes += if ($perfCounter.IOWriteBytesPerSec) { $perfCounter.IOWriteBytesPerSec } else { 0 }
                }
            }
            catch {
                # Process may have exited, continue
            }
        }

        return [PSCustomObject]@{
            ReadMBPerSec = [math]::Round($totalReadBytes / 1MB, 2)
            WriteMBPerSec = [math]::Round($totalWriteBytes / 1MB, 2)
            TotalMBPerSec = [math]::Round(($totalReadBytes + $totalWriteBytes) / 1MB, 2)
        }
    }
    catch {
        return $null
    }
}

function Get-WSL2NetworkIO {
    try {
        # Network I/O is challenging to attribute specifically to WSL2
        # Return network counters for the WSL interface if available
        $wslAdapter = Get-NetAdapter -Name "*WSL*" -ErrorAction SilentlyContinue
        if ($wslAdapter) {
            $stats = Get-NetAdapterStatistics -Name $wslAdapter.Name -ErrorAction SilentlyContinue
            if ($stats) {
                return [PSCustomObject]@{
                    ReceivedMB = [math]::Round($stats.ReceivedBytes / 1MB, 2)
                    SentMB = [math]::Round($stats.SentBytes / 1MB, 2)
                    AdapterName = $wslAdapter.Name
                    Status = $wslAdapter.Status
                }
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-WSL2ProcessStates {
    $wslProcesses = Get-Process -Name wslservice, wslhost, wsl, vmmem -ErrorAction SilentlyContinue

    $states = @{
        Running = 0
        Hung = 0
        Zombie = 0
        Total = 0
    }

    if ($wslProcesses) {
        foreach ($proc in $wslProcesses) {
            $states.Total++

            if ($proc.Responding) {
                $states.Running++
            }
            else {
                $states.Hung++
            }

            # Check for zombie-like state (has exited but handle not closed)
            if ($proc.HasExited) {
                $states.Zombie++
            }
        }
    }

    return [PSCustomObject]$states
}

function Get-WSL2Distros {
    try {
        $output = & wsl --list --verbose 2>&1 | Out-String
        $lines = $output -split "`r?`n" | Where-Object { $_ -match '\S' }

        $distros = [System.Collections.Generic.List[object]]::new()

        # Skip header line
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*[\*\s]\s*(\S+)\s+(Stopped|Running)\s+(\d+)') {
                $distros.Add([PSCustomObject]@{
                    Name = $matches[1]
                    State = $matches[2]
                    Version = $matches[3]
                    IsDefault = $line.TrimStart().StartsWith('*')
                })
            }
        }

        return $distros
    }
    catch {
        return @()
    }
}

function Get-WSL2FilesystemType {
    try {
        $runningDistros = Get-WSL2Distros | Where-Object { $_.State -eq 'Running' }
        $filesystems = [System.Collections.Generic.List[object]]::new()

        foreach ($distro in $runningDistros) {
            try {
                $mountOutput = & wsl -d $distro.Name sh -c "mount | grep -E '(virtiofs|9p)' | head -5" 2>&1

                $hasVirtiofs = $mountOutput -match 'virtiofs'
                $has9p = $mountOutput -match '9p'

                $filesystems.Add([PSCustomObject]@{
                    Distro = $distro.Name
                    Type = if ($hasVirtiofs) { "virtiofs" } elseif ($has9p) { "9p" } else { "unknown" }
                    HasVirtiofs = $hasVirtiofs
                    Has9p = $has9p
                    Details = $mountOutput
                })
            }
            catch {
                $filesystems.Add([PSCustomObject]@{
                    Distro = $distro.Name
                    Type = "error"
                    Error = $_.Exception.Message
                })
            }
        }

        return $filesystems
    }
    catch {
        return @()
    }
}

function Get-WSL2ServiceStatus {
    $services = @('wslservice')
    $serviceStatus = [System.Collections.Generic.List[object]]::new()

    foreach ($svcName in $services) {
        try {
            # Check Windows service
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                $serviceStatus.Add([PSCustomObject]@{
                    Name = $svcName
                    Status = $svc.Status
                    StartType = $svc.StartType
                    IsRunning = $svc.Status -eq 'Running'
                })
            }
            else {
                # Service doesn't exist as Windows service, check process
                $proc = Get-Process -Name $svcName -ErrorAction SilentlyContinue
                $serviceStatus.Add([PSCustomObject]@{
                    Name = $svcName
                    Status = if ($proc) { "Running" } else { "Stopped" }
                    StartType = "Process"
                    IsRunning = $proc -ne $null
                })
            }
        }
        catch {
            $serviceStatus.Add([PSCustomObject]@{
                Name = $svcName
                Status = "Error"
                Error = $_.Exception.Message
                IsRunning = $false
            })
        }
    }

    return $serviceStatus
}

function Get-WSL2HealthStatus {
    $health = [PSCustomObject]@{
        Overall = "Green"
        Issues = [System.Collections.Generic.List[string]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
    }

    # Check if any distro is running
    $distros = Get-WSL2Distros
    $runningDistros = $distros | Where-Object { $_.State -eq 'Running' }

    if ($runningDistros.Count -eq 0 -and $distros.Count -gt 0) {
        $health.Warnings.Add("No distros currently running")
        $health.Overall = "Yellow"
    }

    # Check service status
    $services = Get-WSL2ServiceStatus
    $stoppedServices = $services | Where-Object { -not $_.IsRunning }

    if ($stoppedServices.Count -gt 0 -and $runningDistros.Count -gt 0) {
        $health.Issues.Add("WSL services stopped while distros are running")
        $health.Overall = "Red"
    }

    # Check memory usage
    $memory = Get-WSL2MemoryUsage
    if ($memory -and $memory.WorkingSetMB -gt 8192) {
        $health.Warnings.Add("High memory usage: $($memory.WorkingSetMB) MB")
        if ($health.Overall -eq "Green") {
            $health.Overall = "Yellow"
        }
    }

    # Check process states
    $procStates = Get-WSL2ProcessStates
    if ($procStates.Hung -gt 0) {
        $health.Issues.Add("$($procStates.Hung) hung processes detected")
        $health.Overall = "Red"
    }

    if ($procStates.Zombie -gt 0) {
        $health.Warnings.Add("$($procStates.Zombie) zombie processes detected")
        if ($health.Overall -eq "Green") {
            $health.Overall = "Yellow"
        }
    }

    return $health
}

function Test-WSL2DStateProcesses {
    $dStateProcs = [System.Collections.Generic.List[object]]::new()

    try {
        $distros = Get-WSL2Distros | Where-Object { $_.State -eq 'Running' }

        foreach ($distro in $distros) {
            try {
                $output = & wsl -d $distro.Name sh -c "ps aux | awk '\$8 == \"D\" {print \$2, \$11}'" 2>&1

                if ($output -and $output -match '\d+') {
                    $lines = $output -split "`n" | Where-Object { $_ -match '\S' }
                    foreach ($line in $lines) {
                        if ($line -match '^(\d+)\s+(.+)') {
                            $dStateProcs.Add([PSCustomObject]@{
                                Distro = $distro.Name
                                PID = $matches[1]
                                Command = $matches[2]
                            })
                        }
                    }
                }
            }
            catch {
                # Distro may not be accessible
            }
        }
    }
    catch {
        # WSL may not be available
    }

    return $dStateProcs
}

function Test-WSL2ZombieProcesses {
    $zombieProcs = [System.Collections.Generic.List[object]]::new()

    try {
        $distros = Get-WSL2Distros | Where-Object { $_.State -eq 'Running' }

        foreach ($distro in $distros) {
            try {
                $output = & wsl -d $distro.Name sh -c "ps aux | awk '\$8 == \"Z\" {print \$2, \$11}'" 2>&1

                if ($output -and $output -match '\d+') {
                    $lines = $output -split "`n" | Where-Object { $_ -match '\S' }
                    foreach ($line in $lines) {
                        if ($line -match '^(\d+)\s+(.+)') {
                            $zombieProcs.Add([PSCustomObject]@{
                                Distro = $distro.Name
                                PID = $matches[1]
                                Command = $matches[2]
                            })
                        }
                    }
                }
            }
            catch {
                # Distro may not be accessible
            }
        }
    }
    catch {
        # WSL may not be available
    }

    return $zombieProcs
}

function Test-WSL2ServiceResponsiveness {
    $issues = [System.Collections.Generic.List[object]]::new()

    $services = Get-WSL2ServiceStatus
    foreach ($svc in $services) {
        if ($svc.IsRunning) {
            # Check if process is responding
            $proc = Get-Process -Name $svc.Name -ErrorAction SilentlyContinue
            if ($proc -and -not $proc.Responding) {
                $issues.Add([PSCustomObject]@{
                    Service = $svc.Name
                    Issue = "Not responding"
                    ProcessId = $proc.Id
                })
            }
        }
    }

    return $issues
}

function Test-WSL2SustainedHighCpu {
    param(
        [int]$ThresholdPercent,
        [int]$DurationMinutes
    )

    # Check if we have enough history
    $cutoffTime = (Get-Date).AddMinutes(-$DurationMinutes)
    $relevantSamples = $script:PerformanceHistory.CpuSamples | Where-Object { $_.Timestamp -ge $cutoffTime }

    if ($relevantSamples.Count -lt 2) {
        return $null  # Not enough data
    }

    # Calculate average CPU across all WSL processes
    $highCpuCount = 0
    foreach ($sample in $relevantSamples) {
        $totalCpu = 0
        $processCount = 0

        if ($sample.Cpu.wslservice) { $totalCpu += $sample.Cpu.wslservice.AverageCpuPercent; $processCount++ }
        if ($sample.Cpu.wslhost) { $totalCpu += $sample.Cpu.wslhost.AverageCpuPercent; $processCount++ }
        if ($sample.Cpu.wsl) { $totalCpu += $sample.Cpu.wsl.AverageCpuPercent; $processCount++ }
        if ($sample.Cpu.vmmem) { $totalCpu += $sample.Cpu.vmmem.AverageCpuPercent; $processCount++ }

        if ($processCount -gt 0 -and ($totalCpu / $processCount) -ge $ThresholdPercent) {
            $highCpuCount++
        }
    }

    $highCpuPercentage = ($highCpuCount / $relevantSamples.Count) * 100

    if ($highCpuPercentage -ge 80) {  # 80% of samples show high CPU
        return [PSCustomObject]@{
            Type = "SustainedHighCpu"
            Severity = "High"
            Description = "Sustained high CPU usage detected"
            ThresholdPercent = $ThresholdPercent
            DurationMinutes = $DurationMinutes
            HighCpuPercentage = [math]::Round($highCpuPercentage, 2)
            SampleCount = $relevantSamples.Count
        }
    }

    return $null
}

#endregion

# Export public functions
Export-ModuleMember -Function @(
    'Get-WSL2Performance',
    'Get-WSL2Status',
    'Test-WSL2Hung'
)
