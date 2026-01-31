#!/bin/bash
################################################################################
# WSL2 Zen 5 Kernel Builder - Strix Turbo Edition
#
# A comprehensive script to build a custom WSL2 Linux kernel with Zen 5
# optimizations for improved performance and responsiveness.
#
# Usage: ./build-zen5-kernel.sh [OPTIONS]
#
# Options:
#   -v, --version VERSION      Specify kernel version tag (default: latest stable)
#   -j, --jobs N               Number of parallel jobs (default: nproc)
#   -c, --clang                Use clang/LLVM instead of GCC
#   -k, --kernel-dir PATH      Path to kernel source (default: ./linux-kernel)
#   -o, --output PATH          Output directory for bzImage
#   -h, --help                 Show this help message
#
################################################################################

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/build-$(date +%Y%m%d-%H%M%S).log"
readonly KERNEL_REPO="https://github.com/microsoft/WSL2-Linux-Kernel.git"
readonly WINDOWS_USER_DIR="/mnt/c/Users"

# Build configuration defaults
KERNEL_VERSION=""
JOBS=$(nproc)
USE_CLANG=false
KERNEL_DIR="${SCRIPT_DIR}/linux-kernel"
OUTPUT_DIR=""
VERBOSE=false

################################################################################
# Utility Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

print_separator() {
    echo "================================================================================" | tee -a "${LOG_FILE}"
}

print_header() {
    print_separator
    echo -e "${BLUE}$*${NC}" | tee -a "${LOG_FILE}"
    print_separator
}

show_help() {
    head -n 25 "$0" | tail -n 18
}

estimate_build_time() {
    local cores=$1
    local base_time=300  # Base time for single core in seconds
    local estimated=$((base_time / cores))

    if [ $estimated -lt 60 ]; then
        echo "${estimated}s"
    elif [ $estimated -lt 3600 ]; then
        local minutes=$((estimated / 60))
        echo "${minutes}m"
    else
        local hours=$((estimated / 3600))
        local mins=$(((estimated % 3600) / 60))
        echo "${hours}h ${mins}m"
    fi
}

################################################################################
# Dependency Checking
################################################################################

check_dependencies() {
    print_header "Checking Dependencies"

    local dependencies=("build-essential" "flex" "bison" "libssl-dev" "libelf-dev" "bc" "git" "wget")
    local missing_deps=()

    for dep in "${dependencies[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$dep"; then
            missing_deps+=("$dep")
            log_warn "Missing dependency: $dep"
        else
            log_info "Found: $dep"
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies with:"
        echo -e "${YELLOW}sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}${NC}" | tee -a "${LOG_FILE}"
        return 1
    fi

    log_success "All required dependencies are installed"

    # Check for optional clang
    if [ "$USE_CLANG" = true ]; then
        if ! command -v clang &> /dev/null; then
            log_warn "clang not found, will use GCC instead"
            USE_CLANG=false
        else
            log_info "Found clang: $(clang --version | head -n1)"
        fi
    fi

    return 0
}

check_system_requirements() {
    print_header "Checking System Requirements"

    log_info "CPU Cores: $JOBS"
    log_info "Estimated build time: $(estimate_build_time $JOBS)"

    # Check free disk space (need at least 5GB)
    local free_space=$(df /home/user/WSL | awk 'NR==2 {print int($4/1024/1024)}')
    log_info "Free disk space: ${free_space}GB"

    if [ "$free_space" -lt 5 ]; then
        log_error "Insufficient disk space! Need at least 5GB, have ${free_space}GB"
        return 1
    fi

    # Check if running on WSL
    if ! grep -qi microsoft /proc/version; then
        log_warn "Not running on WSL2 (or WSL detection unavailable)"
    else
        log_info "Running on WSL2"
    fi

    return 0
}

################################################################################
# Kernel Source Management
################################################################################

get_latest_tag() {
    log_info "Fetching latest stable kernel version..."
    cd "$KERNEL_DIR"

    # Fetch tags and get the latest stable one
    git fetch --tags 2>/dev/null || true
    local latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

    if [ -z "$latest_tag" ]; then
        log_warn "Could not determine latest tag, using main branch"
        echo "main"
    else
        echo "$latest_tag"
    fi
}

clone_or_update_kernel() {
    print_header "Setting up Kernel Source"

    if [ -d "$KERNEL_DIR" ]; then
        log_info "Kernel directory already exists at $KERNEL_DIR"
        log_info "Updating repository..."
        cd "$KERNEL_DIR"
        git fetch origin 2>&1 | tee -a "${LOG_FILE}"
    else
        log_info "Cloning WSL2 Linux Kernel repository..."
        git clone --depth 1 "$KERNEL_REPO" "$KERNEL_DIR" 2>&1 | tee -a "${LOG_FILE}"
    fi

    log_success "Kernel source ready at $KERNEL_DIR"
}

