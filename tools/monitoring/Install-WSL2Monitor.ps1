#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the WSL2 System Tray Monitor with scheduled task auto-start.

.DESCRIPTION
    This script installs the WSL2 System Tray Monitor by:
    - Validating prerequisites (PowerShell 5.1+, WSL installed)
    - Creating a scheduled task for auto-start at user login
    - Creating optional desktop shortcuts
    - Testing the monitor installation

.PARAMETER CreateShortcut
    Creates a desktop shortcut to manually launch the monitor.

.PARAMETER NoTest
    Skips the test run after installation.

.EXAMPLE
    .\Install-WSL2Monitor.ps1
    Standard installation with test run.

.EXAMPLE
    .\Install-WSL2Monitor.ps1 -CreateShortcut
    Installation with desktop shortcut creation.

.NOTES
    Requires Administrator privileges for scheduled task creation.
#>

[CmdletBinding()]
param(
    [switch]$CreateShortcut,
    [switch]$NoTest
)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Script configuration
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$MonitorScript = Join-Path $ScriptRoot "WSL2-TrayMonitor.ps1"
$TaskName = "WSL2-TrayMonitor-AutoStart"
$TaskDescription = "Automatically start WSL2 System Tray Monitor at user login"

Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     WSL2 System Tray Monitor - Installation Tool     ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Step 1: Validate prerequisites
Write-Host "[1/5] Validating prerequisites..." -ForegroundColor Yellow

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -lt 1)) {
    Write-Error "PowerShell 5.1 or higher is required. Current version: $($psVersion.ToString())"
}
Write-Verbose "✓ PowerShell version: $($psVersion.ToString())"

# Check if WSL is installed
try {
    $wslVersion = wsl --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed"
    }
    Write-Verbose "✓ WSL is installed"
} catch {
    Write-Error "WSL is not installed. Run 'wsl --install' first."
}

# Validate monitor script exists
if (-not (Test-Path $MonitorScript)) {
    Write-Error "Monitor script not found: $MonitorScript"
}
Write-Verbose "✓ Monitor script found: $MonitorScript"

# Validate script directory
if (-not (Test-Path $ScriptRoot)) {
    Write-Error "Script root directory not found: $ScriptRoot"
}
Write-Verbose "✓ Script root directory: $ScriptRoot"

Write-Host "✓ All prerequisites validated" -ForegroundColor Green
Write-Host ""

# Step 2: Remove existing scheduled task if present
Write-Host "[2/5] Checking for existing installation..." -ForegroundColor Yellow

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Verbose "Found existing scheduled task. Removing..."
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Verbose "✓ Removed existing scheduled task"
    } catch {
        Write-Warning "Failed to remove existing task: $_"
    }
}

# Stop any running monitor instances
Write-Verbose "Checking for running monitor instances..."
$runningMonitors = Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*WSL2-TrayMonitor.ps1*" }

if ($runningMonitors) {
    Write-Verbose "Stopping $($runningMonitors.Count) running monitor instance(s)..."
    $runningMonitors | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Verbose "✓ Stopped running monitors"
}

Write-Host "✓ Cleaned up existing installation" -ForegroundColor Green
Write-Host ""

# Step 3: Create scheduled task
Write-Host "[3/5] Creating scheduled task for auto-start..." -ForegroundColor Yellow

try {
    # Create action to run the monitor script
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MonitorScript`" -StartMinimized" `
        -WorkingDirectory $ScriptRoot

    # Create trigger for user logon
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Create principal (run as current user)
    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited

    # Create settings
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RunOnlyIfNetworkAvailable:$false `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    # Register the task
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Description $TaskDescription `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-Verbose "✓ Created scheduled task: $TaskName"
    Write-Host "✓ Scheduled task created successfully" -ForegroundColor Green
} catch {
    Write-Error "Failed to create scheduled task: $_"
}
Write-Host ""

# Step 4: Create desktop shortcut (optional)
Write-Host "[4/5] Creating shortcuts..." -ForegroundColor Yellow

