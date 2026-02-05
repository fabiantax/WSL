# Build WSL Performance Monitor
# Requires .NET 8 SDK

param(
    [switch]$Release,
    [switch]$Publish,
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "WSL Performance Monitor Build Script" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Check for .NET SDK
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Host "ERROR: .NET SDK not found. Install from https://dot.net" -ForegroundColor Red
    exit 1
}

$version = & dotnet --version
Write-Host "Using .NET SDK: $version" -ForegroundColor Gray

Push-Location $ScriptDir
try {
    if ($Publish) {
        Write-Host "`nPublishing self-contained executable..." -ForegroundColor Yellow
        dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o "$ScriptDir\publish"

        $exePath = "$ScriptDir\publish\WSLPerfMonitor.exe"
        if (Test-Path $exePath) {
            $size = [math]::Round((Get-Item $exePath).Length / 1MB, 1)
            Write-Host "`nBuild successful!" -ForegroundColor Green
            Write-Host "Output: $exePath ($size MB)" -ForegroundColor Gray

            if ($Install) {
                $installPath = "$env:LOCALAPPDATA\Programs\WSLPerfMonitor"
                Write-Host "`nInstalling to: $installPath" -ForegroundColor Yellow

                New-Item -ItemType Directory -Force -Path $installPath | Out-Null
                Copy-Item $exePath $installPath -Force

                # Create Start Menu shortcut
                $shell = New-Object -ComObject WScript.Shell
                $startMenu = [Environment]::GetFolderPath("StartMenu")
                $shortcut = $shell.CreateShortcut("$startMenu\Programs\WSL Performance Monitor.lnk")
                $shortcut.TargetPath = "$installPath\WSLPerfMonitor.exe"
                $shortcut.Description = "Monitor WSL2 filesystem performance"
                $shortcut.Save()

                # Create startup entry (optional)
                $startup = [Environment]::GetFolderPath("Startup")
                $startupShortcut = $shell.CreateShortcut("$startup\WSL Performance Monitor.lnk")
                $startupShortcut.TargetPath = "$installPath\WSLPerfMonitor.exe"
                $startupShortcut.Description = "Monitor WSL2 filesystem performance"
                $startupShortcut.Save()

                Write-Host "Installed!" -ForegroundColor Green
                Write-Host "  - Start Menu shortcut created" -ForegroundColor Gray
                Write-Host "  - Auto-start on login enabled" -ForegroundColor Gray
                Write-Host "`nRun from Start Menu or: $installPath\WSLPerfMonitor.exe" -ForegroundColor Cyan
            }
        }
    }
    elseif ($Release) {
        Write-Host "`nBuilding Release..." -ForegroundColor Yellow
        dotnet build -c Release
        Write-Host "Build successful!" -ForegroundColor Green
    }
    else {
        Write-Host "`nBuilding Debug..." -ForegroundColor Yellow
        dotnet build -c Debug
        Write-Host "Build successful!" -ForegroundColor Green
        Write-Host "Run: dotnet run" -ForegroundColor Gray
    }
}
finally {
    Pop-Location
}
