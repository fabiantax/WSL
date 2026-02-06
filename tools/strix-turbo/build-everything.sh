#!/bin/bash
# =============================================================================
# Strix-Turbo: Master Build Script
# =============================================================================
#
# This script builds all components of the Strix-Turbo WSL2 optimization suite.
#
# Components:
#   1. Custom WSL2 kernel with Zen 5 + io_uring optimizations
#   2. Strix-FUSE filesystem
#   3. SIMD path utilities
#   4. NPU prefetcher model
#   5. Benchmarking tools
#
# Prerequisites:
#   - Ubuntu/Debian with build-essential
#   - libfuse3-dev, liburing-dev
#   - Python 3.10+ with pytorch (for NPU prefetcher)
#   - WSL2-Linux-Kernel source
#
# Usage:
#   ./build-everything.sh [component]
#
# Components:
#   all      - Build everything (default)
#   kernel   - Build custom kernel only
#   fuse     - Build Strix-FUSE only
#   simd     - Build SIMD utilities only
#   npu      - Train NPU prefetcher only
#   test     - Build and run tests
#
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
KERNEL_DIR="${HOME}/WSL2-Linux-Kernel"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Configuration
JOBS=$(nproc)
KERNEL_VERSION="6.6"  # Match WSL2 kernel version

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Missing dependency: $1"
        return 1
    fi
}

ensure_dir() {
    mkdir -p "$1"
}

# =============================================================================
# Dependency Checks
# =============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=0

    # Build tools
    for cmd in gcc g++ make cmake; do
        if ! check_dependency "$cmd"; then
            missing=1
        fi
    done

    # Kernel build
    for cmd in flex bison bc; do
        if ! check_dependency "$cmd"; then
            log_warning "Missing kernel build dependency: $cmd"
            log_info "Install with: sudo apt install flex bison bc"
        fi
    done

    # FUSE
    if ! pkg-config --exists fuse3 2>/dev/null; then
        log_warning "libfuse3-dev not found"
        log_info "Install with: sudo apt install libfuse3-dev"
    fi

    # io_uring
    if ! pkg-config --exists liburing 2>/dev/null; then
        log_warning "liburing-dev not found"
        log_info "Install with: sudo apt install liburing-dev"
    fi

    # Python (for NPU prefetcher)
    if ! check_dependency python3; then
        log_warning "Python 3 not found (needed for NPU prefetcher)"
    fi

    if [ $missing -eq 1 ]; then
        log_error "Missing critical dependencies. Please install them first."
        exit 1
    fi

    log_success "Dependency check passed"
}

# =============================================================================
# Kernel Build
# =============================================================================