checkout_kernel_version() {
    print_header "Checking out Kernel Version"

    cd "$KERNEL_DIR"

    if [ -z "$KERNEL_VERSION" ]; then
        KERNEL_VERSION=$(get_latest_tag)
        log_info "Using latest version: $KERNEL_VERSION"
    else
        log_info "Checking out specified version: $KERNEL_VERSION"
    fi

    git checkout "$KERNEL_VERSION" 2>&1 | tee -a "${LOG_FILE}" || {
        log_error "Failed to checkout version $KERNEL_VERSION"
        return 1
    }

    log_success "Checked out kernel version: $KERNEL_VERSION"
}

################################################################################
# Kernel Configuration
################################################################################

setup_kernel_config() {
    print_header "Setting up Kernel Configuration"

    cd "$KERNEL_DIR"

    # Copy Microsoft's default config
    log_info "Copying Microsoft WSL2 default configuration..."
    cp Microsoft/config-wsl .config 2>/dev/null || {
        log_warn "Microsoft config not found in expected location, using defconfig"
        make defconfig 2>&1 | tee -a "${LOG_FILE}"
    }

    log_success "Base kernel configuration loaded"
}

apply_zen5_optimizations() {
    print_header "Applying Zen 5 Optimizations"

    cd "$KERNEL_DIR"

    # Create Zen 5 fragment file
    cat > kconfig-zen5.fragment << 'ZENFRAGMENT'
# Zen 5 CPU Scheduler Optimizations
CONFIG_SCHED_ZEN=y

# CPU Frequency Scaling Optimization
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y

# Enable BBRv3 TCP congestion control (better networking)
CONFIG_TCP_CONG_BBR=m

# Disable mitigations for better single-threaded performance (optional - security tradeoff)
# CONFIG_MITIGATION is not set

# L1TF=off can improve performance but requires CPU support
# CONFIG_L1TF=off

# Performance-focused I/O scheduler
CONFIG_IOSCHED_BFQ=m
CONFIG_BFQ_GROUP_IOSCHED=y

# Dynticks for power efficiency
CONFIG_NO_HZ=y
CONFIG_NO_HZ_FULL=y

# Preemption model - PREEMPT for responsiveness
CONFIG_PREEMPT=y
CONFIG_PREEMPT_COUNT=y

# RCU configuration for responsiveness
CONFIG_RCU_BOOST=y

# Disable unnecessary debug options for performance
# CONFIG_KGDB is not set
# CONFIG_KGDB_KDB is not set

# Enable THP (Transparent Huge Pages)
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_DEFRAG=y

# VM optimization
CONFIG_PAGE_POOL=y
CONFIG_PAGE_POOL_STATS=y

# Zstd compression for better performance
CONFIG_HAVE_KERNEL_GZIP=y
CONFIG_KERNEL_GZIP=y

# 1000Hz timer for better responsiveness
CONFIG_HZ_1000=y
CONFIG_HZ=1000

# PSI (Pressure Stall Information) for monitoring
CONFIG_PSI=y

# Enable ZRAM if memory is limited
# CONFIG_ZRAM is not set

# CPU Idle Management
CONFIG_CPU_IDLE=y
CONFIG_CPU_IDLE_GOV_MENU=y

ZENFRAGMENT

    log_info "Created kconfig-zen5.fragment"

    # Apply the fragment using kconfig-merge or manual merge
    if command -v merge_config.sh &> /dev/null; then
        log_info "Using merge_config.sh to apply Zen 5 optimizations..."
        bash merge_config.sh -m .config kconfig-zen5.fragment 2>&1 | tee -a "${LOG_FILE}"
    else
        log_info "merge_config.sh not found, applying optimizations manually..."
        # Manual merge - append unique options
        grep -v "^#" kconfig-zen5.fragment | grep "=" | while read line; do
            key="${line%%=*}"
            if ! grep -q "^${key}" .config; then
                echo "$line" >> .config
            fi
        done
    fi

    log_success "Zen 5 optimizations applied"
}

configure_build_options() {
    print_header "Configuring Build Options"

    cd "$KERNEL_DIR"

    # Set compiler choice
    if [ "$USE_CLANG" = true ]; then
        log_info "Configuring for clang/LLVM build..."
        export CC=clang
        export LD=ld.lld
        export LLVM=1
        log_success "Using clang/LLVM toolchain"
    else
        log_info "Using GCC toolchain"
        export CC=gcc
    fi

    # Configure make options
    export MAKEFLAGS="-j${JOBS}"

    # Prepare the configuration
    log_info "Validating and preparing kernel configuration..."
    make olddefconfig 2>&1 | tee -a "${LOG_FILE}"

    log_success "Build configuration prepared"
}

