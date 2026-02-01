# =============================================================================
# NVMe Passthrough Setup for WSL2 - Eliminate VHDX Forever
# =============================================================================
#
# This script sets up a dedicated NVMe partition for your git repos,
# completely bypassing the VHDX that grows but never shrinks.
#
# REQUIREMENTS:
#   - Windows 11 (WSL2 mount requires this)
#   - Admin privileges
#   - A spare partition or disk (at least 100GB recommended)
#
# WHAT THIS DOES:
#   1. Lists your NVMe drives
#   2. Helps you identify a partition to use
#   3. Mounts it into WSL2 as ext4
#   4. Creates a startup task to auto-mount
#
# Run as Administrator!
#
# =============================================================================

param(
    [switch]$ListDisks,
    [switch]$Setup,
    [string]$DiskNumber,
    [int]$PartitionNumber = 1,
    [string]$MountPoint = "/mnt/nvme-repos"
)

$ErrorActionPreference = "Stop"

function Write-Header {
    param([string]$Text)
    Write-Host "`n$("=" * 70)" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "$("=" * 70)`n" -ForegroundColor Cyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
# List Disks
# =============================================================================

if ($ListDisks -or (-not $Setup)) {
    Write-Header "Available Disks and Partitions"

    Write-Host "Physical Disks:" -ForegroundColor Yellow
    Get-CimInstance -Query "SELECT * from Win32_DiskDrive" |
        Format-Table DeviceID, Model, @{N='Size (GB)';E={[math]::Round($_.Size/1GB,2)}}, Partitions -AutoSize

    Write-Host "`nPartitions:" -ForegroundColor Yellow
    Get-Partition | Where-Object { $_.DriveLetter -or $_.Type -eq 'Basic' } |
        Format-Table DiskNumber, PartitionNumber, @{N='Size (GB)';E={[math]::Round($_.Size/1GB,2)}}, DriveLetter, Type -AutoSize

    Write-Host "`n" -NoNewline
    Write-Host "INSTRUCTIONS:" -ForegroundColor Green
    Write-Host "  1. Identify a partition you want to use for WSL2 repos"
    Write-Host "  2. OPTION A: Use an existing unformatted partition"
    Write-Host "  3. OPTION B: Shrink a Windows partition and create a new one"
    Write-Host "  4. Run this script again with -Setup -DiskNumber <N> -PartitionNumber <N>"
    Write-Host ""
    Write-Host "EXAMPLE:" -ForegroundColor Yellow
    Write-Host "  .\setup-nvme-repos.ps1 -Setup -DiskNumber 0 -PartitionNumber 3"
    Write-Host ""
    Write-Host "WARNING:" -ForegroundColor Red
    Write-Host "  - The partition will be formatted as ext4 (Linux filesystem)"
    Write-Host "  - Windows will NOT be able to read it directly"
    Write-Host "  - Back up any data on the partition first!"
    Write-Host ""

    exit 0
}

# =============================================================================
# Setup Mode
# =============================================================================

if (-not (Test-Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

if (-not $DiskNumber) {
    Write-Host "ERROR: Please specify -DiskNumber" -ForegroundColor Red
    Write-Host "Run with -ListDisks to see available disks"
    exit 1
}

Write-Header "Setting Up NVMe Passthrough for WSL2"

$PhysicalDrive = "\\.\PHYSICALDRIVE$DiskNumber"

# Confirm with user
Write-Host "About to set up:" -ForegroundColor Yellow
Write-Host "  Disk:      $PhysicalDrive"
Write-Host "  Partition: $PartitionNumber"
Write-Host "  Mount:     $MountPoint"
Write-Host ""
Write-Host "This will FORMAT the partition as ext4!" -ForegroundColor Red
$confirm = Read-Host "Type 'YES' to continue"
if ($confirm -ne "YES") {
    Write-Host "Aborted."
    exit 0
}

# Step 1: Mount bare
Write-Host "`n[1/5] Mounting disk bare into WSL2..." -ForegroundColor Green
try {
    wsl --mount $PhysicalDrive --bare
    Write-Host "  OK: Disk mounted bare" -ForegroundColor Gray
} catch {
    Write-Host "  ERROR: Failed to mount. Is WSL2 running?" -ForegroundColor Red
    exit 1
}

# Step 2: Format as ext4
Write-Host "`n[2/5] Formatting partition as ext4..." -ForegroundColor Green
$device = "/dev/sd" + [char]([int][char]'b' + [int]$DiskNumber) + $PartitionNumber

# Unmount first if mounted
wsl -- sudo umount $device 2>$null

# Format
$formatResult = wsl -- sudo mkfs.ext4 -F $device 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Format failed: $formatResult" -ForegroundColor Red
    wsl --unmount $PhysicalDrive
    exit 1
}
Write-Host "  OK: Formatted as ext4" -ForegroundColor Gray

# Unmount bare
wsl --unmount $PhysicalDrive

# Step 3: Mount with type
Write-Host "`n[3/5] Mounting partition with ext4 filesystem..." -ForegroundColor Green
try {
    wsl --mount $PhysicalDrive --partition $PartitionNumber --type ext4
    Write-Host "  OK: Mounted as ext4" -ForegroundColor Gray
} catch {
    Write-Host "  ERROR: Failed to mount as ext4" -ForegroundColor Red
    exit 1
}

# Step 4: Create mount point and fstab entry
Write-Host "`n[4/5] Creating mount point in WSL2..." -ForegroundColor Green
wsl -- sudo mkdir -p $MountPoint
wsl -- sudo chown $env:USERNAME:$env:USERNAME $MountPoint

# Get the actual device path inside WSL
$wslDevice = wsl -- lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | Select-String "ext4"
Write-Host "  Device in WSL: $wslDevice" -ForegroundColor Gray

# Step 5: Create startup task
Write-Header "Creating Startup Task"

$taskName = "WSL2-NVMe-Mount"
$taskAction = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "--mount $PhysicalDrive --partition $PartitionNumber --type ext4"
$taskTrigger = New-ScheduledTaskTrigger -AtStartup
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Register new task
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -RunLevel Highest -User "SYSTEM"

Write-Host "  OK: Created startup task '$taskName'" -ForegroundColor Gray

# =============================================================================
# Summary
# =============================================================================

Write-Header "Setup Complete!"

Write-Host "Your NVMe partition is now available in WSL2 at:" -ForegroundColor Green
Write-Host "  $MountPoint" -ForegroundColor Yellow
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Green
Write-Host "  1. Move your git repos to $MountPoint"
Write-Host "     cd $MountPoint"
Write-Host "     git clone your-repos..."
Write-Host ""
Write-Host "  2. Or move existing repos:"
Write-Host "     mv ~/projects/* $MountPoint/"
Write-Host "     ln -s $MountPoint ~/projects"
Write-Host ""
Write-Host "  3. The partition auto-mounts on Windows startup"
Write-Host ""
Write-Host "BENEFITS:" -ForegroundColor Green
Write-Host "  - No more VHDX growth problems"
Write-Host "  - Direct NVMe performance (no virtualization overhead)"
Write-Host "  - Can access from native Linux if you dual-boot"
Write-Host ""
Write-Host "TROUBLESHOOTING:" -ForegroundColor Yellow
Write-Host "  If mount fails after reboot, run manually:"
Write-Host "  wsl --mount $PhysicalDrive --partition $PartitionNumber --type ext4"
Write-Host ""
