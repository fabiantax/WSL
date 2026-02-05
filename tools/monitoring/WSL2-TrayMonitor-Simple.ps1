<#
.SYNOPSIS
    Minimal WSL2 system tray monitor - lightweight and stable.

.DESCRIPTION
    Provides basic WSL2 status monitoring in the Windows system tray.
    Features:
    - Simple process-based monitoring
    - 30-second refresh interval
    - Minimal resource usage
    - No complex dependencies
    - Robust error handling

.PARAMETER StartMinimized
    Start the monitor minimized to the system tray (always true for tray app).

.EXAMPLE
    .\WSL2-TrayMonitor-Simple.ps1

.NOTES
    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.
#>

param(
    [switch]$StartMinimized = $true
)

# Ensure we don't show console errors
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# Load required assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Script-level variables
$script:Icon = $null
$script:Timer = $null
$script:LastMetrics = $null

#region Helper Functions

<#
.SYNOPSIS
    Gets simple WSL2 metrics using process information only.
#>
function Get-SimpleMetrics {
    $result = @{
        IsRunning = $false
        CpuPercent = 0
        MemoryMB = 0
        ProcessCount = 0
        Timestamp = Get-Date
    }

    try {
        # Look for WSL-related processes
        $wslProcessNames = @('wsl', 'wslhost', 'wslservice', 'vmmem', 'wslrelay')
        $wslProcs = @()

        foreach ($procName in $wslProcessNames) {
            $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
            if ($procs) {
                $wslProcs += $procs
            }
        }

        if ($wslProcs.Count -gt 0) {
            $result.IsRunning = $true
            $result.ProcessCount = $wslProcs.Count

            # Calculate total CPU (already in seconds)
            $totalCpu = ($wslProcs | Measure-Object -Property CPU -Sum -ErrorAction SilentlyContinue).Sum
            if ($totalCpu) {
                $result.CpuPercent = [math]::Round($totalCpu, 2)
            }

            # Calculate total memory in MB
            $totalMemory = ($wslProcs | Measure-Object -Property WS -Sum -ErrorAction SilentlyContinue).Sum
            if ($totalMemory) {
                $result.MemoryMB = [math]::Round($totalMemory / 1MB, 0)
            }
        }
    } catch {
        # Silently continue on any errors
    }

    return $result
}

<#
.SYNOPSIS
    Updates the tray icon based on WSL2 status.
#>
function Update-TrayIcon {
    param($Metrics)

    try {
        if (-not $script:Icon) { return }

        # Update icon based on status
        if ($Metrics.IsRunning) {
            # Green icon for running
            $script:Icon.Icon = [System.Drawing.SystemIcons]::Information
        } else {
            # Gray icon for stopped
            $script:Icon.Icon = [System.Drawing.SystemIcons]::Shield
        }

        # Build tooltip (max 63 characters for Windows)
        $status = if ($Metrics.IsRunning) { "Running" } else { "Stopped" }
        $tooltip = "WSL2: $status | Mem: $($Metrics.MemoryMB)MB | Procs: $($Metrics.ProcessCount)"

        # Truncate if needed
        if ($tooltip.Length -gt 63) {
            $tooltip = $tooltip.Substring(0, 60) + "..."
        }

        $script:Icon.Text = $tooltip
    } catch {
        # Never throw - silently continue
    }
}

#endregion

#region Event Handlers

<#
.SYNOPSIS
    Timer tick handler - refreshes metrics every 30 seconds.
#>
function OnTimerTick {
    try {
        $ErrorActionPreference = 'SilentlyContinue'

        # Get current metrics
        $metrics = Get-SimpleMetrics
        $script:LastMetrics = $metrics

        # Update tray icon
        Update-TrayIcon -Metrics $metrics

    } catch {
        # Never throw from timer tick - just continue
    }
}

<#
.SYNOPSIS
    Icon click handler - shows current status.
#>
function OnIconClick {
    param($Sender, $Event)

    try {
        if ($Event.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:LastMetrics) {
                $status = if ($script:LastMetrics.IsRunning) { "Running" } else { "Stopped" }
                $msg = "WSL2 Status: $status`n"
                $msg += "Memory: $($script:LastMetrics.MemoryMB) MB`n"
                $msg += "Processes: $($script:LastMetrics.ProcessCount)`n"
                $msg += "Last Update: $($script:LastMetrics.Timestamp.ToString('HH:mm:ss'))"

                [System.Windows.Forms.MessageBox]::Show(
                    $msg,
                    "WSL2 Monitor",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            }
        }
    } catch {
        # Silently handle errors
    }
}

<#
.SYNOPSIS
    Exit handler - cleans up resources.
#>
function OnExit {
    try {
        if ($script:Timer) {
            $script:Timer.Stop()
            $script:Timer.Dispose()
        }

        if ($script:Icon) {
            $script:Icon.Visible = $false
            $script:Icon.Dispose()
        }

        [System.Windows.Forms.Application]::Exit()
    } catch {
        # Force exit even if cleanup fails
        [Environment]::Exit(0)
    }
}

#endregion

#region Main Application

<#
.SYNOPSIS
    Initializes and starts the tray monitor.
#>
function Start-TrayMonitor {
    try {
        # Create notify icon
        $script:Icon = New-Object System.Windows.Forms.NotifyIcon
        $script:Icon.Icon = [System.Drawing.SystemIcons]::Information
        $script:Icon.Text = "WSL2 Monitor - Starting..."
        $script:Icon.Visible = $true

        # Add click handler
        $script:Icon.Add_Click({ OnIconClick @args })

        # Create context menu
        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

        # Add "Refresh Now" menu item
        $refreshItem = $contextMenu.Items.Add("Refresh Now")
        $refreshItem.Add_Click({
            try {
                OnTimerTick
            } catch {
                # Silently handle errors
            }
        })

        # Add separator
        $contextMenu.Items.Add("-") | Out-Null

        # Add "Exit" menu item
        $exitItem = $contextMenu.Items.Add("Exit")
        $exitItem.Add_Click({ OnExit })

        $script:Icon.ContextMenuStrip = $contextMenu

        # Create and configure timer (30 second interval)
        $script:Timer = New-Object System.Windows.Forms.Timer
        $script:Timer.Interval = 30000  # 30 seconds
        $script:Timer.Add_Tick({ OnTimerTick })

        # Do initial update
        OnTimerTick

        # Start timer
        $script:Timer.Start()

        # Run application loop
        [System.Windows.Forms.Application]::Run()

    } catch {
        # If initialization fails, show error and exit
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to start WSL2 Monitor: $($_.Exception.Message)",
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit 1
    }
}

#endregion

# Start the monitor
Start-TrayMonitor
