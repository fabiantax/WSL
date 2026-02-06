#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up NVMe passthrough to WSL2, bypassing the VHDX virtualization layer.

.DESCRIPTION
    This script automates the process of passing through an NVMe drive to WSL2.
    It includes safety checks, user confirmation, and persistence setup.

.PARAMETER DiskNumber
    Optional disk number to mount directly (useful for automation)

.PARAMETER BareMode
    Use --bare mode for raw disk access (filesystem handling in WSL)

.PARAMETER Persistent
    Add the mount command to WSL startup script for persistence

.PARAMETER SkipAdmin
    Skip admin privilege check (not recommended for safety)

.EXAMPLE
    .\setup-nvme-passthrough.ps1
    # Interactive mode - detect drives and prompt user selection

.EXAMPLE
    .\setup-nvme-passthrough.ps1 -DiskNumber 1 -BareMode -Persistent
    # Mount disk 1 in bare mode with persistence

.NOTES
    Author: WSL Optimization Team
    Created: 2025-01-31
    Version: 1.0

    Requirements:
    - Windows 10 Build 19041 or later (WSL2)
    - Administrator privileges
    - WSL2 must be installed and running
#>

param(
    [int]$DiskNumber = -1,
    [switch]$BareMode,
    [switch]$Persistent,
    [switch]$SkipAdmin
)

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================

$script:ErrorActionPreference = "Stop"
$script:WarningPreference = "Continue"

# Color definitions
$colors = @{
    Success = [ConsoleColor]::Green
    Warning = [ConsoleColor]::Yellow
    Error   = [ConsoleColor]::Red
    Info    = [ConsoleColor]::Cyan
    Prompt  = [ConsoleColor]::Magenta
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-ColorOutput {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    Write-Host $Message -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput "[✓] $Message" -Color $colors.Success
}

function Write-Error_ {
    param([string]$Message)
    Write-ColorOutput "[✗] ERROR: $Message" -Color $colors.Error
}

function Write-Warning_ {
    param([string]$Message)
    Write-ColorOutput "[!] WARNING: $Message" -Color $colors.Warning
}

function Write-Info {
    param([string]$Message)
    Write-ColorOutput "[i] $Message" -Color $colors.Info
}

function Write-Prompt {
    param([string]$Message)
    Write-ColorOutput $Message -Color $colors.Prompt
}

# ============================================================================
# SAFETY CHECK FUNCTIONS
# ============================================================================

function Check-AdminPrivileges {
    <#
    .SYNOPSIS
        Verifies that the script is running with administrator privileges.
    #>
    if ($SkipAdmin) {
        Write-Warning_ "Admin privilege check skipped (not recommended)"
        return $true
    }

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($adminRole)) {
        Write-Error_ "This script requires administrator privileges."
        Write-Info "Please run PowerShell as Administrator and try again."
        exit 1
    }

    Write-Success "Running with administrator privileges"
    return $true
}

function Check-WSL2Installation {
    <#
    .SYNOPSIS
        Verifies that WSL2 is installed and running.
    #>
    Write-Info "Checking WSL2 installation..."

    try {
        $wslVersion = wsl --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "WSL command failed"
        }

        Write-Success "WSL2 is installed"
        Write-Info "WSL Version: $($wslVersion -join ' | ')"

        # Check if WSL is running
        $wslListOutput = wsl -l -v 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "WSL2 is running and accessible"
            return $true
        } else {
            throw "Cannot access WSL distributions"
        }
    } catch {
        Write-Error_ "WSL2 verification failed: $_"
        Write-Info "Please ensure WSL2 is installed. Install with: wsl --install"
        exit 1
    }
}

function Check-WindowsSystemDrive {
    <#
    .SYNOPSIS
        Identifies the Windows system drive to prevent accidental mounting.
    #>
    try {
        # Get the drive where Windows is installed
        $systemDrive = $env:SystemDrive
        $systemVolume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$systemDrive'" -ErrorAction SilentlyContinue

        if ($systemVolume) {
            Write-Info "Windows system drive detected: $systemDrive"
            return $systemVolume
        }
    } catch {
        Write-Warning_ "Could not determine system drive: $_"
    }
    return $null
}

