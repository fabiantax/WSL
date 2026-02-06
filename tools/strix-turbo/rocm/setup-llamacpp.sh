#!/bin/bash
#
# llama.cpp Setup Script for AMD Strix Halo (gfx1151)
# Optimized for Ryzen AI Max+ 395 with Radeon 8060S GPU
#
# Builds llama.cpp with ROCm 7.2 support and gfx1151 optimizations
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/llama.cpp}"
GPU_TARGET="gfx1151"
ROCM_PATH="${ROCM_PATH:-/opt/rocm}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_rocm() {
    log_info "Checking ROCm installation..."

    if ! command -v hipcc &>/dev/null; then
        log_error "hipcc not found. Please run setup-rocm72.sh first"
        exit 1
    fi

    local version
    version=$(hipcc --version 2>&1 | grep -oP 'HIP version: \K[0-9.]+' || echo "unknown")
    log_ok "ROCm/HIP version: $version"
}

install_dependencies() {
    log_info "Installing build dependencies..."

    if command -v apt-get &>/dev/null; then
        sudo apt-get update
        sudo apt-get install -y \
            build-essential \
            cmake \
            git \
            pkg-config \
            libcurl4-openssl-dev \
            ccache
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y \
            gcc-c++ \
            cmake \
            git \
            pkgconfig \
            libcurl-devel \
            ccache
    fi

    log_ok "Dependencies installed"
}

clone_or_update_repo() {
    log_info "Setting up llama.cpp repository..."

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log_info "Updating existing repository..."
        cd "$INSTALL_DIR"
        git fetch origin
        git reset --hard origin/master
    else
        log_info "Cloning llama.cpp..."
        git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    log_ok "Repository ready at $INSTALL_DIR"
}

build_llamacpp() {
    log_info "Building llama.cpp with ROCm support for gfx1151..."

    cd "$INSTALL_DIR"

    # Clean previous build
    rm -rf build

    # Configure with ROCm and gfx1151 optimizations
    cmake -B build \
        -DGGML_HIP=ON \
        -DAMDGPU_TARGETS="$GPU_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=hipcc \
        -DCMAKE_CXX_COMPILER=hipcc \
        -DCMAKE_HIP_ARCHITECTURES="$GPU_TARGET" \
        -DGGML_NATIVE=ON \
        -DGGML_LTO=ON \
        -DGGML_CUDA_NO_PEER_COPY=OFF \
        -DGGML_HIP_UMA=ON \
        -DCMAKE_C_FLAGS="-O3 -march=znver5 -mtune=znver5" \
        -DCMAKE_CXX_FLAGS="-O3 -march=znver5 -mtune=znver5" \
        -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
        -DLLAMA_CURL=ON \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_EXAMPLES=ON

    # Build with all cores
    local jobs
    jobs=$(nproc)
    log_info "Building with $jobs parallel jobs..."

    cmake --build build --config Release -j "$jobs"

    log_ok "llama.cpp built successfully"
}

create_wrapper_scripts() {
    log_info "Creating optimized wrapper scripts..."

    # Create main runner script
    cat > "$INSTALL_DIR/run-llama.sh" << 'EOF'
#!/bin/bash
#
# Optimized llama.cpp runner for Strix Halo (gfx1151)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ROCm environment
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HIP_VISIBLE_DEVICES=0

# Memory optimizations for 128GB unified memory
export HSA_ENABLE_LARGE_BAR=1
export GPU_MAX_ALLOC_PERCENT=95
export GPU_SINGLE_ALLOC_PERCENT=90

# Performance tuning
export GPU_MAX_HW_QUEUES=8
export HSA_ENABLE_SDMA=1
export AMD_SERIALIZE_KERNEL=0

# Default parameters optimized for Strix Halo
DEFAULT_THREADS=$(( $(nproc) / 2 ))
DEFAULT_GPU_LAYERS=99
DEFAULT_BATCH=2048
DEFAULT_UBATCH=512
DEFAULT_CTX=8192

# Parse model argument
MODEL=""
for arg in "$@"; do
    if [[ "$arg" == "-m" || "$arg" == "--model" ]]; then
        shift
        MODEL="$1"
        break
    fi
done

# Run with optimized settings
exec "$SCRIPT_DIR/build/bin/llama-cli" \
    --threads "$DEFAULT_THREADS" \
    --n-gpu-layers "$DEFAULT_GPU_LAYERS" \
    --batch-size "$DEFAULT_BATCH" \
    --ubatch-size "$DEFAULT_UBATCH" \
    --ctx-size "$DEFAULT_CTX" \
    --flash-attn \
    --mlock \
    "$@"
EOF

    chmod +x "$INSTALL_DIR/run-llama.sh"

    # Create server script
    cat > "$INSTALL_DIR/run-server.sh" << 'EOF'
#!/bin/bash
#
# llama.cpp server for Strix Halo (gfx1151)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ROCm environment
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HIP_VISIBLE_DEVICES=0
export HSA_ENABLE_LARGE_BAR=1
export GPU_MAX_ALLOC_PERCENT=95

# Server defaults
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
THREADS=$(( $(nproc) / 2 ))
PARALLEL="${PARALLEL:-4}"

exec "$SCRIPT_DIR/build/bin/llama-server" \
    --host "$HOST" \
    --port "$PORT" \
    --threads "$THREADS" \
    --n-gpu-layers 99 \
    --batch-size 2048 \
    --ubatch-size 512 \
    --parallel "$PARALLEL" \
    --flash-attn \
    --mlock \
    "$@"
EOF

    chmod +x "$INSTALL_DIR/run-server.sh"

    # Create benchmark script
    cat > "$INSTALL_DIR/benchmark-gfx1151.sh" << 'EOF'
#!/bin/bash
#
# Benchmark llama.cpp on Strix Halo (gfx1151)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ROCm environment
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HSA_ENABLE_LARGE_BAR=1
export GPU_MAX_ALLOC_PERCENT=95

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
    echo "Usage: $0 <model.gguf>"
    exit 1
fi

echo "=============================================="
echo "llama.cpp Benchmark for Strix Halo (gfx1151)"
echo "=============================================="
echo ""
echo "Model: $MODEL"
echo "GPU: Radeon 8060S (gfx1151, RDNA 3.5)"
echo ""

# Run benchmark
"$SCRIPT_DIR/build/bin/llama-bench" \
    -m "$MODEL" \
    -n 128 \
    -ngl 99 \
    -b 2048 \
    -ub 512 \
    -fa 1 \
    -t "$(( $(nproc) / 2 ))" \
    --output csv

echo ""
echo "Benchmark complete!"
EOF

    chmod +x "$INSTALL_DIR/benchmark-gfx1151.sh"

    log_ok "Wrapper scripts created"
}

