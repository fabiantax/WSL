# Heterogeneous Compute Research for AMD Strix Halo
## NPU + GPU/CPU Hybrid AI Workloads on WSL2

**Date:** 2026-02-04
**Target Hardware:** AMD Ryzen AI Max+ 395 (Strix Halo)
- CPU: Zen 5, 16 cores / 32 threads with AVX-512
- GPU: RDNA 3.5 integrated (gfx1151), 40 CUs, up to 128GB shared memory
- NPU: XDNA 2 (Phoenix), up to 50 TOPS

**Context:** WSL2 where GPU compute via ROCm is NOT yet available (blocked by AMD driver), but NPU access exists via Windows bridge service.

---

## Executive Summary

Heterogeneous compute combining NPU, CPU, and eventually GPU is the dominant approach for AI workloads in 2026. For Strix Halo on WSL2, the optimal strategy is:

1. **NPU for Prefill (Compute-Intensive):** Use XDNA 2 NPU (50 TOPS) for the compute-intensive prefill phase of LLM inference
2. **CPU for Decode (Memory-Intensive):** Use Zen 5 CPU with AVX-512 for decode phase until GPU ROCm support arrives
3. **Framework:** ONNX Runtime GenAI (OGA) with hybrid execution provider
4. **Theoretical Performance:** NPU (50 TOPS) + CPU (estimated 3-5 TOPS INT8) = 53-55 combined TOPS
5. **When GPU Available:** Switch to NPU (prefill) + GPU (decode) for maximum performance

---

## 1. AMD XDNA SDK - Heterogeneous Compute Capabilities

### Architecture Overview

AMD XDNA is a **spatial dataflow NPU architecture** consisting of a tiled array of AI Engine processors. The Ryzen AI software provides a **unified software stack spanning CPU, GPU, and NPU**, enabling developers to leverage all three processing units seamlessly.

**Key Capabilities:**
- XDNA 2 delivers up to **50 TOPS** dedicated AI performance on Strix Halo
- L3 cache is **unified main memory shared between CPU, NPU, and iGPU**
- Direct memory access between compute units enables efficient heterogeneous workflows
- Support via AMD's ROCm (Radeon Open Compute) and Vitis AI software stacks

**Development Environment:**
- Ryzen AI Embedded processors provide a **consistent development environment** with a unified software stack
- Optimized CPU libraries, open-standard GPU APIs, and native XDNA architecture AI runtime
- Video tutorials demonstrate how Ryzen AI 300 series uses both NPUs and iGPUs to accelerate LLM workloads

**Real-World Validation (2026):**
- Platform supports dispatch across multiple compute units
- Lemonade benchmarks serve and benchmark LLMs on CPU, GPU, and NPU, indicating mature heterogeneous support