# ============================================================================
# NVMe DETECTION FUNCTIONS
# ============================================================================

function Get-NVMeDrives {
    <#
    .SYNOPSIS
        Detects all available NVMe drives using WMI.
    #>
    Write-Info "Scanning for NVMe drives..."

    try {
        $drives = Get-CimInstance -ClassName Win32_DiskDrive -Filter "MediaType = 'Fixed hard disk media'" |
            Where-Object { $_.Model -like "*NVMe*" -or $_.InterfaceType -like "*NVMe*" }

        if ($drives.Count -eq 0) {
            Write-Warning_ "No NVMe drives detected. Attempting to detect all disk drives..."
            # Fallback to all drives if no NVMe specifically found
            $drives = Get-CimInstance -ClassName Win32_DiskDrive -Filter "MediaType = 'Fixed hard disk media'"
        }

        if ($drives.Count -eq 0) {
            throw "No suitable disk drives found"
        }

        Write-Success "Found $($drives.Count) drive(s)"
        return @($drives)
    } catch {
        Write-Error_ "Failed to detect drives: $_"
        exit 1
    }
}

function Format-DriveSize {
    <#
    .SYNOPSIS
        Converts byte size to human-readable format.
    #>
    param([uint64]$Bytes)

    $units = @("B", "KB", "MB", "GB", "TB")
    $size = [double]$Bytes
    $unitIndex = 0

    while ($size -ge 1024 -and $unitIndex -lt $units.Length - 1) {
        $size /= 1024
        $unitIndex++
    }

    return "{0:N2} {1}" -f $size, $units[$unitIndex]
}

function Show-DriveSelection {
    <#
    .SYNOPSIS
        Displays available drives and prompts user for selection.
    #>
    param([array]$Drives)

    $systemDrive = Check-WindowsSystemDrive

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "AVAILABLE DRIVES"
    Write-Host ("=" * 80)

    $safeIndex = 0
    $driveIndex = @{}

    foreach ($drive in $Drives) {
        $displayIndex = $safeIndex + 1
        $size = Format-DriveSize $drive.Size
        $model = $drive.Model -replace '^\s+|\s+$'
        $deviceId = $drive.DeviceID -replace '\\', ''

        # Check if this is the system drive
        $isSystemDrive = $false
        if ($systemDrive -and $drive.Size -eq $systemDrive.Capacity) {
            $isSystemDrive = $true
            Write-ColorOutput "`n[$displayIndex] ⚠ SYSTEM DRIVE (CANNOT SELECT)" -Color $colors.Error
        } else {
            Write-ColorOutput "`n[$displayIndex] $model" -Color $colors.Info
        }

        Write-Host "    Size: $size"
        Write-Host "    Device ID: $deviceId"
        Write-Host "    Partitions: $(Get-Partitions $drive.DeviceID)"

        # Only add to safe index if not system drive
        if (-not $isSystemDrive) {
            $driveIndex[$displayIndex] = $safeIndex
            $safeIndex++
        }

        Write-Host ""
    }

    Write-Host ("=" * 80)

    # Handle pre-selected disk
    if ($DiskNumber -ge 0) {
        if ($DiskNumber -lt $Drives.Count) {
            if ($driveIndex.ContainsKey($DiskNumber + 1)) {
                Write-Success "Automatically selected disk $DiskNumber"
                return $DiskNumber
            } else {
                Write-Error_ "Selected disk is the Windows system drive (cannot select)"
                exit 1
            }
        } else {
            Write-Error_ "Invalid disk number: $DiskNumber"
            exit 1
        }
    }

    # Interactive selection
    Write-Prompt "Select a drive number to mount (or 0 to cancel): " -NoNewline
    $selection = Read-Host

    if ($selection -eq "0") {
        Write-Info "Operation cancelled"
        exit 0
    }

    [int]$selectedIndex = $selection
    if ($driveIndex.ContainsKey($selectedIndex)) {
        return $driveIndex[$selectedIndex]
    } else {
        Write-Error_ "Invalid selection"
        exit 1
    }
}

