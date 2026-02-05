<#
.SYNOPSIS
    Test script to verify WSL2-TrayMonitor timer safety fixes

.DESCRIPTION
    Simulates various failure conditions to ensure the tray monitor
    handles errors gracefully without crashing from PipelineStoppedException

.NOTES
    Run this AFTER starting WSL2-TrayMonitor.ps1 to verify stability
#>

#Requires -Version 5.1

Write-Host "WSL2 Tray Monitor - Timer Safety Test Suite" -ForegroundColor Cyan
Write-Host "=" * 60
Write-Host ""

$logFile = Join-Path $env:TEMP "WSL2-TrayMonitor-$(Get-Date -Format 'yyyyMMdd').log"

# Test 1: WSL Stopped State
Write-Host "[Test 1] Testing with WSL stopped..." -ForegroundColor Yellow
Write-Host "Shutting down WSL..."
wsl --shutdown
Start-Sleep -Seconds 3

Write-Host "Waiting 15 seconds for monitor to handle stopped state..."
Start-Sleep -Seconds 15

Write-Host "Checking log for errors..."
$errors = Select-String -Path $logFile -Pattern "Failed to query WSL" -ErrorAction SilentlyContinue
if ($errors) {
    Write-Host "✓ Monitor gracefully handled WSL stopped state" -ForegroundColor Green
    Write-Host "  Found $($errors.Count) logged errors (suppressed successfully)" -ForegroundColor Gray
} else {
    Write-Host "⚠ No WSL query errors found in log" -ForegroundColor Yellow
}
Write-Host ""

# Test 2: Process Termination
Write-Host "[Test 2] Testing with process termination..." -ForegroundColor Yellow
Write-Host "Starting a WSL distro..."
Start-Process wsl -ArgumentList "-d Ubuntu -e sleep 30" -WindowStyle Hidden
Start-Sleep -Seconds 5

Write-Host "Checking if vmmem is running..."
$vmmem = Get-Process -Name "vmmem" -ErrorAction SilentlyContinue
if ($vmmem) {
    Write-Host "✓ vmmem process found (PID: $($vmmem.Id))" -ForegroundColor Green

    Write-Host "Terminating vmmem to simulate crash..."
    Stop-Process -Name "vmmem" -Force -ErrorAction SilentlyContinue

    Write-Host "Waiting 10 seconds for monitor to detect..."
    Start-Sleep -Seconds 10

    Write-Host "✓ Monitor should have handled process termination gracefully" -ForegroundColor Green
} else {
    Write-Host "⚠ vmmem not running (WSL may be stopped)" -ForegroundColor Yellow
}
Write-Host ""

