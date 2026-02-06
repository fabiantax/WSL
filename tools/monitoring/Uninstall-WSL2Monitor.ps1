#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Uninstalls the WSL2 System Tray Monitor.

.DESCRIPTION
    This script removes the WSL2 System Tray Monitor by:
    - Stopping any running monitor instances
    - Removing the scheduled task
    - Removing desktop shortcuts
    - Preserving logs and settings (optional cleanup)

.PARAMETER RemoveLogs
    Also remove log files and settings from AppData.

.PARAMETER RemoveShortcuts
    Remove desktop shortcuts if present.

.EXAMPLE
    .\Uninstall-WSL2Monitor.ps1
    Standard uninstallation, preserving logs.

.EXAMPLE
    .\Uninstall-WSL2Monitor.ps1 -RemoveLogs -RemoveShortcuts
    Complete removal including logs and shortcuts.

.NOTES
    Requires Administrator privileges for scheduled task removal.
#>

[CmdletBinding()]
param(
    [switch]$RemoveLogs,
    [switch]$RemoveShortcuts
)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Script configuration
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "WSL2-TrayMonitor-AutoStart"
$LogPath = Join-Path $env:LOCALAPPDATA "WSL2-TrayMonitor"

Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   WSL2 System Tray Monitor - Uninstallation Tool     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Step 1: Stop running instances
Write-Host "[1/4] Stopping running monitor instances..." -ForegroundColor Yellow

$runningMonitors = Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
    Where-Object {
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
            $cmdLine -like "*WSL2-TrayMonitor.ps1*"
        } catch {
            $false
        }
    }

if ($runningMonitors) {
    Write-Verbose "Found $($runningMonitors.Count) running monitor instance(s)"
    foreach ($process in $runningMonitors) {
        Write-Verbose "  Stopping process ID: $($process.Id)"
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        } catch {
            Write-Warning "Failed to stop process $($process.Id): $_"
        }
    }

    # Wait for processes to fully terminate
    Start-Sleep -Seconds 2

    # Verify termination
    $stillRunning = Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
                $cmdLine -like "*WSL2-TrayMonitor.ps1*"
            } catch {
                $false
            }
        }

    if ($stillRunning) {
        Write-Warning "Some monitor processes are still running. You may need to terminate them manually."
    } else {
        Write-Verbose "✓ All monitor instances stopped"
        Write-Host "✓ Stopped running monitors" -ForegroundColor Green
    }
} else {
    Write-Verbose "No running monitor instances found"
    Write-Host "✓ No running monitors to stop" -ForegroundColor Green
}
Write-Host ""

# Step 2: Remove scheduled task
Write-Host "[2/4] Removing scheduled task..." -ForegroundColor Yellow

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Verbose "✓ Removed scheduled task: $TaskName"
        Write-Host "✓ Scheduled task removed" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to remove scheduled task: $_"
        Write-Host "  You may need to remove it manually from Task Scheduler" -ForegroundColor Gray
    }
} else {
    Write-Verbose "No scheduled task found"
    Write-Host "✓ No scheduled task to remove" -ForegroundColor Green
}
Write-Host ""

# Step 3: Remove shortcuts
Write-Host "[3/4] Removing shortcuts..." -ForegroundColor Yellow

if ($RemoveShortcuts) {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shortcutPaths = @(
        (Join-Path $desktopPath "WSL2 Monitor.lnk"),
        (Join-Path $desktopPath "WSL2-TrayMonitor.lnk")
    )

    $removed = 0
    foreach ($shortcut in $shortcutPaths) {
        if (Test-Path $shortcut) {
            try {
                Remove-Item $shortcut -Force -ErrorAction Stop
                Write-Verbose "✓ Removed shortcut: $shortcut"
                $removed++
            } catch {
                Write-Warning "Failed to remove shortcut: $shortcut - $_"
            }
        }
    }

    if ($removed -gt 0) {
        Write-Host "✓ Removed $removed shortcut(s)" -ForegroundColor Green
    } else {
        Write-Host "✓ No shortcuts found to remove" -ForegroundColor Green
    }
} else {
    Write-Host "  Skipped (use -RemoveShortcuts to remove)" -ForegroundColor Gray
}
Write-Host ""

# Step 4: Remove logs and settings
Write-Host "[4/4] Cleaning up logs and settings..." -ForegroundColor Yellow

if ($RemoveLogs) {
    if (Test-Path $LogPath) {
        try {
            # Show what will be removed
            $logFiles = Get-ChildItem -Path $LogPath -Recurse -File
            $logSize = ($logFiles | Measure-Object -Property Length -Sum).Sum / 1MB
            Write-Verbose "Found log directory: $LogPath"
            Write-Verbose "  Files: $($logFiles.Count)"
            Write-Verbose "  Size: $([math]::Round($logSize, 2)) MB"

            # Confirm removal
            Write-Host "  This will remove $($logFiles.Count) log files ($([math]::Round($logSize, 2)) MB)" -ForegroundColor Yellow
            $confirm = Read-Host "  Confirm removal? (Y/N)"

            if ($confirm -eq "Y" -or $confirm -eq "y") {
                Remove-Item -Path $LogPath -Recurse -Force -ErrorAction Stop
                Write-Verbose "✓ Removed log directory: $LogPath"
                Write-Host "✓ Logs and settings removed" -ForegroundColor Green
            } else {
                Write-Host "  Log removal cancelled" -ForegroundColor Gray
            }
        } catch {
            Write-Warning "Failed to remove logs: $_"
        }
    } else {
        Write-Verbose "No log directory found at: $LogPath"
        Write-Host "✓ No logs to remove" -ForegroundColor Green
    }
} else {
    if (Test-Path $LogPath) {
        Write-Host "  Logs preserved at: $LogPath" -ForegroundColor Gray
        Write-Host "  Use -RemoveLogs to remove them" -ForegroundColor Gray
    } else {
        Write-Host "  No logs found" -ForegroundColor Gray
    }
}
Write-Host ""

# Uninstallation summary
Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║            Uninstallation Complete!                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "The WSL2 System Tray Monitor has been uninstalled." -ForegroundColor White
Write-Host ""

if (-not $RemoveLogs -and (Test-Path $LogPath)) {
    Write-Host "Note: Logs are preserved at:" -ForegroundColor Cyan
    Write-Host "  $LogPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "To remove logs manually:" -ForegroundColor Cyan
    Write-Host "  Remove-Item -Path '$LogPath' -Recurse -Force" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "To reinstall:" -ForegroundColor Cyan
Write-Host "  .\Install-WSL2Monitor.ps1" -ForegroundColor Gray
Write-Host ""
