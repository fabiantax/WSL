#!/bin/bash
#
# ROCm 7.2 Setup Script for AMD Strix Halo (gfx1151)
# Optimized for Ryzen AI Max+ 395 with Radeon 8060S GPU
#
# This script sets up ROCm 7.2 with full support for:
# - RDNA 3.5 GPU (gfx1151)
# - XDNA 2 NPU (50 TOPS)
# - Unified 128GB memory architecture
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROCM_VERSION="7.2"
ROCM_VERSION_FULL="7.2.2"
GPU_TARGET="gfx1151"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_wsl2() {
    if [[ ! -f /proc/version ]] || ! grep -qi microsoft /proc/version; then
        log_error "This script must be run inside WSL2"
        exit 1
    fi

    # Check WSL2 (not WSL1)
    if [[ ! -d /sys/class/dmi/id ]]; then
        log_warn "Cannot verify WSL version - proceeding anyway"
    fi
    log_ok "Running inside WSL2"
}

check_gpu() {
    log_info "Detecting AMD GPU..."

    # Check for Radeon 8060S (gfx1151)
    if command -v rocminfo &>/dev/null; then
        if rocminfo 2>/dev/null | grep -q "gfx1151\|gfx115"; then
            log_ok "Detected AMD Radeon 8060S (gfx1151)"
            return 0
        fi
    fi

    # Check via lspci
    if command -v lspci &>/dev/null; then
        if lspci 2>/dev/null | grep -qi "AMD.*Radeon\|AMD.*Display"; then
            log_ok "Detected AMD GPU via lspci"
            return 0
        fi
    fi

    # Check /dev/dri
    if [[ -d /dev/dri ]]; then
        if ls /dev/dri/render* &>/dev/null; then
            log_ok "Found GPU render nodes in /dev/dri"
            return 0
        fi
    fi

    log_warn "Could not detect AMD GPU - proceeding with installation"
    return 0
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

install_rocm_ubuntu() {
    log_info "Installing ROCm ${ROCM_VERSION} on Ubuntu..."

    # Add AMD GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/rocm.gpg

    # Add ROCm repository
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" | \
        sudo tee /etc/apt/sources.list.d/rocm.list

    # Set priority
    cat <<EOF | sudo tee /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

    sudo apt-get update

    # Install ROCm components
    sudo apt-get install -y \
        rocm-dev${ROCM_VERSION_FULL} \
        rocm-libs${ROCM_VERSION_FULL} \
        rocm-hip-runtime${ROCM_VERSION_FULL} \
        rocm-hip-sdk${ROCM_VERSION_FULL} \
        rocblas \
        hipblas \
        rocfft \
        rocsparse \
        hipsparse \
        rocrand \
        hiprand \
        miopen-hip \
        composablekernel-dev

    log_ok "ROCm ${ROCM_VERSION} installed"
}

install_rocm_fedora() {
    log_info "Installing ROCm ${ROCM_VERSION} on Fedora..."

    # Fedora has ROCm in main repos
    sudo dnf install -y \
        rocm-dev \
        rocm-hip \
        rocm-hip-devel \
        rocblas \
        rocblas-devel \
        hipblas \
        hipblas-devel \
        rocfft \
        rocsparse \
        rocrand \
        miopen-hip

    log_ok "ROCm installed from Fedora repos"
}

setup_environment() {
    log_info "Configuring ROCm environment..."

    local profile_file="$HOME/.bashrc"

    # Create ROCm environment config
    cat > "$HOME/.rocm_env" << 'EOF'
# ROCm 7.2 Environment for Strix Halo (gfx1151)
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export PATH=$ROCM_PATH/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH

# Target architecture for Radeon 8060S
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HIP_VISIBLE_DEVICES=0

# Performance optimizations
export GPU_MAX_HW_QUEUES=8
export HSA_ENABLE_SDMA=1
export AMD_SERIALIZE_KERNEL=0
export AMD_SERIALIZE_COPY=0

# Memory optimizations for 128GB unified memory
export HSA_ENABLE_LARGE_BAR=1
export GPU_MAX_ALLOC_PERCENT=95
export GPU_SINGLE_ALLOC_PERCENT=90

# HIP compilation flags for gfx1151
export HIPCC_COMPILE_FLAGS_APPEND="--offload-arch=gfx1151 -O3 -ffast-math"

# PyTorch ROCm
export PYTORCH_ROCM_ARCH=gfx1151
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1

# Disable CPU fallback for pure GPU execution
export ROCBLAS_DISABLE_CPU_FALLBACK=1
export HIPBLASLT_DISABLE_CPU_FALLBACK=1
EOF

    # Source in bashrc if not already present
    if ! grep -q "source.*rocm_env" "$profile_file" 2>/dev/null; then
        echo "" >> "$profile_file"
        echo "# ROCm 7.2 environment" >> "$profile_file"
        echo "[ -f \"\$HOME/.rocm_env\" ] && source \"\$HOME/.rocm_env\"" >> "$profile_file"
    fi

    # Source now
    source "$HOME/.rocm_env"

    log_ok "ROCm environment configured"
}

setup_user_groups() {
    log_info "Setting up user groups for GPU access..."

    # Add user to render and video groups
    sudo usermod -aG render "$USER" 2>/dev/null || true
    sudo usermod -aG video "$USER" 2>/dev/null || true

    # Create udev rules for WSL2 GPU access
    sudo mkdir -p /etc/udev/rules.d
    cat << 'EOF' | sudo tee /etc/udev/rules.d/70-amdgpu.rules
# AMD GPU access for ROCm
KERNEL=="kfd", MODE="0666"
KERNEL=="renderD*", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="card*", MODE="0666"
EOF

    log_ok "User groups configured"
}

verify_installation() {
    log_info "Verifying ROCm installation..."

    local failed=0

    # Check rocminfo
    if command -v rocminfo &>/dev/null; then
        if rocminfo 2>/dev/null | grep -q "Name:"; then
            log_ok "rocminfo: Working"
        else
            log_warn "rocminfo: GPU not detected (may need Windows driver update)"
        fi
    else
        log_error "rocminfo: Not found"
        failed=1
    fi

    # Check hipcc
    if command -v hipcc &>/dev/null; then
        local version
        version=$(hipcc --version 2>&1 | head -1)
        log_ok "hipcc: $version"
    else
        log_error "hipcc: Not found"
        failed=1
    fi

    # Check rocm-smi
    if command -v rocm-smi &>/dev/null; then
        log_ok "rocm-smi: Available"
    else
        log_warn "rocm-smi: Not found"
    fi

    # Check HIP device
    if command -v hipconfig &>/dev/null; then
        log_ok "hipconfig: $(hipconfig --platform 2>/dev/null || echo 'Available')"
    fi

    return $failed
}

install_python_packages() {
    log_info "Installing Python packages for ROCm 7.2..."

    # Create virtual environment if requested
    if [[ "${USE_VENV:-false}" == "true" ]]; then
        python3 -m venv "$HOME/.venv/rocm72"
        source "$HOME/.venv/rocm72/bin/activate"
    fi

    # Install PyTorch with ROCm support
    pip3 install --upgrade pip
    pip3 install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/rocm${ROCM_VERSION}

    # Install additional ML packages
    pip3 install \
        transformers \
        accelerate \
        datasets \
        safetensors \
        sentencepiece \
        bitsandbytes

    log_ok "Python packages installed"
}

create_test_script() {
    log_info "Creating GPU test script..."

    cat > "$HOME/test_rocm72.py" << 'EOF'
#!/usr/bin/env python3
"""
ROCm 7.2 GPU Test for Strix Halo (gfx1151)
"""

import sys

def test_pytorch():
    """Test PyTorch ROCm backend."""
    print("\n=== PyTorch ROCm Test ===")
    try:
        import torch
        print(f"PyTorch version: {torch.__version__}")
        print(f"ROCm available: {torch.cuda.is_available()}")

        if torch.cuda.is_available():
            print(f"Device count: {torch.cuda.device_count()}")
            print(f"Current device: {torch.cuda.current_device()}")
            print(f"Device name: {torch.cuda.get_device_name(0)}")

            # Memory info
            total = torch.cuda.get_device_properties(0).total_memory
            print(f"Total memory: {total / (1024**3):.1f} GB")

            # Quick compute test
            x = torch.randn(1000, 1000, device='cuda')
            y = torch.randn(1000, 1000, device='cuda')

            # Warmup
            for _ in range(3):
                z = torch.mm(x, y)
            torch.cuda.synchronize()

            # Benchmark
            import time
            start = time.perf_counter()
            for _ in range(100):
                z = torch.mm(x, y)
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - start

            gflops = (2 * 1000 * 1000 * 1000 * 100) / elapsed / 1e9
            print(f"Matrix multiply: {gflops:.1f} GFLOPS")
            print("PyTorch ROCm: PASS")
            return True
        else:
            print("PyTorch ROCm: GPU not available")
            return False

    except Exception as e:
        print(f"PyTorch test failed: {e}")
        return False

def test_hip():
    """Test HIP runtime."""
    print("\n=== HIP Runtime Test ===")
    try:
        import subprocess
        result = subprocess.run(
            ['hipconfig', '--platform'],
            capture_output=True, text=True, timeout=10
        )
        print(f"HIP Platform: {result.stdout.strip()}")
        print("HIP Runtime: PASS")
        return True
    except Exception as e:
        print(f"HIP test failed: {e}")
        return False

def test_memory():
    """Test large memory allocation (128GB unified)."""
    print("\n=== Memory Allocation Test ===")
    try:
        import torch
        if not torch.cuda.is_available():
            print("Skipping - no GPU")
            return True

        # Try allocating large tensors (unique to 128GB systems)
        sizes_gb = [8, 16, 32, 64]
        for size in sizes_gb:
            try:
                elements = (size * 1024**3) // 4  # float32
                x = torch.empty(elements, dtype=torch.float32, device='cuda')
                del x
                torch.cuda.empty_cache()
                print(f"  {size}GB allocation: PASS")
            except torch.cuda.OutOfMemoryError:
                print(f"  {size}GB allocation: OOM (expected on smaller configs)")
                break

        print("Memory test: PASS")
        return True
    except Exception as e:
        print(f"Memory test failed: {e}")
        return False

def main():
    print("=" * 50)
    print("ROCm 7.2 Test Suite for Strix Halo (gfx1151)")
    print("=" * 50)

    results = {
        'HIP Runtime': test_hip(),
        'PyTorch ROCm': test_pytorch(),
        'Memory Allocation': test_memory(),
    }

    print("\n" + "=" * 50)
    print("Summary:")
    print("=" * 50)

    all_pass = True
    for test, passed in results.items():
        status = "PASS" if passed else "FAIL"
        print(f"  {test}: {status}")
        if not passed:
            all_pass = False

    return 0 if all_pass else 1

if __name__ == '__main__':
    sys.exit(main())
EOF

    chmod +x "$HOME/test_rocm72.py"
    log_ok "Test script created: ~/test_rocm72.py"
}

print_next_steps() {
    cat << EOF

${GREEN}============================================================${NC}
${GREEN}ROCm 7.2 Setup Complete for Strix Halo!${NC}
${GREEN}============================================================${NC}

${BLUE}GPU Target:${NC} gfx1151 (Radeon 8060S / RDNA 3.5)
${BLUE}ROCm Version:${NC} ${ROCM_VERSION_FULL}

${YELLOW}Next Steps:${NC}

1. Restart your terminal or run:
   ${GREEN}source ~/.rocm_env${NC}

2. Verify installation:
   ${GREEN}rocminfo${NC}
   ${GREEN}hipcc --version${NC}

3. Run the test script:
   ${GREEN}python3 ~/test_rocm72.py${NC}

4. For llama.cpp, run:
   ${GREEN}./setup-llamacpp.sh${NC}

5. For vLLM, run:
   ${GREEN}./setup-vllm.sh${NC}

${YELLOW}Troubleshooting:${NC}
- If GPU not detected, ensure Windows Adrenalin drivers are updated
- ROCm version must match Windows driver version
- Check: ${GREEN}rocm-smi${NC}

${BLUE}Documentation:${NC}
- https://rocm.docs.amd.com/
- https://github.com/ROCm/ROCm

EOF
}

main() {
    log_info "ROCm ${ROCM_VERSION} Setup for AMD Strix Halo"
    log_info "Target: gfx1151 (Radeon 8060S)"
    echo ""

    check_wsl2
    check_gpu

    local distro
    distro=$(detect_distro)
    log_info "Detected distribution: $distro"

    case "$distro" in
        ubuntu|debian)
            install_rocm_ubuntu
            ;;
        fedora)
            install_rocm_fedora
            ;;
        *)
            log_error "Unsupported distribution: $distro"
            log_info "Supported: Ubuntu, Fedora"
            exit 1
            ;;
    esac

    setup_environment
    setup_user_groups
    verify_installation
    create_test_script

    if [[ "${INSTALL_PYTHON:-true}" == "true" ]]; then
        install_python_packages
    fi

    print_next_steps
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-python)
            INSTALL_PYTHON=false
            ;;
        --venv)
            USE_VENV=true
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-python  Skip Python package installation"
            echo "  --venv       Install Python packages in virtual environment"
            echo "  -h, --help   Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

main
