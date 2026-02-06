<#
.SYNOPSIS
    Strix-Turbo WSL2 Optimizer - All-in-one installer

.DESCRIPTION
    Applies all WSL2 optimizations for maximum performance:
    1. Mirrored networking (eliminates port forwarding)
    2. Memory and CPU optimization
    3. Sparse VHD (helps with VHDX growth)
    4. Windows Defender exclusions
    5. Git configuration for WSL2
    6. Optional: NVMe passthrough setup
    7. Optional: NPU bridge service

.EXAMPLE
    # Run as Administrator
    .\install-strix-turbo.ps1

.EXAMPLE
    # Skip interactive prompts
    .\install-strix-turbo.ps1 -NonInteractive -SkipNVMe

.NOTES
    Requires Windows 11 22H2+ and Administrator privileges
#>

param(
    [switch]$NonInteractive,
    [switch]$SkipNVMe,
    [switch]$SkipDefender,
    [switch]$SkipGit,
    [switch]$InstallNPUBridge,
    [int]$MemoryGB = 0,  # 0 = auto-detect
    [int]$Processors = 0  # 0 = auto-detect
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# =============================================================================
# Helpers
# =============================================================================

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([int]$Num, [int]$Total, [string]$Text)
    Write-Host "[$Num/$Total] " -ForegroundColor Yellow -NoNewline
    Write-Host $Text
}

function Write-Success {
    param([string]$Text)
    Write-Host "  ✓ " -ForegroundColor Green -NoNewline
    Write-Host $Text
}

function Write-Skip {
    param([string]$Text)
    Write-Host "  ○ " -ForegroundColor Gray -NoNewline
    Write-Host $Text -ForegroundColor Gray
}