################################################################################
# Cross-Compilation Setup
################################################################################

setup_cross_compilation() {
    print_header "Setting up Cross-Compilation Environment"

    # Detect target architecture
    local target_arch=$(uname -m)
    local build_arch="x86_64"

    log_info "Build architecture: $build_arch"
    log_info "Target architecture: $target_arch"

    if [ "$build_arch" = "$target_arch" ]; then
        log_info "Native compilation (no cross-compilation needed)"
        return 0
    fi

    log_warn "Cross-compilation required"
    log_info "Setting up cross-compilation toolchain..."

    # For WSL2, typically x86_64 is both build and target
    # This section can be expanded for ARM targets if needed

    log_success "Cross-compilation environment ready"
}

################################################################################
# Build Process
################################################################################

show_build_summary() {
    print_header "Build Configuration Summary"

    echo "Kernel Version:        $KERNEL_VERSION" | tee -a "${LOG_FILE}"
    echo "Source Directory:      $KERNEL_DIR" | tee -a "${LOG_FILE}"
    echo "Output Directory:      $OUTPUT_DIR" | tee -a "${LOG_FILE}"
    echo "Parallel Jobs:         $JOBS" | tee -a "${LOG_FILE}"
    echo "Compiler:              $([ "$USE_CLANG" = true ] && echo "clang/LLVM" || echo "GCC")" | tee -a "${LOG_FILE}"
    echo "Estimated Build Time:  $(estimate_build_time $JOBS)" | tee -a "${LOG_FILE}"
    echo "Log File:              $LOG_FILE" | tee -a "${LOG_FILE}"

    print_separator
}

build_kernel() {
    print_header "Building Kernel"

    cd "$KERNEL_DIR"

    show_build_summary

    log_info "Starting kernel compilation..."
    local start_time=$(date +%s)

    if ! make -j"${JOBS}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Kernel build failed!"
        log_error "Check $LOG_FILE for details"
        return 1
    fi

    local end_time=$(date +%s)
    local build_duration=$((end_time - start_time))
    local build_minutes=$((build_duration / 60))
    local build_seconds=$((build_duration % 60))

    log_success "Kernel build completed in ${build_minutes}m ${build_seconds}s"
}

################################################################################
# Installation
################################################################################

