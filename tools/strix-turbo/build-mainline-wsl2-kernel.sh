#!/bin/bash
################################################################################
# Mainline WSL2 Kernel Builder with gfx1151 Support
#
# Builds a mainline Linux kernel (6.18+) with:
# - Microsoft's dxgkrnl driver with community compat patches (6.6 -> 6.18)
# - Full AMDGPU support for gfx1151 (RDNA 3.5)
# - Zen 5 CPU optimizations for Strix Halo
# - All critical WSL2 configs (VSOCK, Hyper-V, 9P, VirtIO)
#
# Uses community dxgkrnl-dkms patches from staralt/dxgkrnl-dkms which
# maintain forward-ported compat fixes for kernels 6.8 through 6.17+.
#
# Usage: ./build-mainline-wsl2-kernel.sh [OPTIONS]
#
# Options:
#   -v, --version VERSION    Kernel version tag (default: 6.18.8)
#   -j, --jobs N             Parallel jobs (default: nproc)
#   -c, --clang              Use clang instead of GCC
#   -o, --output PATH        Output directory
#   --no-dxgkrnl             Skip dxgkrnl (no GPU passthrough)
#   --no-firmware             Skip AMDGPU firmware fetch
#   --prebuilt               Download pre-built kernel instead
#   --firmware-only          Only fetch AMDGPU firmware
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
# Build on Linux filesystem (/home) for 74x faster I/O vs /mnt/c
readonly WORK_DIR="${HOME}/kernel-build-mainline"

# Kernel sources
readonly STABLE_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
readonly WSL2_KERNEL_REPO="https://github.com/microsoft/WSL2-Linux-Kernel.git"
readonly DXGKRNL_DKMS_REPO="https://github.com/staralt/dxgkrnl-dkms.git"

# Defaults
KERNEL_VERSION="6.18.8"
JOBS=$(nproc)
USE_CLANG=false
OUTPUT_DIR=""
SKIP_DXGKRNL=false
SKIP_FIRMWARE=false

################################################################################
# Utility Functions
################################################################################

