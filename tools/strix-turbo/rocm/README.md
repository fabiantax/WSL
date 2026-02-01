# ROCm 7.2 Integration for Strix Halo

This directory contains scripts to set up ROCm 7.2 with full support for AMD Strix Halo (Ryzen AI Max+ 395) hardware.

## Hardware Target

| Component | Specification |
|-----------|---------------|
| APU | AMD Ryzen AI Max+ 395 (Strix Halo) |
| GPU | Radeon 8060S (gfx1151, RDNA 3.5) |
| GPU Cores | 40 Compute Units |
| NPU | XDNA 2 (50 TOPS) |
| Memory | 128GB Unified (shared CPU/GPU/NPU) |
| ROCm Target | gfx1151 |

## Scripts

### 1. setup-rocm72.sh - Base ROCm Installation

Installs ROCm 7.2 with gfx1151 support:

```bash
./setup-rocm72.sh
```

Options:
- `--no-python` - Skip Python package installation
- `--venv` - Install Python packages in virtual environment

What it does:
- Installs ROCm 7.2 packages (rocm-dev, rocm-libs, etc.)
- Configures environment variables for gfx1151
- Sets up user groups for GPU access
- Installs PyTorch with ROCm backend
- Creates verification test script

### 2. setup-llamacpp.sh - llama.cpp with ROCm

Builds llama.cpp optimized for Strix Halo:

```bash
./setup-llamacpp.sh
```

Options:
- `--install-dir DIR` - Custom installation directory
- `--download-model` - Download a test model

Features:
- Builds with HIP/ROCm and gfx1151 target
- Zen 5 CPU optimizations (-march=znver5)
- UMA (Unified Memory Access) enabled
- Flash attention support
- Wrapper scripts with optimal defaults

### 3. setup-vllm.sh - vLLM with ROCm

Sets up vLLM for high-throughput inference:

```bash
./setup-vllm.sh
```

Options:
- `--install-dir DIR` - Custom installation directory
- `--docker-only` - Only create Docker configuration

Features:
- Docker and pip installation options
- OpenAI-compatible API server
- Optimized for 128GB unified memory
- ROCm Flash Attention backend

## Quick Start

```bash
# 1. Install ROCm 7.2
./setup-rocm72.sh

# 2. Restart terminal or source environment
source ~/.rocm_env

# 3. Verify installation
rocminfo | grep gfx1151
python3 ~/test_rocm72.py

# 4. Set up llama.cpp
./setup-llamacpp.sh

# 5. Run inference
cd ~/llama.cpp
./run-llama.sh -m models/your-model.gguf -i
```

## Environment Variables

Key environment variables set by setup-rocm72.sh:

```bash
# GPU target
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCM_GPU=gfx1151
export HIP_VISIBLE_DEVICES=0

# Memory optimizations (128GB unified)
export HSA_ENABLE_LARGE_BAR=1
export GPU_MAX_ALLOC_PERCENT=95
export GPU_SINGLE_ALLOC_PERCENT=90

# Performance
export GPU_MAX_HW_QUEUES=8
export HSA_ENABLE_SDMA=1

# PyTorch
export PYTORCH_ROCM_ARCH=gfx1151
```

## Recommended Models

With 128GB unified memory, you can run large models entirely on GPU:

| Model | Size | Context | VRAM |
|-------|------|---------|------|
| Llama 3.1 70B Q4_K_M | 40GB | 128K | ~45GB |
| Llama 3.1 70B Q8_0 | 70GB | 128K | ~75GB |
| Qwen2.5 72B Q4_K_M | 42GB | 128K | ~47GB |
| Mixtral 8x22B Q4_K_M | 80GB | 64K | ~85GB |
| DeepSeek-V2 236B Q2_K | 90GB | 128K | ~95GB |

## Performance Tips

1. **Use Flash Attention**: Both llama.cpp and vLLM support flash attention for faster inference

2. **Maximize GPU Offload**: Set `--n-gpu-layers 99` (llama.cpp) or `gpu_memory_utilization=0.95` (vLLM)

3. **Enable Memory Lock**: Use `--mlock` to prevent swapping to disk

4. **Batch Size**: Increase batch size for faster prompt processing

5. **Quantization**: Q4_K_M offers best quality/speed trade-off

## Troubleshooting

### GPU Not Detected

1. Check Windows Adrenalin driver version matches ROCm version
2. Verify GPU passthrough in WSL2: `ls /dev/dri/`
3. Check rocminfo: `rocminfo 2>&1 | head -50`

### Out of Memory

1. Reduce `GPU_MAX_ALLOC_PERCENT`
2. Use smaller quantization (Q4_K_M instead of Q8_0)
3. Reduce context length

### Performance Issues

1. Ensure `HSA_ENABLE_LARGE_BAR=1` is set
2. Check for thermal throttling: `rocm-smi`
3. Verify gfx1151 target is used in builds

## Related Documentation

- [ROCm Documentation](https://rocm.docs.amd.com/)
- [llama.cpp ROCm Guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/3rd-party/llama-cpp-install.html)
- [vLLM ROCm Blog](https://rocm.blogs.amd.com/software-tools-optimization/vllm-omni/README.html)

## Version History

- ROCm 7.2.2 - Current supported version
- gfx1151 - Strix Halo GPU target (RDNA 3.5)
- WSL2 - Windows Subsystem for Linux 2