**Sources:**
- [AMD XDNA - Wikipedia](https://en.wikipedia.org/wiki/AMD_XDNA)
- [AMD XDNA™ Architecture](https://www.amd.com/en/technologies/xdna.html)
- [AMD Ryzen™ AI Software](https://www.amd.com/en/developer/resources/ryzen-ai-software.html)

---

## 2. AMD Ryzen AI Software - Model Splitting Across NPU/GPU/CPU

### Hybrid LLM Execution Strategy

AMD has developed sophisticated approaches for **splitting AI workloads across compute units** based on workload characteristics:

**Prefill vs. Decode Split:**
- **NPU for compute-intensive prefill:** High AI Engine capability at 50 TOPS
- **GPU for memory-intensive decode:** High bandwidth for iterative token generation
- **Result:** Faster end-to-end inference, lower latency, reduced power consumption

This approach is particularly effective for **RAG (Retrieval Augmented Generation)** applications.

### Model Pipelining

Ryzen AI processors enable **building high-performance applications through strategic pipelining**:
- Run CNN models on NPU alongside generative models on iGPU
- Distribute models based on computational requirements and hardware support
- Maximize processor potential through intelligent workload distribution

### Hardware Selection Criteria

**When to use each compute unit:**

| Hardware | Best For | Characteristics |
|----------|----------|-----------------|
| **NPU** | Small-medium models, power efficiency | Lower power consumption, 50 TOPS, optimized for inference |
| **iGPU** | Very large iterative models | High bandwidth for memory-intensive operations |
| **CPU** | Complex control flow, FP operations | Flexible, lower throughput but handles all operations |

### AI Analyzer Tool

AMD provides **AI Analyzer** to visualize:
- Graph and operator partitions between NPU and CPU
- Breakdown of model execution across compute units
- Helps optimize which layers run where

**Sources:**
- [Model Pipelining on NPU and GPU using Ryzen™ AI Software](https://www.amd.com/en/developer/resources/technical-articles/model-pipelining-on-npu-and-gpu-using-ryzen-ai-software.html)
- [RAG with Hybrid LLM on AMD Ryzen AI Processors](https://www.amd.com/en/developer/resources/technical-articles/2025/rag-with-hybrid-llm-on-amd-ryzen-ai-processors.html)
- [AMD Ryzen™ AI Software](https://www.amd.com/en/developer/resources/ryzen-ai-software.html)

---

## 3. ONNX Runtime Execution Provider System - Hybrid NPU-CPU

### Hybrid Execution Architecture

**ONNX Runtime** with the **Vitis AI Execution Provider** automatically partitions ONNX graphs:
- Operators supported by NPU execute on NPU
- Remaining subgraphs execute on CPU
- Uses `GetCapability()` interface to allocate nodes/sub-graphs to execution providers
- Abstracts hardware-specific details across CPU, GPU, FPGA, and NPUs

### Windows ML Integration (2025-2026)

**Windows ML** extends ONNX Runtime APIs to handle:
- Dynamic initialization and dependency management of execution providers
- Support across CPU, NPU, and GPU hardware on PCs
- Optimizes for latency, throughput, memory utilization, and binary size

### OnnxRuntime GenAI (OGA) Flow

The **OGA hybrid mode** for LLMs:
- Uses both NPU and iGPU for optimal performance
- Achieves best **time-to-first-token (TTFT)** and **tokens-per-second (TPS)**
- Prefill phase: High-compute workloads on NPU
- Decode phase: Memory-intensive operations on GPU/CPU

### Hybrid CPU-NPU for LLMs

**Specialized workload distribution strategy:**
- NPU handles computationally intensive operations (matrix multiplications)
- CPU manages complex control flow and decision logic
- Maximizes LLM inference performance through strengths of both units

**Implementation Status (2026):**
- Actively deployed via AMD's Ryzen AI software
- Microsoft's Windows ML framework provides key implementations
- Mature hybrid NPU-CPU inference capabilities available

**Sources:**
- [ONNX Runtime Execution Providers](https://onnxruntime.ai/docs/execution-providers/)
- [Vitis AI Execution Provider - AMD](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html)
- [OnnxRuntime GenAI (OGA) Flow](https://ryzenai.docs.amd.com/en/latest/hybrid_oga.html)
- [Hybrid CPU-NPU Execution | amd/RyzenAI-SW](https://deepwiki.com/amd/RyzenAI-SW/4.2-hybrid-cpu-npu-execution)

---

## 4. llama.cpp NPU Offloading Status

### Current NPU Support

**Ascend NPU:**
- llama.cpp provides NPU acceleration via AI cores of **Ascend NPU through CANN**
- Hierarchical API to build AI applications on Ascend NPU
- Production-ready support

**Intel NPU (In Development):**
- PR exists to enable **OpenVINO as a new backend** in llama.cpp
- Would support Intel CPU/GPU/NPU
- Not yet merged as of 2026

**AMD XDNA NPU:**
- No direct llama.cpp support for AMD XDNA as of February 2026
- Community discussion exists but no production implementation

### Hybrid Offloading Strategies

**Current Best Practices:**

1. **Attention Layers on Accelerator:**
   - Attention tensors perform extremely well on GPU/NPU
   - Used very often in inference
   - Keep in VRAM/fast memory

2. **Feed-Forward Networks on CPU:**
   - FFN tensors of experts used less often
   - Less impactful to offload to CPU
   - Acceptable performance degradation

3. **Recommended Configuration:**
   - Offload just attention tensors and KV cache to accelerator
   - Keep rest of model in CPU RAM
   - Provides decent performance with large models

### Future Research Directions

Identified needs (not yet implemented):
- Extended context support and hybrid KV cache strategies for long-sequence inference
- Improved hardware heterogeneity with NPU/DSP offload support
- Deep integration with mobile SoC NPUs

**Key Limitation:**
> "The lack of deep integration with NPU/DSP offload is currently a performance bottleneck on many mobile SOCs."

**Sources:**
- [llama.cpp/docs/build.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md)
- [Support for Intel Neural Processing Unit (NPU) and Intel Arc GPU acceleration](https://github.com/ggml-org/llama.cpp/discussions/15883)
- [Performant local mixture-of-experts CPU inference with GPU acceleration](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)

---

## 5. vLLM NPU Acceleration Status

### Current State (2026)

**vLLM-Omni NPU Project:**
- Completed initial **Ascend NPU enablement** in v0.11.0rc1 and v0.12.0rc1
- Q1 2026 roadmap focuses on expanding model coverage and performance optimization
- **NOT for AMD XDNA** - this is Huawei Ascend NPUs

**AMD XDNA Focus:**
- Current vLLM implementations on AMD use **GPU acceleration via ROCm**
- Examples use AMD Instinct GPUs and Radeon iGPUs
- **No evidence of vLLM running on AMD XDNA NPUs specifically**

### AMD XDNA NPU Applications (2026)

AMD XDNA NPUs are being used for:
- **Stable Diffusion** and image generation optimized for XDNA 2
- **Super resolution acceleration**
- **Power-efficient AI inference tasks**
- BF16 NPU models for SD 3.0 Medium (world's first)

### ROCm/vLLM on AMD GPUs

- Early ROCm/vLLM support for AMD processors exists
- Requires careful tuning to hit peak throughput
- Used with AMD Radeon iGPUs and Instinct GPUs (not NPU)
- One of the most popular frameworks for LLMs on AMD hardware

**Conclusion:** vLLM does not currently support AMD XDNA NPUs. For LLM inference on Strix Halo NPU, use ONNX Runtime GenAI instead.

**Sources:**
- [vLLM-Omni NPU 2026 Q1 Roadmap](https://github.com/vllm-project/vllm-omni/issues/886)
- [AMD XDNA NPUs: Architecture & Optimization](https://www.emergentmind.com/topics/amd-xdna-npus)
- [Introducing The World's First BF16 NPU Model for SD 3.0 Medium](https://www.amd.com/en/blogs/2025/worlds-first-bf16-sd3-medium-npu-model.html)

---

## 6. Qualcomm Snapdragon NPU+GPU Lessons

### Heterogeneous Architecture Philosophy

Qualcomm's approach:
- **NPU designed from ground-up for generative AI**
- Heterogeneous mix of CPU, GPU, and NPU processors
- **Intelligent task allocation** to most suitable processor
- Optimal balance of performance, thermal efficiency, and battery life

### Performance Advantages

**Benchmark Results:**
- NPU provides up to **100x speedup over CPU**
- NPU provides up to **10x speedup over GPU**
- On Snapdragon 8 Elite Gen 5: 56 models run in <5ms on NPU vs. only 13 on CPU

### 2026 Hardware Evolution

**Snapdragon X2 Plus:**
- Previous generation: 45 TOPS
- X2 Plus (2026): **80 TOPS** (matching premium X2 Elite)
- Demonstrates rapid NPU capability growth

### Parallel Processing Benefits

**Key Insight:**
> "The NPU runs parallel to the GPU and CPU, enabling the heavy AI processing. This concurrency frees the GPU to focus on rendering and the CPU on main-thread logic."

### Hybrid Inference Strategy

**Optimal Workload Distribution:**
- **NPU for prefill** (compute-intensive)
- **CPU or GPU for decode** (memory-intensive)
- Suitable approach for future optimization

### Programming Challenges

**Current Limitation:**
> "Developers cannot customize high-performance low-level kernels even though the full LLVM toolchain for Hexagon NPU is provided in the Hexagon SDK, mainly because the instructions for the matrix unit remain undisclosed."

This highlights ongoing software accessibility challenges across the NPU ecosystem.

### Advanced Optimizations (Snapdragon 8 Gen 3)

- Latest Hexagon NPU designed specifically for generative AI
- **98% faster performance** than previous generation
- **40% improved performance-per-watt** for sustained AI inferencing

**Key Takeaway:** Heterogeneous computing with specialized NPUs is the standard for mobile AI in 2026, with substantial performance and efficiency when workloads are appropriately distributed.

**Sources:**
- [Unlocking on-device generative AI with an NPU and heterogeneous computing](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Unlocking-on-device-generative-AI-with-an-NPU-and-heterogeneous-computing.pdf)
- [Qualcomm NPU: A Key to Unlocking On-Device Generative AI?](https://futurumgroup.com/insights/qualcomm-npu-a-key-to-unlocking-on-device-generative-ai/)
- [Scaling LLM Test-Time Compute with Mobile NPU on Smartphones](https://arxiv.org/html/2509.23324v1)

---

## 7. NPU Attention Layers + CPU for Rest (Hybrid llama.cpp)

### NPU Challenges with Attention Operations

**Fundamental Problem:**
> "NPUs face challenges in supporting attention operations, as many have limited support for attention, dynamic shapes, or certain activations."

**Mobile NPU Constraints:**
- Provide significant **integer-based MatMul acceleration**
- Weak at FP operations
- LLMs can hardly be quantized to integer-only with minimal accuracy loss
- Quantized LLMs still rely on float operators like **LayerNorm and Attention**
- Scheduling FP operators out of NPU increases inference critical path

### Hybrid System Architectures (2025-2026)

**1. Hybe - GPU-NPU Hybrid System**
- GPU for prefill stage
- Lightweight NPUs for decode stage
- **Results:**
  - 2.1x speedup for Phi-3 with 100K-token context window
  - 3.9x energy efficiency for Llama-3 with 1M-token context window
  - Compared to H100 GPUs with equal device count

**2. AMD Ryzen AI Hybrid Execution**
- NPU-only and Hybrid execution modes
- Utilizes both NPU and iGPU via ONNXRuntime GenAI (OGA)
- **Best performance of NPU for TTFT** (time-to-first-token)
- **iGPU for token generation** (TPS)
- Delivers exceptional performance for LLM inference

**3. llm.npu for Mobile**
- Maximizes execution on mobile NPU for integer operations
- Keeps necessary FP operations on CPU/GPU (no accuracy loss)
- Variable-length prompts reduced to multiple fixed-sized chunks
- Transformer blocks scheduled between CPU/GPU and NPU based on hardware affinity

### Practical Tools (2026)

**llama.cpp NPU Support:**
- Research prototype for Qualcomm Snapdragon SoCs
- Uses Hexagon NPU via llama.cpp fork
- Not production-ready

**Intel IPEX-LLM:**
- LLM acceleration library for Intel GPU, NPU, and CPU
- Supports running on Intel NPU via Python/C++ or llama.cpp API
- Production-ready for Intel hardware

### Attention Offload Techniques

**llama.cpp Best Practice:**
- `--merge-qkv` flag merges Q, K, and V attention tensors
- Provides performance improvement to token generation
- No penalty if attention layers offloaded to at least one GPU

**Trend for 2026:** Hybrid approaches that leverage NPUs for integer operations while offloading attention layers and FP operations to CPUs/GPUs for optimal performance.

**Sources:**
- [Hybe: GPU-NPU Hybrid System](https://dl.acm.org/doi/10.1145/3695053.3731051)
- [Fast On-device LLM Inference with NPUs](https://arxiv.org/html/2407.05858v2)
- [Intel IPEX-LLM](https://github.com/intel/ipex-llm)
- [Accelerate Fine-tuned LLMs Locally on NPU and iGPU](https://www.amd.com/en/developer/resources/technical-articles/accelerate-llms-locally-on-amd-ryzen-ai-npu-and-igpu.html)

---

## 8. Theoretical TOPS Calculation: NPU + CPU

### AMD XDNA 2 NPU

**Specification:**
- Up to **50 TOPS** (INT8/INT16)
- Optimized for inference workloads
- Power-efficient dedicated AI accelerator

### AMD Zen 5 CPU with AVX-512

**AVX-512 Architecture Improvements:**
- **Native 512-bit floating-point datapath** (doubled from Zen 4's 256-bit)
- Ryzen 9000 desktop and EPYC 9005 server: Full 512-bit datapath
- Ryzen AI 300 mobile: 256-bit datapath (power savings)
- **Note:** Strix Halo likely has 256-bit datapath for mobile form factor

**AI Inference Performance:**
- 35% and 32% IPC uplifts on Geekbench AES and machine learning subtests
- AVX-512 instructions dramatically accelerate AI inference
- Threadripper PRO 9000: 49% better than Intel for DeepSeek R1 32B context-based prompting

**TOPS Calculation for CPU:**

Base formula:
```
TOPS = (operations/cycle) × (clock frequency GHz) × 10^3
```

**For INT8 with AVX-512 (512-bit datapath):**
- 512 bits / 8 bits (INT8) = 64 INT8 values per vector
- With FMA (Fused Multiply-Add): 2 operations (multiply + add)
- Operations per cycle = 64 × 2 = 128 INT8 ops/cycle

**Example Calculation (Ryzen AI Max+ 395):**
- 16 cores, assumed base frequency ~3.0 GHz
- Per-core: 128 ops/cycle × 3.0 GHz = 384 GOPS = 0.384 TOPS
- All cores: 16 × 0.384 = **6.14 TOPS (theoretical peak INT8)**

**Important Caveats:**
1. **AVX-512 frequency throttling:** Zen 5 reduces clock when running AVX-512 workloads
2. **Actual vs. theoretical:** Real performance may be 50-70% of theoretical peak
3. **Memory bandwidth:** May become bottleneck before compute saturation
4. **256-bit datapath:** If mobile Strix Halo has 256-bit (like Ryzen AI 300), divide by 2

**Conservative Estimate:** **3-5 TOPS INT8** for sustained CPU inference on Strix Halo

### Combined NPU + CPU Performance

**Theoretical Combined TOPS:**
- NPU: 50 TOPS (dedicated, sustained)
- CPU: 3-5 TOPS (conservative, INT8 inference)
- **Total: 53-55 TOPS**

**Practical Considerations:**
- NPU and CPU can run in parallel (true heterogeneous compute)
- Unified shared memory (up to 128GB) enables efficient data sharing
- Bottleneck will likely be model partitioning efficiency, not raw compute
- When GPU ROCm support arrives, GPU will replace CPU for decode (much higher TOPS)

**Sources:**
- [AMD Zen 5 Raises IPC, Speeds up Math and AI Processing](https://xpu.pub/2024/07/16/amd-zen-5/)
- [Zen 5's AVX-512 Frequency Behavior](https://chipsandcheese.com/p/zen-5s-avx-512-frequency-behavior)
- [AMD Ryzen AI Max Processors 2026: Complete Architecture Guide](https://www.ofzenandcomputing.com/amd-ryzen-ai-max-mobile-processors/)

---

## 9. Practical Implementation Recommendations for WSL2

### Current State (GPU Blocked)

**Available:**
- NPU via Windows bridge (`npu_bridge_windows.py` at `C:\Users\fabia\projects\wsl\WSL\tools\strix-turbo\npu_client`)
- CPU with Zen 5 AVX-512 optimizations
- 128GB unified shared memory

**Blocked:**
- GPU ROCm compute (waiting for AMD driver with WSL2 gfx1151 passthrough support)

### Recommended Framework: ONNX Runtime GenAI

**Why ONNX Runtime GenAI:**
1. **Production-ready** hybrid NPU-CPU execution (as of 2026)
2. **AMD officially supports** Ryzen AI with pre-optimized models
3. **Automatic graph partitioning** between NPU and CPU
4. Compatible with OGA version 0.11.2
5. **Windows ML integration** for NPU bridge access

**Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│                      WINDOWS                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  ONNX Runtime + DirectML Execution Provider         │    │
│  │  - NPU EP for XDNA 2 (50 TOPS)                      │    │
│  │  - CPU EP fallback for unsupported ops              │    │
│  │  - TCP Bridge on port 9999                          │    │
│  └─────────────────────────────────────────────────────┘    │
│                           ▲                                  │
│                           │ JSON/TCP (existing bridge)       │
└───────────────────────────┼──────────────────────────────────┘
                            │
┌───────────────────────────┼──────────────────────────────────┐
│                      WSL2 │                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Application Layer (Python/C++)                     │    │
│  │  - strix_npu client (existing)                      │    │
│  │  - OGA-compatible API wrapper                       │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### Pre-optimized Models (Hugging Face)

AMD provides ready-to-use models:
- **Llama-3.2-3B-Instruct** (hybrid NPU+CPU/GPU)
- **Mistral-7B-Instruct** (hybrid variants)
- Available on Hugging Face with NPU quantization

### Implementation Steps

**1. Enhance NPU Bridge (Windows Side):**
```python
# Add OGA hybrid execution to npu_bridge_windows.py
import onnxruntime_genai as og

# Configure hybrid execution
options = og.GenAIOptions()
options.execution_provider = "DML"  # DirectML for NPU
options.hybrid_mode = True  # Enable CPU fallback
```

**2. Add OGA Wrapper (WSL2 Side):**
```python
# New: tools/strix-turbo/npu_client/python/strix_npu/oga_wrapper.py
from strix_npu import NPUClient

class OGAHybridClient:
    def __init__(self):
        self.client = NPUClient()

    def load_model(self, model_path, hybrid=True):
        """Load pre-optimized OGA model with hybrid execution"""
        return self.client.load_model(model_path,
                                      execution_mode="hybrid" if hybrid else "npu_only")

    def generate(self, prompt, max_tokens=100):
        """Run hybrid NPU (prefill) + CPU (decode) inference"""
        return self.client.infer(prompt, max_tokens=max_tokens)
```

**3. Test with Llama-3.2-3B:**
```python
from strix_npu.oga_wrapper import OGAHybridClient

client = OGAHybridClient()
client.load_model("amd/llama-3.2-3b-instruct-npu-hybrid")

response = client.generate("Explain quantum computing in simple terms")
print(response)
```

### When GPU Becomes Available

**Transition Strategy:**
1. Keep NPU for prefill (already optimized)
2. Switch decode from CPU to GPU (iGPU/gfx1151)
3. Update execution provider: `NPU (prefill) + GPU (decode)`
4. Expected gain: 5-10x decode performance over CPU

**ROCm Integration Path:**
```bash
# Future: Once AMD driver supports WSL2 gfx1151
./tools/strix-turbo/rocm/setup-rocm72.sh  # Already exists
# Update OGA bridge to use ROCm EP for decode
```

### Performance Expectations

**Current (NPU + CPU):**
- Prefill: ~50 TOPS on NPU (excellent)
- Decode: ~3-5 TOPS on CPU (acceptable)
- **TTFT (Time-to-First-Token):** ~200-500ms for 3B model
- **TPS (Tokens-Per-Second):** ~10-20 tokens/sec (CPU-limited)

**Future (NPU + GPU):**
- Prefill: ~50 TOPS on NPU (same)
- Decode: ~100+ TOPS on GPU (20x faster)
- **TTFT:** ~200-500ms (same)
- **TPS:** ~200+ tokens/sec (GPU-accelerated)

**Sources:**
- [OnnxRuntime GenAI (OGA) Flow](https://ryzenai.docs.amd.com/en/latest/hybrid_oga.html)
- [Hybrid NPU/iGPU Optimized Agent on AMD Ryzen AI](https://www.amd.com/en/developer/resources/technical-articles/2025/hybrid-npu-igpu-optimized-agent-on-amd-ryzen-ai-powered-pc-.html)
- [Model Pipelining on NPU and GPU using Ryzen™ AI Software](https://www.amd.com/en/developer/resources/technical-articles/model-pipelining-on-npu-and-gpu-using-ryzen-ai-software.html)

---

## 10. Alternative Approaches

### llama.cpp with CPU-Only (Current Fallback)

**If ONNX Runtime NPU bridge is complex:**
- Use llama.cpp with AVX-512 optimizations on Zen 5 CPU
- Build with ROCm backend (ready for when GPU support arrives)
- Existing setup at `tools/strix-turbo/rocm/setup-llamacpp.sh`

**Performance:**
- CPU-only: ~10-20 tokens/sec for 7B model (acceptable)
- Easy to transition to GPU when driver available

### Intel IPEX-LLM Approach (Cross-Platform Learnings)

While IPEX-LLM is Intel-specific, their architecture offers lessons:
- Seamless integration with llama.cpp, Ollama, HuggingFace
- Automatic NPU/CPU/GPU scheduling
- Could inspire AMD equivalent or cross-platform abstraction

### Parasitic Batching Enhancement

**Combine heterogeneous compute with existing Strix-Turbo tech:**
- Use NPU for inference while `parasitic_batch` optimizes I/O
- `tools/strix-turbo/parasitic_batch/` already does io_uring batching
- Parallel I/O optimization + NPU compute = multiplicative gains

---

## Summary Table: Framework Comparison

| Framework | NPU Support | CPU Support | GPU Support | WSL2 Ready | Production Status |
|-----------|-------------|-------------|-------------|-----------|-------------------|
| **ONNX Runtime GenAI** | ✅ AMD XDNA 2 | ✅ Hybrid | ✅ Future (iGPU) | ⚠️ Via bridge | ✅ Production (2026) |
| **llama.cpp** | ❌ AMD XDNA | ✅ AVX-512 | ⚠️ Future (ROCm) | ✅ Native | ✅ Production |
| **vLLM** | ❌ AMD XDNA | ✅ Basic | ⚠️ Future (ROCm) | ✅ Native | ✅ Production |
| **Intel IPEX-LLM** | ❌ Intel only | ✅ Intel | ✅ Intel Arc | ❌ Intel HW only | ✅ Production |
| **AMD Ryzen AI SDK** | ✅ XDNA 2 | ✅ Hybrid | ✅ iGPU | ❌ Windows only | ✅ Production |

**Recommendation:** Start with **ONNX Runtime GenAI** via NPU bridge for immediate NPU+CPU hybrid. Transition to llama.cpp+ROCm when GPU support arrives.

---

## Next Steps for Strix-Turbo Integration

### Phase 1: Enhance NPU Bridge (Week 1)
1. Update `tools/strix-turbo/npu_bridge_windows.py` with OGA hybrid support
2. Add DirectML execution provider configuration
3. Test with Llama-3.2-3B-Instruct pre-optimized model

### Phase 2: WSL2 OGA Wrapper (Week 2)
1. Create `tools/strix-turbo/npu_client/python/strix_npu/oga_wrapper.py`
2. Implement hybrid inference API (NPU prefill + CPU decode)
3. Add benchmarking tools for TTFT and TPS metrics

### Phase 3: Performance Validation (Week 3)
1. Benchmark NPU+CPU vs. CPU-only llama.cpp
2. Measure actual TOPS utilization (NPU: 50, CPU: 3-5)
3. Document performance for different model sizes (3B, 7B, 13B)

### Phase 4: GPU Readiness (Week 4)
1. Monitor AMD driver updates for WSL2 gfx1151 support
2. Prepare ROCm integration scripts (already have `setup-rocm72.sh`)
3. Create transition plan: NPU+CPU → NPU+GPU

### Phase 5: Documentation & Examples (Week 5)
1. Create `HETEROGENEOUS_INFERENCE_GUIDE.md`
2. Add example applications using OGA hybrid
3. Update `ARCHITECTURE_10X.md` with NPU+CPU findings

---

## Conclusion

**For AMD Strix Halo on WSL2 in 2026:**

1. **Use ONNX Runtime GenAI** for production-ready NPU+CPU hybrid inference
2. **NPU handles prefill** (50 TOPS, compute-intensive)
3. **CPU handles decode** (3-5 TOPS, acceptable until GPU available)
4. **Combined theoretical performance:** 53-55 TOPS
5. **When GPU arrives:** Switch to NPU (prefill) + GPU (decode) for 10x decode speedup

**Key Insight from Research:**
> Heterogeneous computing with specialized NPUs is the standard approach for AI workloads in 2026. The NPU provides 10-100x speedup over CPU, while intelligent workload distribution across NPU, CPU, and GPU maximizes both performance and power efficiency.

The existing Strix-Turbo NPU bridge infrastructure (`npu_client/`) provides an excellent foundation. Adding ONNX Runtime GenAI support will unlock production-ready hybrid inference today, with a clear path to GPU acceleration when drivers arrive.

---

## References

### AMD Official Documentation
- [AMD Ryzen™ AI Software](https://www.amd.com/en/developer/resources/ryzen-ai-software.html)
- [AMD XDNA™ Architecture](https://www.amd.com/en/technologies/xdna.html)
- [Model Pipelining on NPU and GPU using Ryzen™ AI Software](https://www.amd.com/en/developer/resources/technical-articles/model-pipelining-on-npu-and-gpu-using-ryzen-ai-software.html)
- [RAG with Hybrid LLM on AMD Ryzen AI Processors](https://www.amd.com/en/developer/resources/technical-articles/2025/rag-with-hybrid-llm-on-amd-ryzen-ai-processors.html)
- [Hybrid NPU/iGPU Optimized Agent on AMD Ryzen AI](https://www.amd.com/en/developer/resources/technical-articles/2025/hybrid-npu-igpu-optimized-agent-on-amd-ryzen-ai-powered-pc-.html)

### ONNX Runtime
- [ONNX Runtime Execution Providers](https://onnxruntime.ai/docs/execution-providers/)
- [Vitis AI Execution Provider - AMD](https://onnxruntime.ai/docs/execution-providers/Vitis-AI-ExecutionProvider.html)
- [OnnxRuntime GenAI (OGA) Flow](https://ryzenai.docs.amd.com/en/latest/hybrid_oga.html)

### Research Papers & Systems
- [Hybe: GPU-NPU Hybrid System for LLM Inference](https://dl.acm.org/doi/10.1145/3695053.3731051)
- [Fast On-device LLM Inference with NPUs](https://arxiv.org/html/2407.05858v2)
- [Scaling LLM Test-Time Compute with Mobile NPU](https://arxiv.org/html/2509.23324v1)

### Industry Comparisons
- [Qualcomm NPU and Heterogeneous Computing](https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Unlocking-on-device-generative-AI-with-an-NPU-and-heterogeneous-computing.pdf)
- [Intel IPEX-LLM](https://github.com/intel/ipex-llm)

### Community Tools
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [vLLM-Omni](https://github.com/vllm-project/vllm-omni)
- [AMD RyzenAI-SW GitHub](https://github.com/amd/RyzenAI-SW)

---

**Document Version:** 1.0
**Last Updated:** 2026-02-04
**Next Review:** When AMD releases WSL2 gfx1151 GPU support