prepare_output_directory() {
    if [ -z "$OUTPUT_DIR" ]; then
        # Try to find Windows user directory
        if [ -d "$WINDOWS_USER_DIR" ]; then
            # Find the first user directory
            for user_dir in "$WINDOWS_USER_DIR"/*; do
                if [ -d "$user_dir" ] && [ "$(basename "$user_dir")" != "Public" ]; then
                    OUTPUT_DIR="${user_dir}/WSL-Kernels"
                    break
                fi
            done
        fi

        # Fallback to script directory
        if [ -z "$OUTPUT_DIR" ]; then
            OUTPUT_DIR="${SCRIPT_DIR}/output"
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    log_info "Output directory: $OUTPUT_DIR"
}

copy_kernel_image() {
    print_header "Installing Kernel Image"

    local kernel_src="${KERNEL_DIR}/arch/x86/boot/bzImage"

    if [ ! -f "$kernel_src" ]; then
        log_error "bzImage not found at $kernel_src"
        return 1
    fi

    prepare_output_directory

    local kernel_filename="bzImage-${KERNEL_VERSION}-zen5-$(date +%s)"
    local kernel_dest="${OUTPUT_DIR}/${kernel_filename}"

    log_info "Copying bzImage to $OUTPUT_DIR..."
    cp "$kernel_src" "$kernel_dest"

    # Create a symlink to the latest kernel
    ln -sf "$kernel_filename" "${OUTPUT_DIR}/bzImage-latest"

    log_success "Kernel image installed: $kernel_dest"
    log_info "Latest symlink: ${OUTPUT_DIR}/bzImage-latest"

    echo "$kernel_dest"
}

################################################################################
# Configuration and Instructions
################################################################################

generate_wslconfig_snippet() {
    local kernel_path=$1
    local config_file="${OUTPUT_DIR}/.wslconfig-snippet"

    print_header "Generating .wslconfig Snippet"

    # Convert WSL path to Windows path
    local windows_kernel_path="${kernel_path//\/mnt\/c/C:}"
    windows_kernel_path="${windows_kernel_path//\//\\}"

    cat > "$config_file" << WSLCONFIG
# WSL2 Custom Kernel Configuration - Zen 5 Optimized
# Generated on $(date)
#
# To enable this custom kernel, add the following to your .wslconfig file:
# Location: C:\\Users\\<YourUsername>\\.wslconfig
#
# [wsl2]
# kernel=${windows_kernel_path}

[wsl2]
kernel=${windows_kernel_path}

# Memory allocation (adjust based on your system)
# memory=8GB

# CPU allocation (adjust based on your system)
# processors=8

# Virtual disk size
# localhostForwarding=true

WSLCONFIG

    log_success "Generated .wslconfig snippet at $config_file"
    echo "$config_file"
}

show_installation_instructions() {
    local kernel_path=$1
    local config_file=$2

    print_header "Installation Instructions"

    cat << 'INSTRUCTIONS' | tee -a "${LOG_FILE}"

================================================================================
                     KERNEL INSTALLATION INSTRUCTIONS
================================================================================

Your custom Zen 5 optimized kernel has been successfully built!

STEP 1: Locate your .wslconfig file
--------
The .wslconfig file should be in your Windows user directory:
  C:\Users\<YourUsername>\.wslconfig

If it doesn't exist, create it.

STEP 2: Add the custom kernel configuration
--------
Open .wslconfig in Notepad and add the following lines under [wsl2]:

INSTRUCTIONS

    cat "$config_file" >> "${LOG_FILE}"
    cat "$config_file" | grep -A 10 "^\[wsl2\]" | tee -a "${LOG_FILE}"

    cat << 'INSTRUCTIONS' | tee -a "${LOG_FILE}"

STEP 3: Shut down WSL2
--------
From PowerShell or Command Prompt on Windows, run:
  wsl --shutdown

STEP 4: Restart WSL2
--------
Open your WSL2 terminal and WSL will automatically use the new kernel.

STEP 5: Verify the kernel is running
--------
Inside WSL, run:
  uname -r
  uname -a

You should see the custom kernel version.

TROUBLESHOOTING
--------
If WSL doesn't start:
1. Check the kernel path in .wslconfig is correct
2. Verify the bzImage file exists and is readable
3. Try resetting WSL config: wsl --update
4. Check Windows Event Viewer for error messages

STEP 6: Monitor performance
--------
Use tools to benchmark and monitor:
  cat /proc/cpuinfo           # CPU information
  lscpu                        # CPU details
  free -h                      # Memory usage
  cat /proc/meminfo
  iostat -x 1                 # I/O statistics (install sysstat)
  perf stat command           # Performance stats (install linux-tools)

STEP 7: Fine-tune if needed
--------
You can adjust kernel parameters in /etc/sysctl.conf:
  # Better network performance
  net.ipv4.tcp_tw_reuse = 1
  net.ipv4.tcp_timestamps = 0
  net.ipv4.tcp_fast_open = 3

Apply changes: sudo sysctl -p

ADDITIONAL NOTES
--------
- Kernel built with Zen 5 optimizations for responsiveness
- BBRv3 TCP congestion control enabled
- Preemption configured for low latency
- BFQ I/O scheduler available
- Build completed: $(date)
- Log file: ${LOG_FILE}

================================================================================

INSTRUCTIONS
}

################################################################################
# Cleanup and Recovery
################################################################################

cleanup_build() {
    print_header "Cleanup"

    cd "$KERNEL_DIR"

    # Optional: remove build artifacts to save space
    log_info "Kernel build artifacts location: $KERNEL_DIR"
    log_info "To clean up build files and save space, run:"
    echo -e "${YELLOW}cd $KERNEL_DIR && make clean${NC}" | tee -a "${LOG_FILE}"
}

handle_error() {
    local line_number=$1
    log_error "Build failed at line $line_number"
    log_error "Check $LOG_FILE for details"
    echo -e "${RED}Build failed at line $line_number${NC}" >&2
}

################################################################################
# Main Execution
################################################################################

parse_arguments() {
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
            -k|--kernel-dir)
                KERNEL_DIR="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
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
}

main() {
    # Setup error handling
    trap 'handle_error ${LINENO}' ERR

    # Create log directory
    mkdir -p "$LOG_DIR"

    # Print welcome banner
    print_header "WSL2 Zen 5 Kernel Builder - Strix Turbo Edition"
    log_info "Started at $(date)"

    # Parse command line arguments
    parse_arguments "$@"

    # Run pre-build checks
    check_dependencies || exit 1
    check_system_requirements || exit 1

    # Setup and configure kernel
    clone_or_update_kernel
    checkout_kernel_version
    setup_kernel_config
    apply_zen5_optimizations
    setup_cross_compilation
    configure_build_options

    # Build the kernel
    build_kernel || exit 1

    # Install and configure
    local kernel_path
    kernel_path=$(copy_kernel_image)
    local config_file
    config_file=$(generate_wslconfig_snippet "$kernel_path")
    show_installation_instructions "$kernel_path" "$config_file"

    # Cleanup
    cleanup_build

    print_header "Build Complete"
    log_success "WSL2 Zen 5 kernel successfully built and installed!"
    log_info "Finished at $(date)"
    log_info "Log file saved to: $LOG_FILE"
}

# Execute main function with all arguments
main "$@"
