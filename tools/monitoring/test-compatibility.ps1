<#
.SYNOPSIS
    Test script for WSL2-TrayMonitor PowerShell compatibility

.DESCRIPTION
    Validates that WSL2-TrayMonitor.ps1 can initialize properly and checks
    for PowerShell version compatibility issues.
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

Write-Host "=== WSL2-TrayMonitor Compatibility Test ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: PowerShell Version
Write-Host "[Test 1] Checking PowerShell Version..." -ForegroundColor Yellow
Write-Host "  Version: $($PSVersionTable.PSVersion)"
Write-Host "  Edition: $($PSVersionTable.PSEdition)"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Warning "  PowerShell 7+ detected. Windows Forms may have compatibility issues."
    Write-Host "  Recommendation: Use Windows PowerShell 5.1" -ForegroundColor Yellow
} else {
    Write-Host "  ✓ Windows PowerShell 5.1 - Compatible" -ForegroundColor Green
}
Write-Host ""

# Test 2: Apartment State
Write-Host "[Test 2] Checking Apartment State..." -ForegroundColor Yellow
$apartmentState = [Threading.Thread]::CurrentThread.GetApartmentState()
Write-Host "  Current State: $apartmentState"

if ($apartmentState -eq 'STA') {
    Write-Host "  ✓ STA mode - Required for Windows Forms" -ForegroundColor Green
} else {
    Write-Host "  ✗ Not STA mode - Script will fail" -ForegroundColor Red
    Write-Host "  Fix: Launch with 'powershell.exe -STA'" -ForegroundColor Yellow
}
Write-Host ""

# Test 3: Assembly Loading
Write-Host "[Test 3] Testing Windows Forms Assembly Loading..." -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Write-Host "  ✓ Assemblies loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to load assemblies: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 4: Simple Form Creation
Write-Host "[Test 4] Testing Windows Forms Control Creation..." -ForegroundColor Yellow
try {
    $testForm = New-Object System.Windows.Forms.Form
    $testForm.Text = "Test"
    $testForm.Size = New-Object System.Drawing.Size(100, 100)
    $testForm.Dispose()
    Write-Host "  ✓ Form created and disposed successfully" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to create form: $_" -ForegroundColor Red
    Write-Host "  Exception Type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 5: Event Handler Test
Write-Host "[Test 5] Testing Event Handler Compatibility..." -ForegroundColor Yellow
try {
    $testButton = New-Object System.Windows.Forms.Button
    $testButton.Add_Click({
        try {
            Write-Verbose "Event handler executed"
        } catch {
            throw
        }
    })
    # Trigger event (won't actually click, just test wiring)
    Write-Host "  ✓ Event handler attached successfully" -ForegroundColor Green
    $testButton.Dispose()
} catch {
    Write-Host "  ✗ Failed to attach event handler: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 6: NotifyIcon Test
Write-Host "[Test 6] Testing NotifyIcon Creation..." -ForegroundColor Yellow
try {
    $testIcon = New-Object System.Windows.Forms.NotifyIcon
    $testIcon.Icon = [System.Drawing.SystemIcons]::Information
    $testIcon.Visible = $false
    $testIcon.Dispose()
    Write-Host "  ✓ NotifyIcon created successfully" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to create NotifyIcon: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 7: Timer Test
Write-Host "[Test 7] Testing Timer Creation..." -ForegroundColor Yellow
try {
    $testTimer = New-Object System.Windows.Forms.Timer
    $testTimer.Interval = 1000
    $testTimer.Add_Tick({
        try {
            Write-Verbose "Timer tick"
        } catch {
            throw
        }
    })
    $testTimer.Dispose()
    Write-Host "  ✓ Timer created successfully" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to create timer: $_" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 8: Script Syntax Check
Write-Host "[Test 8] Validating Script Syntax..." -ForegroundColor Yellow
$scriptPath = Join-Path $PSScriptRoot "WSL2-TrayMonitor.ps1"
if (Test-Path $scriptPath) {
    try {
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content $scriptPath -Raw),
            [ref]$null
        )
        Write-Host "  ✓ Script syntax is valid" -ForegroundColor Green
    } catch {
        Write-Host "  ✗ Script has syntax errors: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ✗ Script not found at: $scriptPath" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Summary
Write-Host "=== Test Summary ===" -ForegroundColor Cyan
if ($apartmentState -eq 'STA' -and $PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "✓ All compatibility checks passed" -ForegroundColor Green
    Write-Host "  The tray monitor should work correctly" -ForegroundColor Green
} elseif ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "⚠ PowerShell 7+ detected" -ForegroundColor Yellow
    Write-Host "  Tray monitor may experience issues" -ForegroundColor Yellow
    Write-Host "  Recommended: Use Windows PowerShell 5.1" -ForegroundColor Yellow
} elseif ($apartmentState -ne 'STA') {
    Write-Host "✗ STA mode required" -ForegroundColor Red
    Write-Host "  Launch with: powershell.exe -STA" -ForegroundColor Yellow
} else {
    Write-Host "⚠ Some issues detected" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Recommended Launch Command:" -ForegroundColor Cyan
Write-Host "  powershell.exe -STA -ExecutionPolicy Bypass -File `"$scriptPath`"" -ForegroundColor White