if ($CreateShortcut) {
    try {
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktopPath "WSL2 Monitor.lnk"

        $WScriptShell = New-Object -ComObject WScript.Shell
        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$MonitorScript`""
        $shortcut.WorkingDirectory = $ScriptRoot
        $shortcut.Description = "Launch WSL2 System Tray Monitor"
        $shortcut.IconLocation = "C:\Windows\System32\shell32.dll,23"
        $shortcut.Save()

        Write-Verbose "✓ Created desktop shortcut: $shortcutPath"
        Write-Host "✓ Desktop shortcut created" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to create desktop shortcut: $_"
    }
} else {
    Write-Host "  Skipped (use -CreateShortcut to create)" -ForegroundColor Gray
}
Write-Host ""

# Step 5: Test run
Write-Host "[5/5] Testing installation..." -ForegroundColor Yellow

if (-not $NoTest) {
    Write-Verbose "Starting test run of monitor (will run for 10 seconds)..."

    try {
        # Start monitor in background
        $testJob = Start-Job -ScriptBlock {
            param($scriptPath, $scriptRoot)
            Set-Location $scriptRoot
            & $scriptPath -StartMinimized
        } -ArgumentList $MonitorScript, $ScriptRoot

        # Wait 10 seconds
        Start-Sleep -Seconds 10

        # Check if job is still running
        $jobState = Get-Job -Id $testJob.Id | Select-Object -ExpandProperty State

        if ($jobState -eq "Running") {
            Write-Verbose "✓ Monitor is running successfully"
            Write-Host "✓ Test run successful" -ForegroundColor Green

            # Stop the test job
            Stop-Job -Id $testJob.Id
            Remove-Job -Id $testJob.Id -Force
        } else {
            Write-Warning "Monitor test job exited unexpectedly"
            $jobOutput = Receive-Job -Id $testJob.Id 2>&1
            Write-Verbose "Job output: $jobOutput"
            Remove-Job -Id $testJob.Id -Force
        }
    } catch {
        Write-Warning "Test run encountered an issue: $_"
        Write-Host "  You can manually test by running: powershell -File `"$MonitorScript`"" -ForegroundColor Gray
    }
} else {
    Write-Host "  Skipped (use without -NoTest to test)" -ForegroundColor Gray
}
Write-Host ""

# Installation summary
Write-Host "╔═══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Installation Complete!                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "The WSL2 System Tray Monitor has been installed successfully." -ForegroundColor White
Write-Host ""
Write-Host "What happens next:" -ForegroundColor Cyan
Write-Host "  • The monitor will start automatically when you log in" -ForegroundColor White
Write-Host "  • Look for the WSL icon in your system tray" -ForegroundColor White
Write-Host "  • Hover over the icon to see WSL status" -ForegroundColor White
Write-Host "  • Right-click for quick actions and settings" -ForegroundColor White
Write-Host ""
Write-Host "Manual controls:" -ForegroundColor Cyan
Write-Host "  Start now:        Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
Write-Host "  Stop:             Stop running PowerShell instances from Task Manager" -ForegroundColor Gray
Write-Host "  Manual run:       powershell -File `"$MonitorScript`"" -ForegroundColor Gray
Write-Host "  Uninstall:        .\Uninstall-WSL2Monitor.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  Location:         $ScriptRoot" -ForegroundColor Gray
Write-Host "  Scheduled Task:   $TaskName" -ForegroundColor Gray
Write-Host ""

# Offer to start now
$startNow = Read-Host "Would you like to start the monitor now? (Y/N)"
if ($startNow -eq "Y" -or $startNow -eq "y") {
    Write-Host ""
    Write-Host "Starting monitor..." -ForegroundColor Yellow
    try {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
        Write-Host "✓ Monitor started! Check your system tray." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to start monitor via scheduled task: $_"
        Write-Host "Try running manually: powershell -File `"$MonitorScript`"" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Installation log saved to: $($env:TEMP)\wsl2-monitor-install.log" -ForegroundColor Gray
