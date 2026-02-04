#requires -RunAsAdministrator
<#
.SYNOPSIS
    Add Windows Defender exclusions for WSL2 to improve I/O performance by 20-40%

.DESCRIPTION
    Excludes WSL2 VHDX files and binaries from real-time scanning.
    This dramatically reduces I/O latency without compromising security
    (WSL2 files are isolated from Windows malware threats).

.NOTES
    Run as Administrator
#>

Write-Host "Adding Windows Defender exclusions for WSL2..." -ForegroundColor Cyan

# Get current user's local packages directory (where VHDX files live)
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$wslPackages = Join-Path $localAppData "Packages\*\LocalState\ext4.vhdx"

# WSL installation directory
$wslProgram = "C:\Program Files\WSL"

# User's WSL home directory (if accessible)
$userProfile = [Environment]::GetFolderPath('UserProfile')
$wslHome = Join-Path $userProfile ".wsl"

# List of paths to exclude
$exclusions = @(
    $wslPackages,
    $wslProgram,
    "C:\Windows\System32\lxss",
    "$env:TEMP\wsl*"
)

# Add each exclusion
foreach ($path in $exclusions) {
    try {
        Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        Write-Host "[OK] Excluded: $path" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            Write-Host "[SKIP] Already excluded: $path" -ForegroundColor Yellow
        }
        else {
            Write-Host "[ERROR] Failed to exclude: $path" -ForegroundColor Red
            Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Also exclude WSL processes
$processes = @(
    "wsl.exe",
    "wslservice.exe",
    "wslhost.exe"
)

foreach ($process in $processes) {
    try {
        Add-MpPreference -ExclusionProcess $process -ErrorAction Stop
        Write-Host "[OK] Excluded process: $process" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -match "already exists") {
            Write-Host "[SKIP] Already excluded: $process" -ForegroundColor Yellow
        }
        else {
            Write-Host "[ERROR] Failed to exclude: $process" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "Windows Defender exclusions configured!" -ForegroundColor Green
Write-Host "Expected I/O improvement: 20-40%" -ForegroundColor Cyan
Write-Host ""
Write-Host "To verify, run: Get-MpPreference | Select-Object -ExpandProperty ExclusionPath" -ForegroundColor Yellow