function Get-Partitions {
    <#
    .SYNOPSIS
        Gets partition information for a drive.
    #>
    param([string]$DeviceId)

    try {
        $diskNumber = [regex]::Match($DeviceId, '\d+').Value
        if ([string]::IsNullOrEmpty($diskNumber)) {
            return "Unknown"
        }

        $partitions = Get-CimInstance -ClassName Win32_DiskPartition -Filter "DiskIndex = $diskNumber" -ErrorAction SilentlyContinue
        return $partitions.Count
    } catch {
        return "Unknown"
    }
}

# ============================================================================
# CONFIRMATION AND SAFETY FUNCTIONS
# ============================================================================

function Show-DataLossWarning {
    <#
    .SYNOPSIS
        Displays a prominent data loss warning and requires explicit confirmation.
    #>
    param(
        [string]$DriveName,
        [uint64]$DriveSize
    )

    $formattedSize = Format-DriveSize $DriveSize
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host "`n" + ("!" * 80)
    Write-ColorOutput "DATA LOSS WARNING" -Color $colors.Error
    Write-Host ("!" * 80)
    Write-Host ""
    Write-Host "You are about to pass through the following drive to WSL2:"
    Write-ColorOutput "  Drive: $DriveName" -Color $colors.Warning
    Write-ColorOutput "  Size: $formattedSize" -Color $colors.Warning
    Write-Host ""
    Write-Host "RISKS:"
    Write-Host "  • ALL DATA ON THIS DRIVE MAY BE LOST"
    Write-Host "  • Improper configuration could corrupt your filesystem"
    Write-Host "  • WSL2 will have direct access to the raw disk"
    Write-Host "  • Backup all critical data before proceeding"
    Write-Host ""
    Write-Host ("!" * 80)

    # Triple confirmation
    Write-Prompt "I understand the risks and have backed up my data. Continue? [y/N]: " -NoNewline
    $confirm1 = Read-Host

    if ($confirm1 -ne "y" -and $confirm1 -ne "Y") {
        Write-Info "Operation cancelled"
        exit 0
    }

    Write-Prompt "Type 'CONFIRM' to proceed: " -NoNewline
    $confirm2 = Read-Host

    if ($confirm2 -ne "CONFIRM") {
        Write-Info "Operation cancelled"
        exit 0
    }

    Write-Prompt "Type the drive model name to confirm: " -NoNewline
    $confirm3 = Read-Host

    if ($confirm3 -ne $DriveName) {
        Write-Info "Confirmation mismatch - operation cancelled"
        exit 0
    }

    Write-Success "Data loss warning acknowledged at $timestamp"
    return $true
}

# ============================================================================
# MOUNT COMMAND GENERATION
# ============================================================================

function Get-DiskPhysicalPath {
    <#
    .SYNOPSIS
        Converts a disk number to its physical path for WSL mounting.
    #>
    param([int]$DiskIndex)

    # In WSL, physical drives are referenced as \\.\PhysicalDriveN
    return "\\.\PhysicalDrive$DiskIndex"
}