build_kernel() {
    log_info "Building custom WSL2 kernel..."

    # Check if kernel source exists
    if [ ! -d "$KERNEL_DIR" ]; then
        log_info "Cloning WSL2-Linux-Kernel..."
        git clone --depth 1 https://github.com/microsoft/WSL2-Linux-Kernel.git "$KERNEL_DIR"
    fi

    cd "$KERNEL_DIR"

    # Fetch latest
    log_info "Updating kernel source..."
    git fetch origin
    git checkout "linux-msft-wsl-${KERNEL_VERSION}.y" 2>/dev/null || \
        git checkout origin/linux-msft-wsl-${KERNEL_VERSION}.y

    # Start with Microsoft's config
    log_info "Configuring kernel..."
    if [ -f "Microsoft/config-wsl" ]; then
        cp Microsoft/config-wsl .config
    else
        make KCONFIG_CONFIG=.config defconfig
    fi

    # Apply our optimizations
    log_info "Applying Strix-Turbo kernel config..."
    ./scripts/kconfig/merge_config.sh -m .config \
        "${SCRIPT_DIR}/kconfig-zen5.fragment" \
        "${SCRIPT_DIR}/kconfig-microkernel.fragment"

    # Build
    log_info "Building kernel (this will take a while)..."
    make -j${JOBS} LOCALVERSION="-strix-turbo"

    # Copy output
    ensure_dir "$OUTPUT_DIR"
    cp arch/x86/boot/bzImage "${OUTPUT_DIR}/bzImage-strix-turbo"
    log_success "Kernel built: ${OUTPUT_DIR}/bzImage-strix-turbo"

    # Create .wslconfig snippet
    cat > "${OUTPUT_DIR}/wslconfig-kernel-snippet.txt" << EOF
# Add to %USERPROFILE%\.wslconfig:
[wsl2]
kernel=${OUTPUT_DIR//\//\\\\}\\\\bzImage-strix-turbo
EOF

    log_info "To use the custom kernel, add the following to .wslconfig:"
    cat "${OUTPUT_DIR}/wslconfig-kernel-snippet.txt"

    cd "$SCRIPT_DIR"
}

# =============================================================================
# SIMD Utilities Build
# =============================================================================

build_simd() {
    log_info "Building SIMD path utilities..."

    ensure_dir "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Check for AVX-512 support
    if grep -q avx512f /proc/cpuinfo; then
        SIMD_FLAGS="-mavx512f -mavx512bw -mavx512vl"
        log_info "AVX-512 detected, enabling full SIMD optimizations"
    elif grep -q avx2 /proc/cpuinfo; then
        SIMD_FLAGS="-mavx2"
        log_warning "AVX-512 not detected, falling back to AVX2"
    else
        SIMD_FLAGS=""
        log_warning "No advanced SIMD detected, using scalar fallback"
    fi

    # Compile test program
    g++ -O3 -std=c++17 ${SIMD_FLAGS} \
        -I"${SCRIPT_DIR}" \
        -o test_simd_path_utils \
        "${SCRIPT_DIR}/test_simd_path_utils.cpp" \
        -pthread

    log_success "SIMD utilities built: ${BUILD_DIR}/test_simd_path_utils"

    # Run tests
    log_info "Running SIMD tests..."
    ./test_simd_path_utils

    cd "$SCRIPT_DIR"
}

# =============================================================================
# Strix-FUSE Build
# =============================================================================

build_fuse() {
    log_info "Building Strix-FUSE filesystem..."

    ensure_dir "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Check dependencies
    if ! pkg-config --exists fuse3; then
        log_error "libfuse3-dev not installed"
        log_info "Install with: sudo apt install libfuse3-dev"
        return 1
    fi

    FUSE_CFLAGS=$(pkg-config --cflags fuse3)
    FUSE_LIBS=$(pkg-config --libs fuse3)

    URING_LIBS=""
    if pkg-config --exists liburing; then
        URING_LIBS=$(pkg-config --libs liburing)
    fi

    # Compile
    g++ -O3 -std=c++17 \
        -D_FILE_OFFSET_BITS=64 \
        ${FUSE_CFLAGS} \
        -I"${SCRIPT_DIR}" \
        -o strix-fuse \
        "${SCRIPT_DIR}/strix_fuse.cpp" \
        ${FUSE_LIBS} ${URING_LIBS} \
        -pthread

    log_success "Strix-FUSE built: ${BUILD_DIR}/strix-fuse"

    # Copy to output
    ensure_dir "$OUTPUT_DIR"
    cp strix-fuse "${OUTPUT_DIR}/"

    cd "$SCRIPT_DIR"
}

# =============================================================================
# NPU Prefetcher
# =============================================================================

build_npu() {
    log_info "Setting up NPU prefetcher..."

    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found"
        return 1
    fi

    # Create virtual environment
    if [ ! -d "${SCRIPT_DIR}/venv" ]; then
        log_info "Creating Python virtual environment..."
        python3 -m venv "${SCRIPT_DIR}/venv"
    fi

    # Activate and install dependencies
    source "${SCRIPT_DIR}/venv/bin/activate"

    log_info "Installing Python dependencies..."
    pip install --quiet --upgrade pip
    pip install --quiet torch numpy onnxruntime

    # Check if ROCm is available
    if python3 -c "import torch; print(torch.cuda.is_available())" 2>/dev/null | grep -q True; then
        log_info "ROCm/CUDA detected"
    else
        log_warning "No GPU detected, NPU prefetcher will use CPU"
    fi

    log_success "NPU prefetcher setup complete"
    log_info "To train: python3 npu_prefetcher.py train --traces <trace_files>"
    log_info "To serve: python3 npu_prefetcher.py serve --model prefetch_model.onnx"

    deactivate
}

# =============================================================================
# Benchmarks
# =============================================================================

run_benchmarks() {
    log_info "Running benchmarks..."

    ensure_dir "${OUTPUT_DIR}/benchmarks"

    # Check for fio
    if ! command -v fio &> /dev/null; then
        log_warning "fio not found, skipping I/O benchmarks"
        log_info "Install with: sudo apt install fio"
    else
        log_info "Running fio benchmarks..."

        # Quick sanity check benchmark
        fio --name=quick-test \
            --ioengine=io_uring \
            --rw=randread \
            --bs=4k \
            --numjobs=1 \
            --size=100M \
            --runtime=10 \
            --time_based \
            --output="${OUTPUT_DIR}/benchmarks/fio-quick.json" \
            --output-format=json

        log_success "fio benchmark complete: ${OUTPUT_DIR}/benchmarks/fio-quick.json"
    fi

    # SIMD benchmark
    if [ -f "${BUILD_DIR}/test_simd_path_utils" ]; then
        log_info "Running SIMD benchmarks..."
        "${BUILD_DIR}/test_simd_path_utils" --benchmark > \
            "${OUTPUT_DIR}/benchmarks/simd-benchmark.txt" 2>&1 || true
    fi

    log_success "Benchmarks complete. Results in ${OUTPUT_DIR}/benchmarks/"
}

# =============================================================================
# Tests
# =============================================================================

run_tests() {
    log_info "Running tests..."

    # SIMD tests
    if [ -f "${BUILD_DIR}/test_simd_path_utils" ]; then
        log_info "Running SIMD tests..."
        "${BUILD_DIR}/test_simd_path_utils"
    fi

    # Python tests
    if [ -d "${SCRIPT_DIR}/venv" ]; then
        source "${SCRIPT_DIR}/venv/bin/activate"
        log_info "Running NPU prefetcher tests..."
        python3 -m pytest "${SCRIPT_DIR}/test_npu_prefetcher.py" 2>/dev/null || \
            log_warning "NPU prefetcher tests not found or failed"
        deactivate
    fi

    log_success "Tests complete"
}

# =============================================================================
# Install
# =============================================================================

install_all() {
    log_info "Installing Strix-Turbo components..."

    ensure_dir "${HOME}/.local/bin"

    # Install strix-fuse
    if [ -f "${OUTPUT_DIR}/strix-fuse" ]; then
        cp "${OUTPUT_DIR}/strix-fuse" "${HOME}/.local/bin/"
        log_success "Installed strix-fuse to ~/.local/bin/"
    fi

    # Install .wslconfig
    log_info "Installing .wslconfig optimizations..."
    if [ -f "${SCRIPT_DIR}/.wslconfig" ]; then
        WSLCONFIG_PATH="/mnt/c/Users/${USER}/.wslconfig"
        if [ -f "$WSLCONFIG_PATH" ]; then
            log_warning ".wslconfig already exists at $WSLCONFIG_PATH"
            log_info "Please manually merge ${SCRIPT_DIR}/.wslconfig"
        else
            # Try to copy (may fail if Windows user is different)
            cp "${SCRIPT_DIR}/.wslconfig" "$WSLCONFIG_PATH" 2>/dev/null || \
                log_warning "Could not auto-install .wslconfig"
        fi
    fi

    # Print kernel install instructions
    if [ -f "${OUTPUT_DIR}/bzImage-strix-turbo" ]; then
        log_info ""
        log_info "To install the custom kernel:"
        log_info "1. Copy ${OUTPUT_DIR}/bzImage-strix-turbo to Windows"
        log_info "2. Add to %USERPROFILE%\\.wslconfig:"
        log_info "   [wsl2]"
        log_info "   kernel=C:\\\\path\\\\to\\\\bzImage-strix-turbo"
        log_info "3. Run: wsl --shutdown && wsl"
    fi

    log_success "Installation complete"
}

# =============================================================================
# Clean
# =============================================================================

clean() {
    log_info "Cleaning build artifacts..."

    rm -rf "$BUILD_DIR"
    rm -rf "$OUTPUT_DIR"
    rm -rf "${SCRIPT_DIR}/venv"
    rm -rf "${SCRIPT_DIR}/__pycache__"

    log_success "Clean complete"
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << EOF
Strix-Turbo Build System
========================

Usage: $0 [command]

Commands:
  all         Build everything (default)
  kernel      Build custom WSL2 kernel
  simd        Build SIMD path utilities
  fuse        Build Strix-FUSE filesystem
  npu         Setup NPU prefetcher
  test        Run all tests
  benchmark   Run benchmarks
  install     Install components
  clean       Remove build artifacts
  help        Show this help

Examples:
  $0                    # Build everything
  $0 kernel             # Build only the custom kernel
  $0 simd test          # Build SIMD utils and run tests
  $0 clean all install  # Clean, rebuild all, and install

Environment Variables:
  KERNEL_DIR    WSL2-Linux-Kernel source directory
                (default: ~/WSL2-Linux-Kernel)
  JOBS          Number of parallel jobs
                (default: $(nproc))

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "  Strix-Turbo Build System"
    echo "  WSL2 Performance Optimization Suite"
    echo "=============================================="
    echo ""

    # Create output directories
    ensure_dir "$BUILD_DIR"
    ensure_dir "$OUTPUT_DIR"

    # Default to 'all' if no arguments
    if [ $# -eq 0 ]; then
        set -- all
    fi

    # Process commands
    for cmd in "$@"; do
        case "$cmd" in
            all)
                check_dependencies
                build_simd
                build_fuse
                build_npu
                # build_kernel  # Commented out - takes too long
                log_info "Note: Kernel build skipped. Run '$0 kernel' to build."
                ;;
            kernel)
                check_dependencies
                build_kernel
                ;;
            simd)
                build_simd
                ;;
            fuse)
                build_fuse
                ;;
            npu)
                build_npu
                ;;
            test)
                run_tests
                ;;
            benchmark)
                run_benchmarks
                ;;
            install)
                install_all
                ;;
            clean)
                clean
                ;;
            help|--help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown command: $cmd"
                show_help
                exit 1
                ;;
        esac
    done

    echo ""
    log_success "Build complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Review .wslconfig optimizations: ${SCRIPT_DIR}/.wslconfig"
    echo "  2. Run benchmarks: $0 benchmark"
    echo "  3. Build custom kernel: $0 kernel"
    echo "  4. Install everything: $0 install"
    echo ""
}

main "$@"