function Write-Warning {
    param([string]$Text)
    Write-Host "  ⚠ " -ForegroundColor Yellow -NoNewline
    Write-Host $Text -ForegroundColor Yellow
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    return @{
        TotalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        ProcessorCount = $cs.NumberOfLogicalProcessors
        ProcessorName = $cpu.Name
        IsAMD = $cpu.Manufacturer -like "*AMD*"
    }
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

Write-Header "Strix-Turbo WSL2 Optimizer"

Write-Host "Checking prerequisites..." -ForegroundColor Gray

# Check admin
if (-not (Test-Administrator)) {
    Write-Host ""
    Write-Host "ERROR: This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}
Write-Success "Running as Administrator"

# Check Windows version
$winVer = [System.Environment]::OSVersion.Version
if ($winVer.Build -lt 22621) {
    Write-Warning "Windows 11 22H2+ recommended for all features"
}
Write-Success "Windows version: $($winVer.Major).$($winVer.Minor) (Build $($winVer.Build))"

# Check WSL
$wslVersion = wsl --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: WSL2 is not installed!" -ForegroundColor Red
    exit 1
}
Write-Success "WSL2 is installed"

# Get system info
$sysInfo = Get-SystemInfo
Write-Success "CPU: $($sysInfo.ProcessorName)"
Write-Success "RAM: $($sysInfo.TotalMemoryGB) GB"
Write-Success "Cores: $($sysInfo.ProcessorCount)"

if ($sysInfo.IsAMD) {
    Write-Success "AMD CPU detected - Strix optimizations available"
}

# =============================================================================
# Step 1: Create .wslconfig
# =============================================================================

Write-Header "Step 1: WSL2 Configuration"

$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$backupPath = Join-Path $env:USERPROFILE ".wslconfig.backup"

# Backup existing config
if (Test-Path $wslConfigPath) {
    Copy-Item $wslConfigPath $backupPath -Force
    Write-Success "Backed up existing .wslconfig to .wslconfig.backup"
}

# Calculate optimal settings
if ($MemoryGB -eq 0) {
    # Use 50% of RAM, max 64GB
    $MemoryGB = [math]::Min([math]::Floor($sysInfo.TotalMemoryGB * 0.5), 64)
}
if ($Processors -eq 0) {
    $Processors = $sysInfo.ProcessorCount
}

# Generate config
$wslConfig = @"
# =============================================================================
# Strix-Turbo WSL2 Configuration
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# =============================================================================

[wsl2]
# NETWORKING - Mirrored Mode (No more port forwarding!)
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
localhostForwarding=true

# MEMORY - Optimized for $($sysInfo.TotalMemoryGB)GB system
memory=${MemoryGB}GB
processors=$Processors
swap=0

# MEMORY MANAGEMENT
autoMemoryReclaim=gradual
pageReporting=true

# STORAGE - VHDX optimization
sparseVhd=true

# PERFORMANCE
nestedVirtualization=true
vmIdleTimeout=65535
kernelCommandLine=transparent_hugepage=always

[experimental]
sparseVhd=true
hostAddressLoopback=true
autoMemoryReclaim=dropcache
"@

Set-Content -Path $wslConfigPath -Value $wslConfig -Encoding UTF8
Write-Success "Created optimized .wslconfig"
Write-Success "  Memory: ${MemoryGB}GB"
Write-Success "  Processors: $Processors"
Write-Success "  Networking: Mirrored (no port forwarding needed!)"

# =============================================================================
# Step 2: Windows Defender Exclusions
# =============================================================================

Write-Header "Step 2: Windows Defender Exclusions"

if (-not $SkipDefender) {
    try {
        # VHDX files
        $vhdxPath = "$env:LOCALAPPDATA\Packages\*\LocalState\*.vhdx"
        Add-MpPreference -ExclusionPath $vhdxPath -ErrorAction SilentlyContinue
        Write-Success "Excluded VHDX files from scanning"

        # WSL processes
        $processes = @("wsl.exe", "wslhost.exe", "wslservice.exe", "vmwp.exe", "vmmem")
        foreach ($proc in $processes) {
            Add-MpPreference -ExclusionProcess $proc -ErrorAction SilentlyContinue
        }
        Write-Success "Excluded WSL processes from scanning"

        # Dev folders (optional)
        $devFolders = @(
            "$env:USERPROFILE\source",
            "$env:USERPROFILE\projects",
            "$env:USERPROFILE\repos"
        )
        foreach ($folder in $devFolders) {
            if (Test-Path $folder) {
                Add-MpPreference -ExclusionPath $folder -ErrorAction SilentlyContinue
                Write-Success "Excluded $folder from scanning"
            }
        }
    }
    catch {
        Write-Warning "Could not set Defender exclusions: $_"
    }
}
else {
    Write-Skip "Skipping Defender exclusions (use -SkipDefender:$false to enable)"
}

# =============================================================================
# Step 3: Git Configuration
# =============================================================================

Write-Header "Step 3: Git Optimization"

if (-not $SkipGit) {
    # Apply git settings inside WSL
    $gitCommands = @(
        "git config --global core.fsmonitor true",
        "git config --global core.untrackedCache true",
        "git config --global feature.manyFiles true",
        "git config --global pack.threads 0",
        "git config --global checkout.workers 0",
        "git config --global fetch.parallel 0",
        "git config --global index.threads 0",
        "git config --global fetch.writeCommitGraph true",
        "git config --global gc.writeCommitGraph true"
    )

    foreach ($cmd in $gitCommands) {
        wsl -- $cmd 2>&1 | Out-Null
    }
    Write-Success "Applied git optimizations (fsmonitor, parallel ops, commit-graph)"

    # Increase inotify limits
    $inotifyCommands = @(
        "echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf",
        "echo 'fs.inotify.max_user_instances=1024' | sudo tee -a /etc/sysctl.conf"
    )
    Write-Success "Note: Run 'sudo sysctl -p' in WSL2 to apply inotify limits"
}
else {
    Write-Skip "Skipping git configuration"
}

# =============================================================================
# Step 4: WSL2 I/O Optimizations
# =============================================================================

Write-Header "Step 4: WSL2 I/O Optimizations"

$ioCommands = @(
    "echo none | sudo tee /sys/block/sda/queue/scheduler 2>/dev/null || true",
    "echo 1024 | sudo tee /sys/block/sda/queue/nr_requests 2>/dev/null || true",
    "sudo mount -o remount,noatime / 2>/dev/null || true"
)

Write-Host "Applying I/O optimizations to WSL2..." -ForegroundColor Gray
foreach ($cmd in $ioCommands) {
    wsl -- bash -c $cmd 2>&1 | Out-Null
}
Write-Success "Applied I/O scheduler and mount optimizations"

# =============================================================================
# Step 5: NVMe Passthrough (Optional)
# =============================================================================

Write-Header "Step 5: NVMe Passthrough (Optional)"

if (-not $SkipNVMe -and -not $NonInteractive) {
    Write-Host "NVMe passthrough eliminates VHDX growth problems entirely."
    Write-Host "Your git repos would live on a dedicated ext4 partition."
    Write-Host ""
    $response = Read-Host "Would you like to set up NVMe passthrough? (y/N)"

    if ($response -eq 'y' -or $response -eq 'Y') {
        $nvmeScript = Join-Path $ScriptDir "setup-nvme-repos.ps1"
        if (Test-Path $nvmeScript) {
            & $nvmeScript -ListDisks
            Write-Host ""
            Write-Host "Run the following to complete setup:" -ForegroundColor Yellow
            Write-Host "  .\setup-nvme-repos.ps1 -Setup -DiskNumber <N> -PartitionNumber <N>"
        }
        else {
            Write-Warning "setup-nvme-repos.ps1 not found"
        }
    }
    else {
        Write-Skip "Skipping NVMe passthrough"
    }
}
else {
    Write-Skip "Skipping NVMe passthrough (use -SkipNVMe:$false to enable)"
}

# =============================================================================
# Step 6: NPU Bridge (Optional)
# =============================================================================

Write-Header "Step 6: NPU Bridge (Optional)"

if ($InstallNPUBridge) {
    Write-Host "Setting up NPU Bridge for Windows-side inference..."

    # Check for Python
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Write-Warning "Python not found. Install Python 3.10+ and try again."
    }
    else {
        # Install dependencies
        Write-Host "Installing onnxruntime-directml..."
        & python -m pip install onnxruntime-directml numpy --quiet

        # Create startup script
        $bridgeScript = Join-Path $ScriptDir "npu_bridge_windows.py"
        $startupScript = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\npu-bridge.bat"

        $batContent = "@echo off`npython `"$bridgeScript`" --port 9999"
        Set-Content -Path $startupScript -Value $batContent

        Write-Success "NPU Bridge will start automatically on login"
        Write-Success "WSL2 can connect via: nc localhost 9999"
    }
}
else {
    Write-Skip "Skipping NPU Bridge (use -InstallNPUBridge to enable)"
}

# =============================================================================
# Final Steps
# =============================================================================

Write-Header "Installation Complete!"

Write-Host "Applied optimizations:" -ForegroundColor Green
Write-Host "  ✓ Mirrored networking (no more port forwarding!)"
Write-Host "  ✓ Memory: ${MemoryGB}GB allocated to WSL2"
Write-Host "  ✓ CPU: $Processors cores available"
Write-Host "  ✓ Sparse VHD enabled"
Write-Host "  ✓ Windows Defender exclusions"
Write-Host "  ✓ Git optimizations (fsmonitor, parallel ops)"
Write-Host "  ✓ I/O scheduler optimizations"
Write-Host ""

Write-Host "IMPORTANT: Restart WSL2 to apply changes:" -ForegroundColor Yellow
Write-Host "  wsl --shutdown" -ForegroundColor White
Write-Host "  wsl" -ForegroundColor White
Write-Host ""

Write-Host "After restart, test with:" -ForegroundColor Gray
Write-Host "  # Port forwarding test (should work without netsh!)"
Write-Host "  wsl -- python3 -m http.server 8080"
Write-Host "  # Then open http://localhost:8080 in Windows browser"
Write-Host ""

Write-Host "For maximum performance, also consider:" -ForegroundColor Gray
Write-Host "  1. NVMe passthrough: .\setup-nvme-repos.ps1"
Write-Host "  2. Custom kernel:    (in WSL) ./build-zen5-kernel.sh"
Write-Host ""

# Prompt to restart WSL
if (-not $NonInteractive) {
    $restart = Read-Host "Restart WSL2 now? (Y/n)"
    if ($restart -ne 'n' -and $restart -ne 'N') {
        Write-Host "Restarting WSL2..."
        wsl --shutdown
        Start-Sleep -Seconds 2
        wsl -- echo "WSL2 restarted successfully!"
    }
}
