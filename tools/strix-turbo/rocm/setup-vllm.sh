#!/bin/bash
#
# vLLM Setup Script for AMD Strix Halo (gfx1151)
# Optimized for Ryzen AI Max+ 395 with Radeon 8060S GPU
#
# Sets up vLLM with ROCm 7.2 support for high-throughput inference
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLLM_DIR="${VLLM_DIR:-$HOME/vllm}"
GPU_TARGET="gfx1151"
ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
VLLM_VERSION="${VLLM_VERSION:-0.7.3}"

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

    # Check PyTorch ROCm
    if python3 -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
        log_ok "PyTorch ROCm available"
    else
        log_warn "PyTorch ROCm not detected - will install"
    fi
}

check_memory() {
    log_info "Checking system memory..."

    local mem_gb
    mem_gb=$(free -g | awk '/^Mem:/{print $2}')

    if [[ $mem_gb -ge 64 ]]; then
        log_ok "Memory: ${mem_gb}GB (optimal for large models)"
    elif [[ $mem_gb -ge 32 ]]; then
        log_ok "Memory: ${mem_gb}GB (good for medium models)"
    else
        log_warn "Memory: ${mem_gb}GB (limited model support)"
    fi
}

setup_python_env() {
    log_info "Setting up Python environment..."

    # Create virtual environment
    if [[ ! -d "$VLLM_DIR/venv" ]]; then
        python3 -m venv "$VLLM_DIR/venv"
    fi

    source "$VLLM_DIR/venv/bin/activate"

    # Upgrade pip
    pip install --upgrade pip setuptools wheel

    log_ok "Python environment ready"
}