function Generate-MountCommand {
    <#
    .SYNOPSIS
        Generates the wsl --mount command with appropriate options.
    #>
    param(
        [int]$DiskIndex,
        [string]$DriveName,
        [switch]$UseBareMode
    )

    $physicalPath = Get-DiskPhysicalPath $DiskIndex
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Build mount command
    $mountCmd = "wsl --mount $physicalPath"

    if ($UseBareMode) {
        $mountCmd += " --bare"
        $modeDescription = "BARE MODE (raw disk access - WSL handles filesystem)"
    } else {
        $modeDescription = "MANAGED MODE (filesystem automatically mounted)"
    }

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "WSL MOUNT COMMAND"
    Write-Host ("=" * 80)
    Write-Host ""
    Write-ColorOutput "Mount Command:" -Color $colors.Info
    Write-ColorOutput "  $mountCmd" -Color $colors.Success
    Write-Host ""
    Write-ColorOutput "Mode: $modeDescription" -Color $colors.Info
    Write-Host ""
    Write-ColorOutput "Drive: $DriveName" -Color $colors.Info
    Write-ColorOutput "Physical Path: $physicalPath" -Color $colors.Info
    Write-Host ""
    Write-Host ("=" * 80)

    return @{
        Command = $mountCmd
        Path = $physicalPath
        DiskIndex = $DiskIndex
        BareMode = $UseBareMode
        DriveName = $DriveName
        Timestamp = $timestamp
    }
}

# ============================================================================
# FILESYSTEM SETUP FUNCTIONS
# ============================================================================

function Check-Filesystem {
    <#
    .SYNOPSIS
        Checks the filesystem on the target disk.
    #>
    param([int]$DiskIndex)

    Write-Info "Checking filesystem on disk $DiskIndex..."

    try {
        $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DiskIndex = $DiskIndex" -ErrorAction SilentlyContinue

        if ($null -eq $volume) {
            Write-Warning_ "No filesystem detected on disk $DiskIndex"
            return @{ HasFilesystem = $false; FileSystem = "None" }
        }

        $fsType = $volume.FileSystem
        Write-Success "Found filesystem: $fsType"

        return @{
            HasFilesystem = $true
            FileSystem = $fsType
            Label = $volume.Label
            DriveLetters = $volume.DriveLetter
        }
    } catch {
        Write-Warning_ "Could not determine filesystem: $_"
        return @{ HasFilesystem = $null; FileSystem = "Unknown" }
    }
}

function Show-FilesystemSetupGuide {
    <#
    .SYNOPSIS
        Guides user through creating ext4 filesystem in WSL.
    #>
    param(
        [string]$PhysicalPath,
        [bool]$UseBareMode
    )

    if (-not $UseBareMode) {
        Write-Info "In managed mode, filesystem setup is handled automatically."
        return
    }

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "FILESYSTEM SETUP (BARE MODE)"
    Write-Host ("=" * 80)
    Write-Host ""
    Write-Host "In bare mode, you need to initialize the ext4 filesystem in WSL."
    Write-Host ""
    Write-Host "After the mount is complete, run these commands in WSL:"
    Write-Host ""
    Write-ColorOutput "  wsl" -Color $colors.Success
    Write-ColorOutput "  # Inside WSL:" -Color $colors.Info
    Write-ColorOutput "  sudo mkfs.ext4 /dev/sdX" -Color $colors.Success
    Write-Host ""
    Write-Host "Where /dev/sdX is your mounted disk (check with 'lsblk')"
    Write-Host ""
    Write-Host ("=" * 80)
}

# ============================================================================
# PERSISTENCE FUNCTIONS
# ============================================================================

function Get-WSLLaunchDirectory {
    <#
    .SYNOPSIS
        Finds the WSL launch directory for startup scripts.
    #>
    $wslHome = wsl -e pwd 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $wslHome
    }

    # Fallback
    return "/home/$(whoami)"
}