log_info()  { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" | tee -a "${LOG_FILE}"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; }

show_help() {
    head -n 30 "$0" | tail -n 23
}

check_dependencies() {
    log_info "Checking build dependencies..."

    local missing=()

    for cmd in git make gcc flex bison bc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Check for libraries via dpkg
    for lib in libelf-dev libssl-dev; do
        if ! dpkg -l "$lib" &>/dev/null 2>&1; then
            missing+=("$lib")
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
    log_info "Setting up mainline Linux kernel v${KERNEL_VERSION}..."

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # Clone or update mainline kernel
    if [[ -d "linux-mainline/.git" ]]; then
        log_info "Updating existing mainline kernel source..."
        cd linux-mainline
        git fetch origin --tags
        git checkout "v${KERNEL_VERSION}" 2>/dev/null || {
            log_error "Tag v${KERNEL_VERSION} not found. Available 6.18.x tags:"
            git tag -l 'v6.18*' | tail -5
            exit 1
        }
    else
        log_info "Cloning stable kernel tree (shallow clone of v${KERNEL_VERSION})..."
        log_info "This will download ~200MB..."
        git clone --depth 1 --branch "v${KERNEL_VERSION}" "$STABLE_REPO" linux-mainline || {
            log_error "Failed to clone v${KERNEL_VERSION}. Check if this version exists."
            log_info "Browse available versions: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/refs/tags"
            exit 1
        }
        cd linux-mainline
    fi

    log_ok "Mainline kernel v${KERNEL_VERSION} ready at $WORK_DIR/linux-mainline"
}

################################################################################
# dxgkrnl - GPU Passthrough Driver
################################################################################

fetch_dxgkrnl() {
    log_info "Fetching dxgkrnl sources..."

    cd "$WORK_DIR"

    # Primary: community DKMS project with compat patches for 6.8-6.17+
    if [[ ! -d "dxgkrnl-dkms" ]]; then
        log_info "Cloning staralt/dxgkrnl-dkms (community-maintained, patches through 6.17+)..."
        git clone --depth 1 "$DXGKRNL_DKMS_REPO" dxgkrnl-dkms 2>/dev/null || {
            log_warn "Failed to clone dxgkrnl-dkms, falling back to Microsoft source"
        }
    fi

    # Fallback: Microsoft's original WSL2 kernel (6.6 base, no compat patches)
    if [[ ! -d "WSL2-Linux-Kernel" ]]; then
        log_info "Cloning Microsoft WSL2-Linux-Kernel (for base config and fallback)..."
        git clone --depth 1 --branch linux-msft-wsl-6.6.y "$WSL2_KERNEL_REPO" WSL2-Linux-Kernel 2>/dev/null || {
            log_warn "Failed to clone WSL2-Linux-Kernel, will use defconfig as base"
        }
    fi

    log_ok "dxgkrnl sources fetched"
}

apply_dxgkrnl() {
    log_info "Applying dxgkrnl driver to mainline kernel..."

    cd "$WORK_DIR/linux-mainline"

    mkdir -p drivers/hv/dxgkrnl
    mkdir -p include/uapi/misc

    local dxgkrnl_applied=false

    # Method 1 (preferred): Use staralt/dxgkrnl-dkms with compat patches
    if [[ -d "$WORK_DIR/dxgkrnl-dkms" ]]; then
        log_info "Using staralt/dxgkrnl-dkms (has compat patches for modern kernels)..."

        # Find the dxgkrnl source directory in the DKMS tree
        local dkms_src=""
        for candidate in \
            "$WORK_DIR/dxgkrnl-dkms/src" \
            "$WORK_DIR/dxgkrnl-dkms/dxgkrnl" \
            "$WORK_DIR/dxgkrnl-dkms"; do
            if [[ -f "$candidate/ioctl.c" ]]; then
                dkms_src="$candidate"
                break
            fi
        done

        if [[ -n "$dkms_src" ]]; then
            log_info "Found dxgkrnl source at: $dkms_src"
            cp -r "$dkms_src"/*.c drivers/hv/dxgkrnl/ 2>/dev/null || true
            cp -r "$dkms_src"/*.h drivers/hv/dxgkrnl/ 2>/dev/null || true

            # Copy Kconfig and Makefile if present
            cp "$dkms_src/Kconfig" drivers/hv/dxgkrnl/ 2>/dev/null || true
            cp "$dkms_src/Makefile" drivers/hv/dxgkrnl/ 2>/dev/null || true

            # Copy UAPI header
            if [[ -f "$dkms_src/d3dkmthk.h" ]]; then
                cp "$dkms_src/d3dkmthk.h" include/uapi/misc/
            elif [[ -f "$WORK_DIR/dxgkrnl-dkms/include/uapi/misc/d3dkmthk.h" ]]; then
                cp "$WORK_DIR/dxgkrnl-dkms/include/uapi/misc/d3dkmthk.h" include/uapi/misc/
            fi

            dxgkrnl_applied=true
            log_ok "dxgkrnl from staralt/dxgkrnl-dkms applied"
        else
            log_warn "Could not find dxgkrnl source files in dxgkrnl-dkms repo"
        fi
    fi

    # Method 2 (fallback): Copy from Microsoft's WSL2 kernel + apply manual compat patches
    if [[ "$dxgkrnl_applied" == "false" ]] && [[ -d "$WORK_DIR/WSL2-Linux-Kernel/drivers/hv/dxgkrnl" ]]; then
        log_info "Falling back to Microsoft WSL2-Linux-Kernel source + manual compat patches..."

        cp -r "$WORK_DIR/WSL2-Linux-Kernel/drivers/hv/dxgkrnl"/* drivers/hv/dxgkrnl/

        # Copy UAPI header
        if [[ -f "$WORK_DIR/WSL2-Linux-Kernel/include/uapi/misc/d3dkmthk.h" ]]; then
            cp "$WORK_DIR/WSL2-Linux-Kernel/include/uapi/misc/d3dkmthk.h" include/uapi/misc/
        fi

        # Apply compat patches for 6.6 -> 6.18
        apply_compat_patches

        dxgkrnl_applied=true
        log_ok "dxgkrnl from Microsoft source + compat patches applied"
    fi

    if [[ "$dxgkrnl_applied" == "false" ]]; then
        log_error "Could not apply dxgkrnl from any source!"
        log_error "GPU passthrough will not be available."
        log_info "Continuing without dxgkrnl (kernel will still work for CPU workloads)."
        return 0
    fi

    # Ensure dxgkrnl has a valid Kconfig
    if [[ ! -f "drivers/hv/dxgkrnl/Kconfig" ]]; then
        cat > drivers/hv/dxgkrnl/Kconfig << 'KCONFIG'
config DXGKRNL
    tristate "Microsoft Paravirtualized GPU support"
    depends on HYPERV
    depends on 64BIT
    select DMA_SHARED_BUFFER
    select SYNC_FILE
    help
      This driver provides GPU acceleration for Windows Subsystem for Linux
      via the dxgkrnl paravirtualized GPU interface over Hyper-V VMbus.
KCONFIG
    fi

    # Ensure dxgkrnl has a valid Makefile
    if [[ ! -f "drivers/hv/dxgkrnl/Makefile" ]]; then
        cat > drivers/hv/dxgkrnl/Makefile << 'MAKEFILE'
# SPDX-License-Identifier: GPL-2.0
obj-$(CONFIG_DXGKRNL) += dxgkrnl.o
dxgkrnl-y := dxgmodule.o hmgr.o misc.o dxgadapter.o ioctl.o dxgvmbus.o dxgprocess.o
dxgkrnl-$(CONFIG_SYNC_FILE) += dxgsyncfile.o
MAKEFILE
    fi

    # Wire dxgkrnl into the Hyper-V driver tree
    if ! grep -q "dxgkrnl" drivers/hv/Kconfig 2>/dev/null; then
        log_info "Adding dxgkrnl to drivers/hv/Kconfig..."
        echo 'source "drivers/hv/dxgkrnl/Kconfig"' >> drivers/hv/Kconfig
    fi

    if ! grep -q "dxgkrnl" drivers/hv/Makefile 2>/dev/null; then
        log_info "Adding dxgkrnl to drivers/hv/Makefile..."
        echo 'obj-$(CONFIG_DXGKRNL)   += dxgkrnl/' >> drivers/hv/Makefile
    fi

    log_ok "dxgkrnl integration complete"
}

apply_compat_patches() {
    # These are the 5 known breaking API changes from 6.6 to 6.18
    # Based on community analysis from staralt/dxgkrnl-dkms and thexperiments/dxgkrnl-dkms-git

    log_info "Applying kernel API compat patches (6.6 -> 6.18)..."

    local patch_count=0

    # Patch 1: uuid_le_cmp removed from kernel headers
    # Add compat shim to dxgkrnl.h
    if [[ -f "drivers/hv/dxgkrnl/dxgkrnl.h" ]]; then
        if ! grep -q "uuid_le_cmp" "drivers/hv/dxgkrnl/dxgkrnl.h" 2>/dev/null || \
           grep -q "uuid_le_cmp" "drivers/hv/dxgkrnl/dxgkrnl.h" 2>/dev/null; then
            # Add compat definition if the kernel doesn't provide it
            if ! grep -q "DXGKRNL_COMPAT_UUID" "drivers/hv/dxgkrnl/dxgkrnl.h"; then
                sed -i '1i\
/* Compat: uuid_le_cmp removed in 6.6+ */\
#include <linux/version.h>\
#ifndef uuid_le_cmp\
static inline int uuid_le_cmp(const guid_t u1, const guid_t u2) {\
    return memcmp(&u1, &u2, sizeof(guid_t));\
}\
#define DXGKRNL_COMPAT_UUID 1\
#endif' "drivers/hv/dxgkrnl/dxgkrnl.h"
                ((patch_count++))
                log_info "  Applied: uuid_le_cmp compat shim"
            fi
        fi
    fi

    # Patch 2: eventfd_signal() lost its second parameter in 6.8+
    if [[ -f "drivers/hv/dxgkrnl/dxgmodule.c" ]]; then
        if grep -q 'eventfd_signal(.*,.*1)' "drivers/hv/dxgkrnl/dxgmodule.c" 2>/dev/null; then
            sed -i 's/eventfd_signal(\([^,]*\),\s*1)/eventfd_signal(\1)/g' \
                "drivers/hv/dxgkrnl/dxgmodule.c"
            ((patch_count++))
            log_info "  Applied: eventfd_signal() signature fix (6.8+)"
        fi
    fi

    # Patch 3: get_task_comm() -> __get_task_comm() change in 6.13+
    for src_file in drivers/hv/dxgkrnl/*.c; do
        if [[ -f "$src_file" ]] && grep -q 'get_task_comm' "$src_file" 2>/dev/null; then
            if ! grep -q '__get_task_comm\|LINUX_VERSION_CODE.*GET_TASK' "$src_file" 2>/dev/null; then
                # The function signature changed; wrap with version check
                sed -i 's/get_task_comm(\([^,]*\),\s*current)/__get_task_comm(\1, sizeof(\1), current)/g' \
                    "$src_file" 2>/dev/null || true
                ((patch_count++))
                log_info "  Applied: get_task_comm() -> __get_task_comm() fix (6.13+)"
                break
            fi
        fi
    done

    # Patch 4: dma_fence_ops lost fence_value_str/timeline_value_str in 6.16+
    if [[ -f "drivers/hv/dxgkrnl/dxgsyncfile.c" ]]; then
        if grep -q 'fence_value_str\|timeline_value_str' "drivers/hv/dxgkrnl/dxgsyncfile.c" 2>/dev/null; then
            # Comment out the callbacks that no longer exist
            sed -i 's/^\(\s*\)\.fence_value_str/\1\/\/ .fence_value_str/' \
                "drivers/hv/dxgkrnl/dxgsyncfile.c"
            sed -i 's/^\(\s*\)\.timeline_value_str/\1\/\/ .timeline_value_str/' \
                "drivers/hv/dxgkrnl/dxgsyncfile.c"
            ((patch_count++))
            log_info "  Applied: dma_fence_ops callback removal (6.16+)"
        fi
    fi

    # Patch 5: __dma_fence_is_later() argument order changed in 6.17+
    if [[ -f "drivers/hv/dxgkrnl/dxgsyncfile.c" ]]; then
        if grep -q '__dma_fence_is_later' "drivers/hv/dxgkrnl/dxgsyncfile.c" 2>/dev/null; then
            # The new signature has fence as first arg instead of seqno
            # This needs careful handling - log for manual review
            log_info "  Note: __dma_fence_is_later() may need arg reorder for 6.17+"
            log_info "  Will be caught at compile time if needed"
        fi
    fi

    log_ok "Applied $patch_count compat patches"
}

################################################################################
# FUSE Version Compatibility Patch
#
# Microsoft's Windows-side virtiofs/FUSE server (wslservice.exe) was built
# for the stock WSL2 kernel (6.6.x) which uses FUSE protocol 7.38.
# Mainline 6.18+ uses FUSE 7.45 with struct changes that cause the INIT
# handshake to hang (server never replies).
#
# Fix: Cap FUSE_KERNEL_MINOR_VERSION at 38 so the kernel advertises
# compatibility with the host's FUSE server. All 7.39+ features (STATX,
# passthrough I/O, io-uring FUSE, ALLOW_IDMAP, REQUEST_TIMEOUT) are
# disabled at the protocol level, but the kernel code still compiles
# fine since feature negotiation is flag-based at runtime.
################################################################################

patch_fuse_version() {
    local fuse_header="$WORK_DIR/linux-mainline/include/uapi/linux/fuse.h"
    local target_minor=38

    if [[ ! -f "$fuse_header" ]]; then
        log_error "FUSE header not found at $fuse_header"
        return 1
    fi

    local current_minor
    current_minor=$(grep -oP '#define FUSE_KERNEL_MINOR_VERSION \K[0-9]+' "$fuse_header")

    if [[ "$current_minor" -gt "$target_minor" ]]; then
        log_info "Patching FUSE protocol version: 7.${current_minor} -> 7.${target_minor} (WSL2 host compat)"
        sed -i "s/^#define FUSE_KERNEL_MINOR_VERSION ${current_minor}/#define FUSE_KERNEL_MINOR_VERSION ${target_minor}/" "$fuse_header"
        log_ok "FUSE version capped at 7.${target_minor} for WSL2 virtiofs compatibility"
    else
        log_ok "FUSE version already at 7.${current_minor} (compatible with WSL2 host)"
    fi
}

################################################################################
# Kernel Configuration
################################################################################

create_wsl2_config() {
    log_info "Creating WSL2 kernel config for 6.18 with Zen 5 + gfx1151..."

    cd "$WORK_DIR/linux-mainline"

    # Start with Microsoft's WSL2 config as base (best compatibility)
    if [[ -f "$WORK_DIR/WSL2-Linux-Kernel/arch/x86/configs/config-wsl" ]]; then
        log_info "Using Microsoft's config-wsl as base configuration"
        cp "$WORK_DIR/WSL2-Linux-Kernel/arch/x86/configs/config-wsl" .config
    else
        log_info "No WSL2 base config available, using defconfig"
        make defconfig
    fi

    # Append our optimizations and required configs
    cat >> .config << 'EOF'

#
# === WSL2 Critical Communication (VSOCK - without this, WSL2 won't start) ===
#
CONFIG_VSOCKETS=y
CONFIG_VSOCKETS_DIAG=m
CONFIG_VSOCKETS_LOOPBACK=m
CONFIG_HYPERV_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=m
CONFIG_VIRTIO_VSOCKETS_COMMON=m

#
# === Hyper-V (required for WSL2 VM) ===
#
CONFIG_HYPERV=y
CONFIG_HYPERV_TIMER=y
CONFIG_HYPERV_UTILS=y
CONFIG_HYPERV_BALLOON=y
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_PARAVIRT_XXL=y
CONFIG_X86_HV_CALLBACK_VECTOR=y
CONFIG_PCI_HYPERV=y
CONFIG_PCI_HYPERV_INTERFACE=y
CONFIG_HV_BALLOON=y

#
# === VirtIO (required for WSL2 I/O) ===
#
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_FS=y
CONFIG_VIRTIO_PMEM=y
CONFIG_VIRTIO_MEM=m
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HVC_IRQ=y

#
# === 9P Filesystem (required for /mnt/c) ===
#
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
CONFIG_9P_FS=y
CONFIG_9P_FS_POSIX_ACL=y
CONFIG_9P_FSCACHE=y
CONFIG_9P_FS_SECURITY=y
CONFIG_NETWORK_FILESYSTEMS=y

#
# === AMD GPU / RDNA 3.5 / gfx1151 Support ===
#
CONFIG_DRM=y
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_AMDGPU_SI=y
CONFIG_DRM_AMDGPU_CIK=y
CONFIG_DRM_AMDGPU_USERPTR=y
CONFIG_DRM_AMD_DC=y
CONFIG_DRM_AMD_DC_FP=y
CONFIG_DRM_AMD_DC_SI=y
CONFIG_HSA_AMD=y
CONFIG_HSA_AMD_SVM=y
CONFIG_DRM_AMD_ACP=y
CONFIG_DRM_AMD_ISP=y

#
# === dxgkrnl (GPU passthrough from Windows host) ===
#
CONFIG_DXGKRNL=m
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_SYNC_FILE=y

#
# === Zen 5 CPU Optimizations (AMD Ryzen AI Max+ 395) ===
#
CONFIG_MZEN5=y
CONFIG_X86_AMD_PSTATE=y
CONFIG_X86_AMD_PSTATE_UT=m
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_SCHED_MC=y
CONFIG_SCHED_SMT=y

#
# === Memory Optimizations (96GB+ unified memory) ===
#
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_KSM=y
CONFIG_MEMORY_FAILURE=y

#
# === io_uring (performance) ===
#
CONFIG_IO_URING=y

#
# === Disable unnecessary for WSL2 (smaller/faster kernel) ===
#
# CONFIG_SOUND is not set
# CONFIG_USB_SUPPORT is not set
# CONFIG_WIRELESS is not set
# CONFIG_WLAN is not set
# CONFIG_BLUETOOTH is not set
# CONFIG_WERROR is not set
EOF

    # Resolve config dependencies
    make olddefconfig

    log_ok "Kernel config created (Zen 5 + gfx1151 + WSL2 critical configs)"
}

################################################################################
# Pre-flight Compile Checks
#
# Test-compile each critical subsystem BEFORE the full kernel build.
# Catches compat errors in seconds instead of after 20+ minutes.
################################################################################

preflight_all() {
    cd "$WORK_DIR/linux-mainline"

    log_info "============================================"
    log_info "  Pre-flight compile checks"
    log_info "============================================"

    local make_opts="-j${JOBS}"
    if [[ "$USE_CLANG" == "true" ]]; then
        make_opts+=" CC=clang LLVM=1"
    fi

    # Prepare kernel headers and build scripts first (needed for all checks)
    log_info "Preparing kernel headers and build scripts..."
    if ! make $make_opts prepare scripts 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to prepare kernel headers. Config may be invalid."
        exit 1
    fi
    log_ok "Kernel headers ready"

    local failed=()

    # Check 1: Hyper-V core (VSOCK lives here - critical for WSL2 boot)
    log_info ""
    log_info "[1/6] Hyper-V drivers (VSOCK, VMbus)..."
    if make $make_opts KBUILD_MODPOST_WARN=1 M=drivers/hv 2>"${LOG_DIR}/preflight-hyperv.log"; then
        log_ok "  Hyper-V drivers compile OK"
    else
        log_error "  Hyper-V drivers FAILED"
        grep -E "error:" "${LOG_DIR}/preflight-hyperv.log" | head -5
        failed+=("hyperv")
    fi

    # Check 2: VirtIO (filesystem, network, console)
    log_info "[2/6] VirtIO drivers (virtio-fs, balloon, net)..."
    if make $make_opts KBUILD_MODPOST_WARN=1 M=drivers/virtio 2>"${LOG_DIR}/preflight-virtio.log"; then
        log_ok "  VirtIO drivers compile OK"
    else
        log_error "  VirtIO drivers FAILED"
        grep -E "error:" "${LOG_DIR}/preflight-virtio.log" | head -5
        failed+=("virtio")
    fi

    # Check 3: 9P filesystem (required for /mnt/c)
    log_info "[3/6] 9P filesystem (Plan 9, /mnt/c)..."
    if make $make_opts KBUILD_MODPOST_WARN=1 M=net/9p 2>"${LOG_DIR}/preflight-9p-net.log" && \
       make $make_opts KBUILD_MODPOST_WARN=1 M=fs/9p 2>"${LOG_DIR}/preflight-9p-fs.log"; then
        log_ok "  9P filesystem compiles OK"
    else
        log_error "  9P filesystem FAILED"
        grep -E "error:" "${LOG_DIR}/preflight-9p-net.log" "${LOG_DIR}/preflight-9p-fs.log" 2>/dev/null | head -5
        failed+=("9p")
    fi

    # Check 4: VSOCK (critical - without this WSL2 can't talk to Windows host)
    log_info "[4/6] VSOCK (VM ↔ Host communication)..."
    if make $make_opts KBUILD_MODPOST_WARN=1 M=net/vmw_vsock 2>"${LOG_DIR}/preflight-vsock.log"; then
        log_ok "  VSOCK compiles OK"
    else
        log_error "  VSOCK FAILED"
        grep -E "error:" "${LOG_DIR}/preflight-vsock.log" | head -5
        failed+=("vsock")
    fi

    # Check 5: AMDGPU (for gfx1151 GPU support)
    log_info "[5/6] AMDGPU (gfx1151 / RDNA 3.5)..."
    if make $make_opts KBUILD_MODPOST_WARN=1 M=drivers/gpu/drm/amd/amdgpu 2>"${LOG_DIR}/preflight-amdgpu.log"; then
        log_ok "  AMDGPU compiles OK"
    else
        log_warn "  AMDGPU had errors (non-fatal, GPU may not work)"
        grep -E "error:" "${LOG_DIR}/preflight-amdgpu.log" | head -3
        # Don't add to failed - AMDGPU is optional, WSL2 works without it
    fi

    # Check 6: dxgkrnl (GPU passthrough - uses auto-fix loop)
    if [[ "$SKIP_DXGKRNL" == "false" ]] && [[ -d "drivers/hv/dxgkrnl" ]]; then
        log_info "[6/6] dxgkrnl (GPU passthrough)..."
        preflight_dxgkrnl
    else
        log_info "[6/6] dxgkrnl - skipped"
    fi

    # Report results
    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "============================================"
        log_error "  Pre-flight FAILED: ${failed[*]}"
        log_error "============================================"
        log_error ""
        log_error "These subsystems are REQUIRED for WSL2 to function."
        log_error "Check error logs in: ${LOG_DIR}/preflight-*.log"
        log_error ""
        log_error "This likely means the Microsoft WSL2 base config (6.6)"
        log_error "has incompatibilities with kernel ${KERNEL_VERSION}."
        log_error "You may need to update the base config or fix API changes."
        exit 1
    fi

    log_ok "============================================"
    log_ok "  All pre-flight checks PASSED"
    log_ok "============================================"
    echo ""
}

preflight_dxgkrnl() {
    # Test-compile ONLY the dxgkrnl module with auto-fix loop.
    # Headers already prepared by preflight_all().

    cd "$WORK_DIR/linux-mainline"

    local make_opts="-j${JOBS}"
    if [[ "$USE_CLANG" == "true" ]]; then
        make_opts+=" CC=clang LLVM=1"
    fi

    # Try compiling dxgkrnl with up to 3 auto-fix attempts
    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        log_info "dxgkrnl compile check (attempt $attempt/$max_attempts)..."

        local error_log="${LOG_DIR}/dxgkrnl-preflight-${attempt}.log"

        if make $make_opts KBUILD_MODPOST_WARN=1 M=drivers/hv/dxgkrnl 2>"$error_log"; then
            log_ok "dxgkrnl compiles successfully!"
            return 0
        fi

        log_warn "dxgkrnl compilation failed (attempt $attempt). Analyzing errors..."

        # Parse errors and attempt auto-fix
        local fixed=false

        # Pattern: implicit declaration of function 'eventfd_signal'
        # or: too many arguments to function 'eventfd_signal'
        if grep -q "eventfd_signal" "$error_log" 2>/dev/null; then
            log_info "  Auto-fix: eventfd_signal() signature change"
            for f in drivers/hv/dxgkrnl/*.c; do
                sed -i 's/eventfd_signal(\([^,]*\),\s*[0-9]*)/eventfd_signal(\1)/g' "$f" 2>/dev/null || true
            done
            fixed=true
        fi

        # Pattern: implicit declaration of function 'get_task_comm'
        if grep -q "get_task_comm" "$error_log" 2>/dev/null; then
            log_info "  Auto-fix: get_task_comm() -> __get_task_comm()"
            for f in drivers/hv/dxgkrnl/*.c; do
                sed -i 's/\bget_task_comm(\([^,]*\),\s*current)/__get_task_comm(\1, sizeof(\1), current)/g' "$f" 2>/dev/null || true
            done
            fixed=true
        fi

        # Pattern: 'struct dma_fence_ops' has no member named 'fence_value_str'
        if grep -q "fence_value_str\|timeline_value_str" "$error_log" 2>/dev/null; then
            log_info "  Auto-fix: removing fence_value_str/timeline_value_str callbacks"
            sed -i '/\.fence_value_str/d' drivers/hv/dxgkrnl/dxgsyncfile.c 2>/dev/null || true
            sed -i '/\.timeline_value_str/d' drivers/hv/dxgkrnl/dxgsyncfile.c 2>/dev/null || true
            fixed=true
        fi

        # Pattern: too many/few arguments to function '__dma_fence_is_later'
        if grep -q "__dma_fence_is_later" "$error_log" 2>/dev/null; then
            log_info "  Auto-fix: __dma_fence_is_later() argument change"
            # In 6.17+ the function takes (fence, seqno) instead of (seqno, fence)
            # Check current usage pattern and swap if needed
            if grep -q '__dma_fence_is_later.*seqno.*fence' drivers/hv/dxgkrnl/dxgsyncfile.c 2>/dev/null; then
                sed -i 's/__dma_fence_is_later(\([^,]*\),\s*\([^)]*\))/__dma_fence_is_later(\2, \1)/g' \
                    drivers/hv/dxgkrnl/dxgsyncfile.c 2>/dev/null || true
            fi
            fixed=true
        fi

        # Pattern: implicit declaration of function 'uuid_le_cmp'
        if grep -q "uuid_le_cmp" "$error_log" 2>/dev/null; then
            log_info "  Auto-fix: adding uuid_le_cmp compat shim"
            if ! grep -q "DXGKRNL_COMPAT_UUID" drivers/hv/dxgkrnl/dxgkrnl.h 2>/dev/null; then
                sed -i '1i\
/* Compat: uuid_le_cmp */\
#include <linux/version.h>\
#ifndef uuid_le_cmp\
static inline int uuid_le_cmp(const guid_t u1, const guid_t u2) {\
    return memcmp(&u1, &u2, sizeof(guid_t));\
}\
#define DXGKRNL_COMPAT_UUID 1\
#endif' drivers/hv/dxgkrnl/dxgkrnl.h
            fi
            fixed=true
        fi

        # Pattern: undeclared identifier / unknown type (generic catch)
        if grep -qE "error:.*undeclared|error:.*unknown type|error:.*incomplete type" "$error_log" 2>/dev/null; then
            log_warn "  Unknown compilation error detected. Extracting details:"
            grep -E "error:" "$error_log" | head -10 | while IFS= read -r line; do
                log_error "    $line"
            done
        fi

        # Pattern: missing #include
        if grep -q "error:.*No such file or directory" "$error_log" 2>/dev/null; then
            log_warn "  Missing header file detected:"
            grep "No such file or directory" "$error_log" | head -5 | while IFS= read -r line; do
                log_error "    $line"
            done
        fi

        if [[ "$fixed" == "false" ]]; then
            log_error "Could not auto-fix dxgkrnl compilation errors."
            log_error "Errors from $error_log:"
            echo ""
            grep -E "error:" "$error_log" | head -20
            echo ""
            log_error "=== BUILD ABORTED ==="
            log_error "Fix the errors above in drivers/hv/dxgkrnl/ and re-run."
            log_error "Hint: compare with https://github.com/staralt/dxgkrnl-dkms"
            exit 1
        fi

        # Clean dxgkrnl objects for retry
        make KBUILD_MODPOST_WARN=1 M=drivers/hv/dxgkrnl clean 2>/dev/null || true
        ((attempt++))
    done

    log_error "dxgkrnl failed to compile after $max_attempts auto-fix attempts."
    log_error "Manual intervention required. See error logs in: ${LOG_DIR}/"
    exit 1
}

################################################################################
# Build
################################################################################

build_kernel() {
    log_info "Building mainline kernel v${KERNEL_VERSION}..."
    log_info "Using ${JOBS} parallel jobs on $(nproc) available cores"

    cd "$WORK_DIR/linux-mainline"

    # Set compiler
    local make_opts="-j${JOBS}"
    if [[ "$USE_CLANG" == "true" ]]; then
        make_opts+=" CC=clang LLVM=1"
        log_info "Using Clang/LLVM toolchain"
    fi

    local start_time
    start_time=$(date +%s)

    # Build bzImage
    log_info "Building bzImage..."
    if ! make $make_opts bzImage 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "bzImage build failed! Check ${LOG_FILE} for details."
        exit 1
    fi

    # Build all modules (dxgkrnl already verified by preflight)
    log_info "Building modules..."
    if ! make $make_opts modules 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Module build failed! Check ${LOG_FILE} for details."
        exit 1
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_ok "Build completed in $((duration / 60))m $((duration % 60))s"
}

install_kernel() {
    log_info "Installing kernel..."

    cd "$WORK_DIR/linux-mainline"

    # Get kernel version string
    local version
    version=$(make kernelrelease 2>/dev/null || echo "${KERNEL_VERSION}-custom")

    # Determine output location
    local output="${OUTPUT_DIR:-$HOME/WSL2-Kernels}"
    mkdir -p "$output"

    local bzimage="bzImage-${version}-zen5-wsl2"

    # Copy kernel image
    cp arch/x86/boot/bzImage "$output/${bzimage}"

    # Also copy to Windows user directory for .wslconfig
    local win_user="fabia"
    local win_kernel_dir="/mnt/c/Users/${win_user}"

    if [[ -d "$win_kernel_dir" ]]; then
        cp arch/x86/boot/bzImage "$win_kernel_dir/${bzimage}"
        log_ok "Kernel copied to C:\\Users\\${win_user}\\${bzimage}"
    fi

    log_ok "Kernel installed to: $output/${bzimage}"

    # Print installation instructions
    cat << EOF

${GREEN}================================================================${NC}
${GREEN}  WSL2 Kernel v${version} Built Successfully!${NC}
${GREEN}================================================================${NC}

${BLUE}Kernel image:${NC} $output/${bzimage}
${BLUE}Version:${NC}      ${version}
${BLUE}Features:${NC}     Zen 5, VSOCK, Hyper-V, 9P, VirtIO-FS, io_uring
${BLUE}FUSE:${NC}         7.38 (patched for WSL2 host compatibility)
${BLUE}GPU:${NC}          dxgkrnl (if module build succeeded)

${YELLOW}To install, update C:\\Users\\${win_user}\\.wslconfig:${NC}

  [wsl2]
  kernel=C:\\\\Users\\\\${win_user}\\\\${bzimage}

${YELLOW}Then restart WSL2:${NC}
  wsl --shutdown
  wsl

${YELLOW}Verify:${NC}
  uname -r
  # Expected: ${version}

EOF
}

################################################################################
# AMDGPU Firmware
################################################################################

fetch_amdgpu_firmware() {
    log_info "Fetching latest AMDGPU firmware..."

    cd "$WORK_DIR"

    if [[ ! -d "linux-firmware" ]]; then
        git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git
    else
        cd linux-firmware && git pull && cd ..
    fi

    sudo mkdir -p /lib/firmware/amdgpu
    sudo cp -r linux-firmware/amdgpu/* /lib/firmware/amdgpu/

    log_ok "AMDGPU firmware updated"
}

################################################################################
# Pre-built kernel alternative
################################################################################

use_prebuilt_kernel() {
    log_info "Downloading pre-built mainline kernel..."

    local output="${OUTPUT_DIR:-$HOME/WSL2-Kernels}"
    mkdir -p "$output"

    local url="https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases/latest/download/bzImage"

    if curl -fsSL -o "$output/bzImage-prebuilt-mainline" "$url"; then
        log_ok "Pre-built kernel downloaded to: $output/bzImage-prebuilt-mainline"
        echo ""
        echo "Note: Pre-built kernel may not have Zen 5 or gfx1151 options."
        echo "For full optimization, use the source build method."
    else
        log_error "Failed to download pre-built kernel"
        return 1
    fi
}

################################################################################
# Main
################################################################################

main() {
    mkdir -p "$LOG_DIR"

    echo ""
    log_info "============================================"
    log_info "  Mainline WSL2 Kernel Builder v2"
    log_info "  Target: Linux v${KERNEL_VERSION}"
    log_info "  CPU:    AMD Zen 5 (Strix Halo)"
    log_info "  GPU:    gfx1151 (RDNA 3.5) via dxgkrnl"
    log_info "  Jobs:   ${JOBS}"
    log_info "============================================"
    echo ""

    check_dependencies
    setup_mainline_kernel

    if [[ "$SKIP_DXGKRNL" == "false" ]]; then
        fetch_dxgkrnl
        apply_dxgkrnl
    else
        log_info "Skipping dxgkrnl (--no-dxgkrnl flag set)"
    fi

    create_wsl2_config
    patch_fuse_version
    preflight_all
    build_kernel

    if [[ "$SKIP_FIRMWARE" == "false" ]]; then
        fetch_amdgpu_firmware
    fi

    install_kernel

    log_ok "Build complete! See instructions above."
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
        --no-dxgkrnl)
            SKIP_DXGKRNL=true
            shift
            ;;
        --no-firmware)
            SKIP_FIRMWARE=true
            shift
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
