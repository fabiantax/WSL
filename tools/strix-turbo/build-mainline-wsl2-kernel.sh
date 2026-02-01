#!/bin/bash
################################################################################
# Mainline WSL2 Kernel Builder with gfx1151 Support
#
# Builds a mainline Linux kernel (6.12+) with:
# - Microsoft's dxgkrnl patches for GPU passthrough
# - Full AMDGPU support for gfx1151 (RDNA 3.5)
# - Zen 5 CPU optimizations
#
# This is the ONLY way to get native gfx1151 GPU support in WSL2 before
# Microsoft updates their kernel.
#
# Usage: ./build-mainline-wsl2-kernel.sh [OPTIONS]
#
# Options:
#   -v, --version VERSION    Kernel version (default: 6.12)
#   -j, --jobs N             Parallel jobs (default: nproc)
#   -c, --clang              Use clang instead of GCC
#   -o, --output PATH        Output directory
#   -h, --help               Show this help
#
################################################################################

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Script configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/mainline-$(date +%Y%m%d-%H%M%S).log"
readonly WORK_DIR="${SCRIPT_DIR}/kernel-build"

# Kernel sources
readonly MAINLINE_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
readonly STABLE_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
readonly WSL2_KERNEL_REPO="https://github.com/microsoft/WSL2-Linux-Kernel.git"
readonly DXGKRNL_REPO="https://github.com/nicknsy/WSL2-Linux-dxgkrnl.git"

# Defaults
KERNEL_VERSION="6.12"
JOBS=$(nproc)
USE_CLANG=false
OUTPUT_DIR=""

################################################################################
# Utility Functions
################################################################################

log_info()  { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" | tee -a "${LOG_FILE}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; }

show_help() {
    head -n 25 "$0" | tail -n 18
}

check_dependencies() {
    log_info "Checking build dependencies..."

    local missing=()

    for cmd in git make gcc flex bison bc libelf-dev libssl-dev; do
        if ! command -v "$cmd" &>/dev/null && ! dpkg -l | grep -q "$cmd" 2>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        log_info "Installing dependencies..."

        sudo apt-get update
        sudo apt-get install -y \
            build-essential \
            flex \
            bison \
            libssl-dev \
            libelf-dev \
            bc \
            git \
            wget \
            cpio \
            pahole \
            dwarves \
            pkg-config \
            python3 \
            zstd

        if [[ "$USE_CLANG" == "true" ]]; then
            sudo apt-get install -y clang llvm lld
        fi
    fi

    log_ok "Dependencies satisfied"
}

################################################################################
# Kernel Source Management
################################################################################

setup_mainline_kernel() {
    log_info "Setting up mainline Linux kernel ${KERNEL_VERSION}..."

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Clone or update mainline kernel
    if [[ -d "linux-mainline/.git" ]]; then
        log_info "Updating existing mainline kernel..."
        cd linux-mainline
        git fetch origin
        git checkout "v${KERNEL_VERSION}" 2>/dev/null || git checkout "origin/master"
    else
        log_info "Cloning mainline kernel (this may take a while)..."
        git clone --depth 1 --branch "v${KERNEL_VERSION}" "$STABLE_REPO" linux-mainline 2>/dev/null || \
            git clone --depth 1 "$MAINLINE_REPO" linux-mainline
        cd linux-mainline
    fi

    log_ok "Mainline kernel ready"
}

fetch_dxgkrnl_patches() {
    log_info "Fetching Microsoft dxgkrnl patches..."

    cd "$WORK_DIR"

    # Clone WSL2 kernel for dxgkrnl source
    if [[ ! -d "WSL2-Linux-Kernel" ]]; then
        git clone --depth 1 "$WSL2_KERNEL_REPO" WSL2-Linux-Kernel
    fi

    # Clone community dxgkrnl patches (maintained for mainline)
    if [[ ! -d "WSL2-Linux-dxgkrnl" ]]; then
        git clone --depth 1 "$DXGKRNL_REPO" WSL2-Linux-dxgkrnl 2>/dev/null || true
    fi

    log_ok "dxgkrnl sources fetched"
}