function Create-StartupScript {
    <#
    .SYNOPSIS
        Creates a startup script in WSL to mount the drive on boot.
    #>
    param(
        [string]$MountCommand,
        [string]$DriveName
    )

    Write-Info "Creating WSL startup script for persistence..."

    # Extract the physical path from the mount command
    $physicalPath = $MountCommand -replace 'wsl --mount ', '' -replace ' --bare', ''

    # Create startup script content
    $scriptContent = @"
#!/bin/bash
# Auto-mount NVMe drive for WSL2
# Generated: $(Get-Date)

MOUNT_PATH="/mnt/nvme"
PHYSICAL_PATH="$physicalPath"

# Check if already mounted
if ! mountpoint -q `$MOUNT_PATH 2>/dev/null; then
    echo "[i] Mounting NVMe drive from $DriveName..."
    mkdir -p `$MOUNT_PATH

    # Attempt mount with wsl --mount
    if wsl --mount "$physicalPath" --bare 2>/dev/null; then
        echo "[✓] Successfully mounted NVMe drive"
    else
        echo "[!] Failed to mount - you may need to run the mount command manually"
        echo "[i] Run in PowerShell: $MountCommand"
    fi
else
    echo "[i] NVMe drive is already mounted at `$MOUNT_PATH"
fi
"@

    # Create the startup script path in WSL
    $scriptPath = ".wsl/startup-mount-nvme.sh"

    Write-ColorOutput "Startup Script Content:" -Color $colors.Info
    Write-Host ""
    Write-Host $scriptContent
    Write-Host ""
    Write-Prompt "Add this to your WSL .wslconfig or init script to auto-mount on startup? [y/N]: " -NoNewline
    $addScript = Read-Host

    if ($addScript -eq "y" -or $addScript -eq "Y") {
        Write-Success "Persistence setup guide provided (manual addition recommended)"
        return $scriptContent
    }

    return $null
}

function Show-PersistenceGuide {
    <#
    .SYNOPSIS
        Shows user how to persist the mount across WSL restarts.
    #>
    param(
        [string]$MountCommand,
        [string]$DriveName
    )

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "PERSISTENCE SETUP"
    Write-Host ("=" * 80)
    Write-Host ""
    Write-Host "To automatically mount this drive when WSL starts, you have options:"
    Write-Host ""
    Write-Host "Option 1: Add to .wslconfig (recommended for WSL2)"
    Write-Host "  Location: %UserProfile%\.wslconfig"
    Write-Host "  Note: .wslconfig doesn't natively support mount commands yet"
    Write-Host ""
    Write-Host "Option 2: Add to WSL startup script"
    Write-Host "  Create: ~/.bashrc or ~/.bash_profile"
    Write-Host "  Add:"
    Write-ColorOutput "    $MountCommand" -Color $colors.Success
    Write-Host ""
    Write-Host "Option 3: Run mount command manually when needed"
    Write-Host "  Use: $MountCommand"
    Write-Host ""
    Write-Host ("=" * 80)

    return $MountCommand
}

# ============================================================================
# VERIFICATION FUNCTIONS
# ============================================================================

function Show-VerificationGuide {
    <#
    .SYNOPSIS
        Shows how to verify the mount worked inside WSL.
    #>
    param([string]$PhysicalPath)

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "VERIFICATION INSIDE WSL"
    Write-Host ("=" * 80)
    Write-Host ""
    Write-Host "Run these commands inside WSL to verify the mount:"
    Write-Host ""
    Write-ColorOutput "  wsl" -Color $colors.Success
    Write-Host ""
    Write-Host "Then inside WSL:"
    Write-Host ""
    Write-ColorOutput "  # List all disks" -Color $colors.Info
    Write-ColorOutput "  lsblk" -Color $colors.Success
    Write-Host ""
    Write-ColorOutput "  # Check mounted filesystems" -Color $colors.Info
    Write-ColorOutput "  mount | grep -i nvme" -Color $colors.Success
    Write-Host ""
    Write-ColorOutput "  # Check disk usage" -Color $colors.Info
    Write-ColorOutput "  df -h" -Color $colors.Success
    Write-Host ""
    Write-ColorOutput "  # Get device details" -Color $colors.Info
    Write-ColorOutput "  sudo fdisk -l" -Color $colors.Success
    Write-Host ""
    Write-Host "Expected output:"
    Write-Host "  - A new device (usually /dev/sdb, /dev/sdc, etc.)"
    Write-Host "  - If using bare mode, the device may be unformatted"
    Write-Host "  - Mount point will typically be /mnt/nvme or /mnt/wsl/[disk-name]"
    Write-Host ""
    Write-Host ("=" * 80)
}