install_pytorch_rocm() {
    log_info "Installing PyTorch with ROCm 7.2 support..."

    source "$VLLM_DIR/venv/bin/activate"

    # Install PyTorch for ROCm
    pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/rocm6.2

    # Verify
    python3 -c "
import torch
print(f'PyTorch version: {torch.__version__}')
print(f'ROCm available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
"

    log_ok "PyTorch ROCm installed"
}

install_vllm_docker() {
    log_info "Setting up vLLM Docker (recommended method)..."

    # Create docker-compose file
    mkdir -p "$VLLM_DIR"

    cat > "$VLLM_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  vllm:
    image: rocm/vllm-omni:latest
    container_name: vllm-strix
    runtime: nvidia
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    volumes:
      - ~/.cache/huggingface:/root/.cache/huggingface
      - $VLLM_DIR/models:/models
    ports:
      - "8000:8000"
    environment:
      - HIP_VISIBLE_DEVICES=0
      - HSA_OVERRIDE_GFX_VERSION=11.5.1
      - ROCM_GPU=gfx1151
      - VLLM_ATTENTION_BACKEND=ROCM_FLASH
      - VLLM_USE_TRITON_FLASH_ATTN=0
      - GPU_MAX_ALLOC_PERCENT=95
    command: >
      --model mistralai/Mistral-7B-v0.1
      --host 0.0.0.0
      --port 8000
      --tensor-parallel-size 1
      --max-model-len 32768
      --gpu-memory-utilization 0.95
    ipc: host
    security_opt:
      - seccomp:unconfined
    cap_add:
      - SYS_PTRACE
EOF

    log_ok "Docker compose file created: $VLLM_DIR/docker-compose.yml"
}

install_vllm_pip() {
    log_info "Installing vLLM from pip..."

    source "$VLLM_DIR/venv/bin/activate"

    # Install vLLM dependencies
    pip install \
        transformers \
        accelerate \
        safetensors \
        sentencepiece \
        protobuf \
        ray \
        aiohttp \
        fastapi \
        uvicorn \
        pydantic

    # Try installing vLLM with ROCm support
    log_info "Installing vLLM (this may take several minutes)..."

    # Option 1: Pre-built wheel (if available)
    if pip install vllm --extra-index-url https://download.pytorch.org/whl/rocm6.2 2>/dev/null; then
        log_ok "vLLM installed from pre-built wheel"
    else
        log_info "Pre-built not available, building from source..."
        install_vllm_source
    fi
}

install_vllm_source() {
    log_info "Building vLLM from source for gfx1151..."

    source "$VLLM_DIR/venv/bin/activate"

    # Install build dependencies
    pip install ninja cmake packaging

    # Clone vLLM
    if [[ -d "$VLLM_DIR/vllm-src" ]]; then
        cd "$VLLM_DIR/vllm-src"
        git fetch origin
        git reset --hard origin/main
    else
        git clone --depth 1 https://github.com/vllm-project/vllm.git "$VLLM_DIR/vllm-src"
        cd "$VLLM_DIR/vllm-src"
    fi

    # Set build environment
    export ROCM_HOME="$ROCM_PATH"
    export HIP_HOME="$ROCM_PATH"
    export PYTORCH_ROCM_ARCH="$GPU_TARGET"
    export VLLM_TARGET_DEVICE="rocm"

    # Build
    pip install -e . --verbose

    log_ok "vLLM built from source"
}

create_wrapper_scripts() {
    log_info "Creating vLLM wrapper scripts..."

    mkdir -p "$VLLM_DIR/scripts"

    # Create server start script
    cat > "$VLLM_DIR/scripts/start-server.sh" << 'EOF'
#!/bin/bash
#
# vLLM Server for Strix Halo (gfx1151)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLLM_DIR="$(dirname "$SCRIPT_DIR")"

# Activate venv
source "$VLLM_DIR/venv/bin/activate"

# ROCm environment
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HIP_VISIBLE_DEVICES=0
export GPU_MAX_ALLOC_PERCENT=95
export HSA_ENABLE_LARGE_BAR=1

# vLLM optimizations for RDNA 3.5
export VLLM_ATTENTION_BACKEND=ROCM_FLASH
export VLLM_USE_TRITON_FLASH_ATTN=0
export VLLM_WORKER_MULTIPROC_METHOD=spawn

# Default settings
MODEL="${MODEL:-mistralai/Mistral-7B-v0.1}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.95}"

echo "=============================================="
echo "vLLM Server for Strix Halo (gfx1151)"
echo "=============================================="
echo "Model: $MODEL"
echo "Host: $HOST:$PORT"
echo "Max Context: $MAX_MODEL_LEN"
echo "GPU Memory: ${GPU_MEM_UTIL}%"
echo ""

exec python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --host "$HOST" \
    --port "$PORT" \
    --max-model-len "$MAX_MODEL_LEN" \
    --gpu-memory-utilization "$GPU_MEM_UTIL" \
    --tensor-parallel-size 1 \
    --dtype auto \
    --trust-remote-code \
    "$@"
EOF

    chmod +x "$VLLM_DIR/scripts/start-server.sh"

    # Create benchmark script
    cat > "$VLLM_DIR/scripts/benchmark.sh" << 'EOF'
#!/bin/bash
#
# vLLM Benchmark for Strix Halo (gfx1151)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLLM_DIR="$(dirname "$SCRIPT_DIR")"

source "$VLLM_DIR/venv/bin/activate"

# ROCm environment
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export GPU_MAX_ALLOC_PERCENT=95

MODEL="${MODEL:-mistralai/Mistral-7B-v0.1}"
NUM_PROMPTS="${NUM_PROMPTS:-100}"
INPUT_LEN="${INPUT_LEN:-256}"
OUTPUT_LEN="${OUTPUT_LEN:-128}"

echo "=============================================="
echo "vLLM Benchmark for Strix Halo (gfx1151)"
echo "=============================================="
echo "Model: $MODEL"
echo "Prompts: $NUM_PROMPTS"
echo "Input Length: $INPUT_LEN"
echo "Output Length: $OUTPUT_LEN"
echo ""

python -m vllm.entrypoints.openai.benchmark \
    --model "$MODEL" \
    --num-prompts "$NUM_PROMPTS" \
    --input-len "$INPUT_LEN" \
    --output-len "$OUTPUT_LEN" \
    --trust-remote-code \
    "$@"
EOF

    chmod +x "$VLLM_DIR/scripts/benchmark.sh"

    # Create offline inference script
    cat > "$VLLM_DIR/scripts/offline-inference.py" << 'EOF'
#!/usr/bin/env python3
"""
Offline Inference Example for Strix Halo (gfx1151)
"""

import os

# Set ROCm environment
os.environ['HSA_OVERRIDE_GFX_VERSION'] = '11.5.1'
os.environ['ROCM_GPU'] = 'gfx1151'
os.environ['GPU_MAX_ALLOC_PERCENT'] = '95'
os.environ['VLLM_ATTENTION_BACKEND'] = 'ROCM_FLASH'

from vllm import LLM, SamplingParams

def main():
    # Model to use
    model_name = os.environ.get('MODEL', 'mistralai/Mistral-7B-v0.1')

    print(f"Loading model: {model_name}")
    print("GPU: Radeon 8060S (gfx1151)")
    print()

    # Initialize LLM with Strix Halo optimizations
    llm = LLM(
        model=model_name,
        tensor_parallel_size=1,
        gpu_memory_utilization=0.95,
        max_model_len=32768,
        trust_remote_code=True,
        dtype='auto',
    )

    # Sample prompts
    prompts = [
        "Explain quantum computing in simple terms:",
        "Write a Python function to find prime numbers:",
        "What are the key differences between ROCm and CUDA?",
        "Describe the benefits of AMD's unified memory architecture:",
    ]

    # Sampling parameters
    sampling_params = SamplingParams(
        temperature=0.7,
        top_p=0.9,
        max_tokens=256,
    )

    print("Generating responses...")
    print("=" * 60)

    outputs = llm.generate(prompts, sampling_params)

    for output in outputs:
        prompt = output.prompt
        generated = output.outputs[0].text
        print(f"\nPrompt: {prompt[:50]}...")
        print(f"Response: {generated[:200]}...")
        print("-" * 60)

    print("\nDone!")

if __name__ == '__main__':
    main()
EOF

    chmod +x "$VLLM_DIR/scripts/offline-inference.py"

    log_ok "Wrapper scripts created"
}

create_config_file() {
    log_info "Creating vLLM configuration..."

    cat > "$VLLM_DIR/config.yaml" << EOF
# vLLM Configuration for Strix Halo (gfx1151)
# Radeon 8060S with 128GB unified memory

# Model settings
model: "mistralai/Mistral-7B-v0.1"
dtype: "auto"
trust_remote_code: true

# Hardware settings
tensor_parallel_size: 1
gpu_memory_utilization: 0.95
max_model_len: 32768

# Serving settings
host: "0.0.0.0"
port: 8000
max_num_seqs: 256
max_num_batched_tokens: 32768

# Performance optimizations for RDNA 3.5
enable_chunked_prefill: true
enable_prefix_caching: true
swap_space: 32  # GB - use unified memory

# ROCm-specific settings
# Set via environment variables:
#   HSA_OVERRIDE_GFX_VERSION=11.5.1
#   VLLM_ATTENTION_BACKEND=ROCM_FLASH
#   GPU_MAX_ALLOC_PERCENT=95

# Recommended models for 128GB:
#
# | Model                      | VRAM Usage | Max Context |
# |----------------------------|------------|-------------|
# | Llama-3.1-70B              | ~140GB FP16, ~70GB FP8 | 128K |
# | Llama-3.1-8B               | ~16GB FP16 | 128K |
# | Mistral-7B                 | ~14GB FP16 | 32K |
# | Mixtral-8x7B               | ~90GB FP16, ~45GB FP8 | 32K |
# | Qwen2.5-72B                | ~144GB FP16, ~72GB FP8 | 128K |
# | DeepSeek-V2-Lite           | ~32GB FP16 | 128K |
EOF

    log_ok "Configuration created: $VLLM_DIR/config.yaml"
}

verify_installation() {
    log_info "Verifying vLLM installation..."

    source "$VLLM_DIR/venv/bin/activate"

    # Check import
    if python3 -c "import vllm; print(f'vLLM version: {vllm.__version__}')" 2>/dev/null; then
        log_ok "vLLM imported successfully"
    else
        log_error "Failed to import vLLM"
        return 1
    fi

    # Check ROCm support
    if python3 -c "
import torch
assert torch.cuda.is_available(), 'CUDA/ROCm not available'
print(f'GPU: {torch.cuda.get_device_name(0)}')
" 2>/dev/null; then
        log_ok "ROCm GPU available"
    else
        log_warn "GPU not detected (may need driver update)"
    fi

    return 0
}

print_usage() {
    cat << EOF

${GREEN}============================================================${NC}
${GREEN}vLLM Setup Complete for Strix Halo!${NC}
${GREEN}============================================================${NC}

${BLUE}Installation Directory:${NC} $VLLM_DIR
${BLUE}GPU Target:${NC} gfx1151 (Radeon 8060S)

${YELLOW}Usage:${NC}

1. Activate environment:
   ${GREEN}source $VLLM_DIR/venv/bin/activate${NC}

2. Start OpenAI-compatible server:
   ${GREEN}$VLLM_DIR/scripts/start-server.sh${NC}

3. Or with custom model:
   ${GREEN}MODEL=meta-llama/Llama-3.1-8B $VLLM_DIR/scripts/start-server.sh${NC}

4. Run offline inference:
   ${GREEN}python $VLLM_DIR/scripts/offline-inference.py${NC}

5. Benchmark:
   ${GREEN}$VLLM_DIR/scripts/benchmark.sh${NC}

${YELLOW}Docker Alternative:${NC}
   ${GREEN}cd $VLLM_DIR && docker-compose up${NC}

${YELLOW}API Usage (once server is running):${NC}

${GREEN}curl http://localhost:8000/v1/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "mistralai/Mistral-7B-v0.1",
    "prompt": "Write a hello world in Python:",
    "max_tokens": 100
  }'${NC}

${YELLOW}Recommended Models for 128GB Unified Memory:${NC}

| Model | Memory | Context | Notes |
|-------|--------|---------|-------|
| Llama-3.1-70B | ~70GB FP8 | 128K | Flagship |
| Qwen2.5-72B | ~72GB FP8 | 128K | Excellent coding |
| Mixtral-8x7B | ~45GB FP8 | 32K | Fast MoE |
| DeepSeek-V2 | ~32GB FP16 | 128K | Efficient MoE |

${BLUE}Configuration:${NC} $VLLM_DIR/config.yaml

EOF
}

main() {
    log_info "vLLM Setup for AMD Strix Halo (gfx1151)"
    echo ""

    mkdir -p "$VLLM_DIR"

    check_rocm
    check_memory
    setup_python_env
    install_pytorch_rocm
    install_vllm_docker
    install_vllm_pip
    create_wrapper_scripts
    create_config_file
    verify_installation || true

    print_usage
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-dir)
            VLLM_DIR="$2"
            shift 2
            ;;
        --docker-only)
            install_vllm_docker
            exit 0
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --install-dir DIR    Installation directory (default: ~/vllm)"
            echo "  --docker-only        Only create Docker configuration"
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