apply_dxgkrnl_patches() {
    log_info "Applying dxgkrnl patches to mainline kernel..."

    cd "$WORK_DIR/linux-mainline"

    # Method 1: Try community-maintained patches first
    if [[ -d "$WORK_DIR/WSL2-Linux-dxgkrnl/patches" ]]; then
        log_info "Applying community dxgkrnl patches..."
        for patch in "$WORK_DIR/WSL2-Linux-dxgkrnl/patches"/*.patch; do
            if [[ -f "$patch" ]]; then
                git apply "$patch" 2>/dev/null || \
                    patch -p1 < "$patch" 2>/dev/null || \
                    log_warn "Patch may have conflicts: $(basename "$patch")"
            fi
        done
    fi

    # Method 2: Copy dxgkrnl driver from WSL2 kernel
    if [[ -d "$WORK_DIR/WSL2-Linux-Kernel/drivers/hv/dxgkrnl" ]]; then
        log_info "Copying dxgkrnl driver from WSL2 kernel..."

        # Create directory structure
        mkdir -p drivers/hv/dxgkrnl

        # Copy dxgkrnl source files
        cp -r "$WORK_DIR/WSL2-Linux-Kernel/drivers/hv/dxgkrnl"/* drivers/hv/dxgkrnl/

        # Add dxgkrnl to Kconfig if not present
        if ! grep -q "dxgkrnl" drivers/hv/Kconfig 2>/dev/null; then
            cat >> drivers/hv/Kconfig << 'EOF'

config DXGKRNL
    tristate "Microsoft Paravirtualized GPU support"
    depends on HYPERV
    help
      This driver provides GPU acceleration for Windows Subsystem for Linux.
      Select this option if you are running Linux under Windows with WSL2.
EOF
        fi

        # Add dxgkrnl to Makefile if not present
        if ! grep -q "dxgkrnl" drivers/hv/Makefile 2>/dev/null; then
            echo 'obj-$(CONFIG_DXGKRNL)   += dxgkrnl/' >> drivers/hv/Makefile
        fi
    fi

    log_ok "dxgkrnl patches applied"
}

################################################################################
# Kernel Configuration
################################################################################

create_wsl2_config() {
    log_info "Creating WSL2 kernel config with gfx1151 support..."

    cd "$WORK_DIR/linux-mainline"

    # Start with WSL2 config as base
    if [[ -f "$WORK_DIR/WSL2-Linux-Kernel/arch/x86/configs/config-wsl" ]]; then
        cp "$WORK_DIR/WSL2-Linux-Kernel/arch/x86/configs/config-wsl" .config
    else
        # Create minimal WSL2-compatible config
        make defconfig
    fi

    # Apply gfx1151 and RDNA 3.5 specific options
    cat >> .config << 'EOF'

#
# AMD GPU / RDNA 3.5 / gfx1151 Support
#
CONFIG_DRM=y
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMDGPU_USERPTR=y
CONFIG_DRM_AMD_DC=y
CONFIG_DRM_AMD_DC_FP=y
CONFIG_DRM_AMD_DC_SI=y

# HSA / ROCm Support
CONFIG_HSA_AMD=y
CONFIG_HSA_AMD_SVM=y

# Required for RDNA 3.5
CONFIG_DRM_AMD_ACP=y
CONFIG_DRM_AMD_ISP=y
CONFIG_X86_AMD_PSTATE=y
CONFIG_X86_AMD_PSTATE_UT=m

# Memory management for large unified memory (128GB)
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_KSM=y
CONFIG_MEMORY_FAILURE=y
CONFIG_ARCH_SUPPORTS_MEMORY_FAILURE=y

# Hyper-V for WSL2
CONFIG_HYPERV=y
CONFIG_HYPERV_TIMER=y
CONFIG_HYPERV_UTILS=y
CONFIG_HYPERV_BALLOON=y
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_PARAVIRT_XXL=y
CONFIG_X86_HV_CALLBACK_VECTOR=y

# dxgkrnl (GPU passthrough)
CONFIG_DXGKRNL=m

# Zen 5 Optimizations
CONFIG_MZEN5=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_SCHED_MC=y
CONFIG_SCHED_SMT=y

# io_uring for performance
CONFIG_IO_URING=y

# Networking for WSL2
CONFIG_VSOCKETS=y
CONFIG_VSOCKETS_DIAG=y
CONFIG_HYPERV_VSOCKETS=y
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
CONFIG_9P_FS=y
CONFIG_9P_FS_POSIX_ACL=y

# Plan 9 filesystem (for /mnt/c)
CONFIG_NETWORK_FILESYSTEMS=y

# Disable unnecessary for WSL2
# CONFIG_SOUND is not set
# CONFIG_USB_SUPPORT is not set
# CONFIG_WIRELESS is not set
# CONFIG_WLAN is not set
EOF

    # Update config to resolve dependencies
    make olddefconfig

    log_ok "Kernel config created with gfx1151 support"
}

################################################################################
# Build
################################################################################

build_kernel() {
    log_info "Building mainline kernel (this will take 20-60 minutes)..."

    cd "$WORK_DIR/linux-mainline"

    # Clean any previous build
    make clean 2>/dev/null || true

    # Set compiler
    local make_opts="-j${JOBS}"
    if [[ "$USE_CLANG" == "true" ]]; then
        make_opts+=" CC=clang LLVM=1"
        log_info "Using Clang/LLVM toolchain"
    fi

    # Build
    local start_time
    start_time=$(date +%s)

    make $make_opts bzImage modules

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_ok "Kernel built in $((duration / 60)) minutes $((duration % 60)) seconds"
}

install_kernel() {
    log_info "Installing kernel..."

    cd "$WORK_DIR/linux-mainline"

    # Determine output location
    local output="${OUTPUT_DIR:-$HOME/WSL2-Kernels}"
    mkdir -p "$output"

    # Get kernel version
    local version
    version=$(make kernelrelease)

    # Copy kernel image
    cp arch/x86/boot/bzImage "$output/bzImage-mainline-gfx1151-${version}"

    # Create latest symlink
    ln -sf "bzImage-mainline-gfx1151-${version}" "$output/bzImage-mainline-latest"

    # Create Windows path for .wslconfig
    local windows_path
    if [[ "$output" == /mnt/c/* ]]; then
        windows_path=$(echo "$output" | sed 's|/mnt/c|C:|; s|/|\\|g')
    else
        # Copy to Windows user directory
        local win_user_dir="/mnt/c/Users/$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')"
        mkdir -p "$win_user_dir/WSL2-Kernels"
        cp "$output/bzImage-mainline-gfx1151-${version}" "$win_user_dir/WSL2-Kernels/"
        cp "$output/bzImage-mainline-latest" "$win_user_dir/WSL2-Kernels/" 2>/dev/null || true
        windows_path="C:\\Users\\$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')\\WSL2-Kernels"
    fi

    log_ok "Kernel installed to: $output"

    # Print installation instructions
    cat << EOF

${GREEN}============================================================${NC}
${GREEN}Mainline WSL2 Kernel with gfx1151 Support Built!${NC}
${GREEN}============================================================${NC}

${BLUE}Kernel:${NC} $output/bzImage-mainline-gfx1151-${version}
${BLUE}Version:${NC} ${version}

${YELLOW}Installation Steps:${NC}

1. Edit/create ${GREEN}%USERPROFILE%\\.wslconfig${NC}:

   [wsl2]
   kernel=${windows_path}\\bzImage-mainline-gfx1151-${version}

2. Restart WSL2:
   ${GREEN}wsl --shutdown${NC}
   ${GREEN}wsl${NC}

3. Verify kernel:
   ${GREEN}uname -r${NC}
   Should show: ${version}

4. Verify AMD GPU:
   ${GREEN}ls -la /dev/dri/${NC}
   ${GREEN}rocminfo${NC}

${YELLOW}Important Notes:${NC}

- This kernel includes dxgkrnl for GPU passthrough
- gfx1151 (RDNA 3.5) support is enabled in AMDGPU driver
- You still need Windows Adrenalin driver with WSL2 support
- ROCm 7.2 should work after driver support lands

${RED}If GPU still not detected:${NC}
The Windows Adrenalin driver may not yet support WSL2 passthrough
for gfx1151. Check AMD driver release notes for updates.

EOF
}

################################################################################
# Build AMDGPU firmware (optional)
################################################################################

fetch_amdgpu_firmware() {
    log_info "Fetching latest AMDGPU firmware..."

    cd "$WORK_DIR"

    # Clone linux-firmware for latest AMDGPU firmware
    if [[ ! -d "linux-firmware" ]]; then
        git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
    else
        cd linux-firmware
        git pull
        cd ..
    fi

    # Copy AMDGPU firmware
    sudo mkdir -p /lib/firmware/amdgpu
    sudo cp -r linux-firmware/amdgpu/* /lib/firmware/amdgpu/

    log_ok "AMDGPU firmware updated"
}

################################################################################
# Alternative: Use cookbook-kernel-wsl (pre-built mainline + dxgkrnl)
################################################################################

use_prebuilt_kernel() {
    log_info "Downloading pre-built mainline kernel with dxgkrnl..."

    local output="${OUTPUT_DIR:-$HOME/WSL2-Kernels}"
    mkdir -p "$output"

    # cookbook-kernel-wsl provides pre-built kernels
    local cookbook_url="https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases/latest/download/bzImage"

    if curl -fsSL -o "$output/bzImage-prebuilt-mainline" "$cookbook_url"; then
        log_ok "Pre-built kernel downloaded to: $output/bzImage-prebuilt-mainline"
        echo ""
        echo "Note: Pre-built kernel may not have all gfx1151 options enabled."
        echo "For full gfx1151 support, use the source build method."
    else
        log_error "Failed to download pre-built kernel"
        log_info "Falling back to source build..."
        return 1
    fi
}

################################################################################
# Main
################################################################################

main() {
    mkdir -p "$LOG_DIR"

    echo ""
    log_info "Mainline WSL2 Kernel Builder with gfx1151 Support"
    log_info "Target: AMD Strix Halo (Radeon 8060S, RDNA 3.5)"
    echo ""

    check_dependencies
    setup_mainline_kernel
    fetch_dxgkrnl_patches
    apply_dxgkrnl_patches
    create_wsl2_config
    build_kernel
    fetch_amdgpu_firmware
    install_kernel

    log_ok "Build complete!"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            KERNEL_VERSION="$2"
            shift 2
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        -c|--clang)
            USE_CLANG=true
            shift
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --prebuilt)
            use_prebuilt_kernel
            exit $?
            ;;
        --firmware-only)
            fetch_amdgpu_firmware
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

main