function Show-TroubleshootingGuide {
    <#
    .SYNOPSIS
        Shows common troubleshooting steps.
    #>

    Write-Host "`n" + ("=" * 80)
    Write-Prompt "TROUBLESHOOTING GUIDE"
    Write-Host ("=" * 80)
    Write-Host ""
    Write-Host "Issue: Mount command fails"
    Write-Host "  - Ensure WSL2 is running: wsl --list --verbose"
    Write-Host "  - Try running from PowerShell (admin): wsl --mount \\.\PhysicalDriveX"
    Write-Host "  - Check physical drive number is correct"
    Write-Host ""
    Write-Host "Issue: Permission denied when accessing mounted disk"
    Write-Host "  - Use sudo in WSL: sudo ls /mnt/nvme"
    Write-Host "  - Check file permissions: ls -la /mnt/nvme"
    Write-Host ""
    Write-Host "Issue: Disk not appearing in WSL"
    Write-Host "  - Verify mount in PowerShell: wsl --mount --list"
    Write-Host "  - Check device availability: Get-CimInstance Win32_DiskDrive"
    Write-Host ""
    Write-Host "Issue: Filesystem read-only"
    Write-Host "  - Remount with write permissions: mount -o remount,rw /mnt/nvme"
    Write-Host "  - Check disk health: sudo fsck.ext4 /dev/sdX"
    Write-Host ""
    Write-Host ("=" * 80)
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Main {
    Write-Host ""
    Write-Prompt "======================================================================"
    Write-Prompt "  WSL2 NVMe Passthrough Setup Script"
    Write-Prompt "======================================================================"
    Write-Host ""

    # Safety checks
    Check-AdminPrivileges | Out-Null
    Check-WSL2Installation | Out-Null

    # Detect drives
    $drives = Get-NVMeDrives

    # User selection or auto-select
    $selectedIndex = Show-DriveSelection $drives
    $selectedDrive = $drives[$selectedIndex]

    # Prepare drive information
    $driveName = $selectedDrive.Model -replace '^\s+|\s+$'
    $driveSize = $selectedDrive.Size
    $diskIndex = $selectedDrive.DeviceID -replace '\\.*\\'

    # Data loss warning
    Show-DataLossWarning -DriveName $driveName -DriveSize $driveSize

    # Check filesystem
    $fsInfo = Check-Filesystem $diskIndex

    # Generate mount command
    $mountInfo = Generate-MountCommand -DiskIndex $diskIndex -DriveName $driveName -UseBareMode:$BareMode

    # Filesystem setup guide
    Show-FilesystemSetupGuide -PhysicalPath $mountInfo.Path -UseBareMode $mountInfo.BareMode

    # Persistence setup
    if ($Persistent) {
        Show-PersistenceGuide -MountCommand $mountInfo.Command -DriveName $driveName
    }

    # Verification guide
    Show-VerificationGuide -PhysicalPath $mountInfo.Path

    # Troubleshooting guide
    Show-TroubleshootingGuide

    # Final summary
    Write-Host ""
    Write-Prompt "======================================================================"
    Write-Prompt "  NEXT STEPS"
    Write-Prompt "======================================================================"
    Write-Host ""
    Write-ColorOutput "1. Copy and run this command in PowerShell (admin):" -Color $colors.Info
    Write-ColorOutput "   $($mountInfo.Command)" -Color $colors.Success
    Write-Host ""
    Write-ColorOutput "2. Verify mount in WSL:" -Color $colors.Info
    Write-ColorOutput "   wsl && lsblk" -Color $colors.Success
    Write-Host ""
    if ($mountInfo.BareMode) {
        Write-ColorOutput "3. Create filesystem (bare mode):" -Color $colors.Info
        Write-ColorOutput "   sudo mkfs.ext4 /dev/sdX" -Color $colors.Success
        Write-Host ""
    }
    Write-ColorOutput "4. Access your drive from WSL" -Color $colors.Info
    Write-Host ""
    Write-Prompt "======================================================================"
    Write-Host ""

    Write-Success "Setup complete - copy the mount command above and run it when ready"
}

# Run main function
Main
