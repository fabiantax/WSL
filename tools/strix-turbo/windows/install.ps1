# Quick install script for WSL Performance Monitor
# Run: irm https://raw.githubusercontent.com/.../install.ps1 | iex

param(
    [switch]$NoAutoStart
)

$ErrorActionPreference = "Stop"

Write-Host @"
 __        ______  _       ____            __
 \ \      / / ___|| |     |  _ \ ___ _ __ / _|
  \ \ /\ / /\___ \| |     | |_) / _ \ '__| |_
   \ V  V /  ___) | |___  |  __/  __/ |  |  _|
    \_/\_/  |____/|_____| |_|   \___|_|  |_|

  WSL Performance Monitor - Installer
"@ -ForegroundColor Cyan

# Check if running as admin (not required but inform user)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Determine install location
$installPath = "$env:LOCALAPPDATA\Programs\WSLPerfMonitor"

Write-Host "`nInstalling to: $installPath" -ForegroundColor Yellow

# Check for existing installation
if (Test-Path "$installPath\WSLPerfMonitor.exe") {
    Write-Host "Existing installation found. Updating..." -ForegroundColor Gray
    # Kill running instance
    Get-Process WSLPerfMonitor -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

# Create directory
New-Item -ItemType Directory -Force -Path $installPath | Out-Null

# Check if we need to build or if there's a pre-built binary
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$publishedExe = "$scriptDir\publish\WSLPerfMonitor.exe"
$builtExe = "$scriptDir\bin\Release\net8.0-windows\win-x64\WSLPerfMonitor.exe"

if (Test-Path $publishedExe) {
    Write-Host "Copying published executable..." -ForegroundColor Gray
    Copy-Item $publishedExe $installPath -Force
}
elseif (Test-Path $builtExe) {
    Write-Host "Copying built executable..." -ForegroundColor Gray
    Copy-Item $builtExe $installPath -Force
}
else {
    Write-Host "Building from source..." -ForegroundColor Gray

    # Check for .NET SDK
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-Host "ERROR: .NET 8 SDK required. Install from https://dot.net" -ForegroundColor Red
        Write-Host "Or download pre-built release from GitHub." -ForegroundColor Yellow
        exit 1
    }

    Push-Location $scriptDir
    try {
        dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "$scriptDir\publish" 2>&1 | Out-Null
        if (Test-Path "$scriptDir\publish\WSLPerfMonitor.exe") {
            Copy-Item "$scriptDir\publish\WSLPerfMonitor.exe" $installPath -Force
        }
        else {
            throw "Build failed"
        }
    }
    finally {
        Pop-Location
    }
}

$exePath = "$installPath\WSLPerfMonitor.exe"
if (-not (Test-Path $exePath)) {
    Write-Host "ERROR: Installation failed - executable not found" -ForegroundColor Red
    exit 1
}

# Create Start Menu shortcut
Write-Host "Creating Start Menu shortcut..." -ForegroundColor Gray
$shell = New-Object -ComObject WScript.Shell
$startMenu = [Environment]::GetFolderPath("StartMenu")
$shortcut = $shell.CreateShortcut("$startMenu\Programs\WSL Performance Monitor.lnk")
$shortcut.TargetPath = $exePath
$shortcut.Description = "Monitor WSL2 filesystem performance"
$shortcut.WorkingDirectory = $installPath
$shortcut.Save()

# Create Startup shortcut (auto-start)
if (-not $NoAutoStart) {
    Write-Host "Enabling auto-start on login..." -ForegroundColor Gray
    $startup = [Environment]::GetFolderPath("Startup")
    $startupShortcut = $shell.CreateShortcut("$startup\WSL Performance Monitor.lnk")
    $startupShortcut.TargetPath = $exePath
    $startupShortcut.Description = "Monitor WSL2 filesystem performance"
    $startupShortcut.WorkingDirectory = $installPath
    $startupShortcut.Save()
}

# Done!
Write-Host "`n✓ Installation complete!" -ForegroundColor Green
Write-Host @"

  Location:    $exePath
  Start Menu:  WSL Performance Monitor
  Auto-start:  $(if ($NoAutoStart) { "Disabled" } else { "Enabled" })

  The monitor will:
  - Run in system tray
  - Warn when processes use slow /mnt/c paths
  - Help migrate projects to fast Linux filesystem

  Starting now...
"@ -ForegroundColor Gray

# Start the application
Start-Process $exePath

Write-Host "`nLook for the 'W' icon in your system tray!" -ForegroundColor Cyan