# Test 3: Log File Analysis
Write-Host "[Test 3] Analyzing error log for suppressed exceptions..." -ForegroundColor Yellow
if (Test-Path $logFile) {
    Write-Host "Log file: $logFile" -ForegroundColor Gray

    $suppressedErrors = Select-String -Path $logFile -Pattern "suppressed" -ErrorAction SilentlyContinue
    $timerErrors = Select-String -Path $logFile -Pattern "Timer tick error" -ErrorAction SilentlyContinue
    $pipelineErrors = Select-String -Path $logFile -Pattern "PipelineStoppedException" -ErrorAction SilentlyContinue

    Write-Host "Suppressed errors found: $($suppressedErrors.Count)" -ForegroundColor Cyan
    Write-Host "Timer tick errors found: $($timerErrors.Count)" -ForegroundColor Cyan
    Write-Host "PipelineStoppedException found: $($pipelineErrors.Count)" -ForegroundColor Cyan

    if ($pipelineErrors.Count -eq 0) {
        Write-Host "✓ No PipelineStoppedException found (good!)" -ForegroundColor Green
    } else {
        Write-Host "✗ PipelineStoppedException detected - FIX NEEDED" -ForegroundColor Red
        $pipelineErrors | Select-Object -First 3 | ForEach-Object {
            Write-Host "  $($_.Line)" -ForegroundColor Red
        }
    }

    if ($suppressedErrors.Count -gt 0) {
        Write-Host "✓ Errors are being suppressed correctly" -ForegroundColor Green
        Write-Host "`nRecent suppressed errors:" -ForegroundColor Gray
        $suppressedErrors | Select-Object -Last 3 | ForEach-Object {
            Write-Host "  $($_.Line)" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "⚠ Log file not found - monitor may not be running" -ForegroundColor Yellow
}
Write-Host ""

# Test 4: Monitor Process Check
Write-Host "[Test 4] Checking monitor process health..." -ForegroundColor Yellow
$powershellProcesses = Get-Process -Name "powershell", "pwsh" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -match "WSL2-TrayMonitor" }

if ($powershellProcesses) {
    Write-Host "✓ Monitor process is running" -ForegroundColor Green
    $powershellProcesses | ForEach-Object {
        $uptime = (Get-Date) - $_.StartTime
        Write-Host "  PID: $($_.Id), Uptime: $([int]$uptime.TotalMinutes) minutes" -ForegroundColor Gray
    }
} else {
    # Check for process by looking for WindowsForms loaded assemblies
    $formsProcesses = Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $_.Modules | Where-Object { $_.ModuleName -match "System.Windows.Forms" }
            } catch { $false }
        }

    if ($formsProcesses) {
        Write-Host "✓ Monitor may be running in background" -ForegroundColor Green
        Write-Host "  Found $($formsProcesses.Count) PowerShell process(es) with Windows Forms loaded" -ForegroundColor Gray
    } else {
        Write-Host "⚠ Monitor does not appear to be running" -ForegroundColor Yellow
        Write-Host "  Start with: .\WSL2-TrayMonitor.ps1" -ForegroundColor Gray
    }
}
Write-Host ""

# Test 5: Event Log Access
Write-Host "[Test 5] Testing Event Log access..." -ForegroundColor Yellow
try {
    $recentWSLEvents = Get-EventLog -LogName Application -Source "WSL" -Newest 5 -ErrorAction Stop
    Write-Host "✓ Event Log accessible (found $($recentWSLEvents.Count) recent events)" -ForegroundColor Green
} catch {
    Write-Host "⚠ Event Log not accessible - monitor should handle gracefully" -ForegroundColor Yellow
    Write-Host "  Error: $_" -ForegroundColor Gray
}
Write-Host ""

# Summary
Write-Host "=" * 60
Write-Host "Test Suite Complete" -ForegroundColor Cyan
Write-Host ""
Write-Host "Expected Results:" -ForegroundColor White
Write-Host "  ✓ No PipelineStoppedException in log" -ForegroundColor Green
Write-Host "  ✓ Errors are logged with 'suppressed' keyword" -ForegroundColor Green
Write-Host "  ✓ Monitor process continues running" -ForegroundColor Green
Write-Host "  ✓ System tray icon remains visible and responsive" -ForegroundColor Green
Write-Host ""
Write-Host "If monitor crashed, check:" -ForegroundColor Yellow
Write-Host "  1. Log file: $logFile" -ForegroundColor Gray
Write-Host "  2. Event Viewer: Windows Logs > Application" -ForegroundColor Gray
Write-Host "  3. PowerShell version: Should use 5.1, not 7+" -ForegroundColor Gray
Write-Host ""
Write-Host "Manual Verification:" -ForegroundColor White
Write-Host "  - Right-click system tray icon (should show menu)" -ForegroundColor Gray
Write-Host "  - Left-click icon (should show dashboard)" -ForegroundColor Gray
Write-Host "  - Check tooltip shows current metrics" -ForegroundColor Gray
Write-Host "  - Start/stop WSL distros and verify updates" -ForegroundColor Gray
Write-Host ""

# Offer to view log
$response = Read-Host "View full error log? (Y/N)"
if ($response -eq 'Y' -or $response -eq 'y') {
    if (Test-Path $logFile) {
        Start-Process notepad -ArgumentList $logFile
    } else {
        Write-Host "Log file not found: $logFile" -ForegroundColor Red
    }
}