download_test_model() {
    log_info "Downloading test model..."

    local models_dir="$INSTALL_DIR/models"
    mkdir -p "$models_dir"

    # Download a small quantized model for testing
    if [[ ! -f "$models_dir/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf" ]]; then
        log_info "Downloading TinyLlama 1.1B for testing..."
        curl -L -o "$models_dir/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf" \
            "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"
        log_ok "Test model downloaded"
    else
        log_ok "Test model already exists"
    fi
}

verify_build() {
    log_info "Verifying build..."

    cd "$INSTALL_DIR"

    # Check binary exists
    if [[ ! -f "build/bin/llama-cli" ]]; then
        log_error "llama-cli not found"
        return 1
    fi

    # Check HIP support
    if ldd build/bin/llama-cli | grep -q "libamdhip"; then
        log_ok "HIP/ROCm support linked"
    else
        log_warn "HIP libraries not detected in binary"
    fi

    # Quick test run
    log_info "Running quick verification..."
    if ./build/bin/llama-cli --help &>/dev/null; then
        log_ok "llama-cli executes correctly"
    else
        log_error "llama-cli failed to run"
        return 1
    fi

    return 0
}

print_usage() {
    cat << EOF

${GREEN}============================================================${NC}
${GREEN}llama.cpp Setup Complete for Strix Halo!${NC}
${GREEN}============================================================${NC}

${BLUE}Installation Directory:${NC} $INSTALL_DIR
${BLUE}GPU Target:${NC} gfx1151 (Radeon 8060S)

${YELLOW}Usage Examples:${NC}

1. Interactive chat:
   ${GREEN}cd $INSTALL_DIR${NC}
   ${GREEN}./run-llama.sh -m models/your-model.gguf -i${NC}

2. Start API server:
   ${GREEN}./run-server.sh -m models/your-model.gguf${NC}

3. Run benchmark:
   ${GREEN}./benchmark-gfx1151.sh models/your-model.gguf${NC}

${YELLOW}Recommended Models for 128GB System:${NC}

| Model | Size | Context | Notes |
|-------|------|---------|-------|
| Llama 3.1 70B Q8_0 | ~70GB | 128K | Full precision |
| Llama 3.1 70B Q4_K_M | ~40GB | 128K | Best quality/size |
| Qwen2.5 72B Q4_K_M | ~42GB | 32K | Excellent coding |
| DeepSeek-V2 236B Q2_K | ~90GB | 128K | Massive MoE |
| Mixtral 8x22B Q4_K_M | ~80GB | 64K | Fast MoE |

${YELLOW}Performance Tips:${NC}

- Use --flash-attn for faster inference
- Set --n-gpu-layers 99 to offload all layers
- Use --mlock to prevent swapping
- Increase --batch-size for faster prompt processing
- Use Q4_K_M quantization for best quality/speed

${BLUE}Direct binary access:${NC}
  $INSTALL_DIR/build/bin/llama-cli
  $INSTALL_DIR/build/bin/llama-server
  $INSTALL_DIR/build/bin/llama-bench

EOF
}

main() {
    log_info "llama.cpp Setup for AMD Strix Halo (gfx1151)"
    echo ""

    check_rocm
    install_dependencies
    clone_or_update_repo
    build_llamacpp
    create_wrapper_scripts

    if [[ "${DOWNLOAD_MODEL:-false}" == "true" ]]; then
        download_test_model
    fi

    verify_build
    print_usage
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --download-model)
            DOWNLOAD_MODEL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --install-dir DIR    Installation directory (default: ~/llama.cpp)"
            echo "  --download-model     Download a test model"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

main
