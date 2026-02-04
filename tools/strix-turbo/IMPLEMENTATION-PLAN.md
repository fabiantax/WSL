# GPU Compute & Performance Implementation Plan

## Synthesized from TRIZ + Axiomatic Design + Specialist Agent Research
## Updated with prior art research (Feb 2026)

**Target**: AMD Strix Halo (Ryzen AI MAX+ PRO 395, Radeon 8060S gfx1151, XDNA NPU 50 TOPS)
**Current kernel**: 6.18.8-microsoft-standard-WSL2-dirty (dxgkrnl built-in, AMDGPU=module)
**Constraint**: AMD has NOT shipped GPU-P passthrough for gfx1151 in Adrenalin driver

---

## Prior Art Research (What Already Exists)

### Existing Solutions That Overlap With Our Plan

| Our Plan | Existing Solution | Overlap | Action |
|----------|-------------------|---------|--------|
| 1A. NPU bridge fixes | **AMD Ryzen AI 1.7 + OGA** (Jan 2026) | HIGH — hybrid NPU+iGPU execution, Python/C++ API, 61 TPS on Phi-3.5 | **Use Ryzen AI OGA as backend** instead of raw DirectML |
| 1B. Shared memory IPC | **virtio-fs** (in WSL 2.7.0 testing) | MEDIUM — Microsoft actively testing virtiofs, but no ship date | **Still build** — virtiofs targets filesystem, not compute IPC |
| 2A. Accelerator abstraction | **Windows ML** (GA Sept 2025) | HIGH — auto CPU/GPU/NPU dispatch with fallback | **Windows-only** — not available inside WSL2; still need our layer |
| 2A. Accelerator abstraction | **Google LiteRT** | LOW — supports Qualcomm/MediaTek NPUs, not AMD XDNA | Skip — wrong vendor |
| 2C. NPU+CPU pipeline | **Ryzen AI 1.7 hybrid mode** | VERY HIGH — already partitions prefill→NPU, decode→iGPU | **Don't rebuild** — expose via bridge instead |
| 3A. HIP-to-DirectML | Nothing found | NONE | Still novel (and still hard) |

### Key External Facts

1. **NPU is NOT passthrough to WSL2** — no `/dev/accel`, not in `lspci`. Our bridge is the ONLY way to access NPU/iGPU from WSL2.
2. **Windows ML** does auto-dispatch but is Windows-only runtime. Cannot call from Linux.
3. **Ryzen AI Software 1.7** (Jan 2026) has mature hybrid NPU+iGPU with OGA APIs, MoE model support, 16K context, Stable Diffusion built-in.
4. **virtio-fs** is being tested in WSL (commits in 2.7.0), but 9P drivers remain proprietary. No timeline for replacing 9P.
5. **DirectML is in maintenance mode** — Microsoft recommends Windows ML instead.
6. **HIP-to-DirectML translation**: No existing project. Community considers translation layers a "fool's errand" — native support is preferred.
7. **gfx1151 WSL2 GPU compute**: Still blocked. ROCm can't detect GPU in WSL2. AMD broader support changes expected H1 2026.
8. **Native Linux gfx1151**: Working with community PyTorch wheels, llama.cpp+rocWMMA, Docker images. gfx1100 kernels are 2-6x faster than gfx1151 kernels currently.

---

## Validated Findings (What We Know For Sure)

### Confirmed Dead Ends
1. **Native AMDGPU in WSL2**: No PCIe device exposed; modprobe hangs without firmware/device
2. **D3D12 compute via dxgkrnl**: ioctl returns -22 (EINVAL) for AMD GPUs; zero success reports
3. **Hyper-V DDA (discrete passthrough)**: Impossible for integrated GPUs; Win 11 Pro blocks it
4. **Nested virtualization with GPU**: No hypervisor supports GPU passthrough inside Hyper-V
5. **torch-directml**: Maintenance mode, 4x slower than ROCm, limited operator coverage
6. **Windows ML from WSL2**: Windows-only runtime, not exposed to Linux guests
7. **Google LiteRT for AMD XDNA**: Wrong vendor, no AMD NPU support

### Confirmed Working
1. **dxgkrnl /dev/dxg**: Present and active on 6.18.8 kernel (GPU-P plumbing works)
2. **NPU bridge (npu_bridge_windows.py)**: Functional but limited (64KB buffer, JSON, ONNX-only)
3. **Ryzen AI 1.7 OGA on Windows**: Hybrid NPU+iGPU, Python/C++ APIs, production-ready
4. **Windows ML on Windows**: Auto-dispatch CPU/GPU/NPU with EP management
5. **shared_memory_ipc.h/cpp**: Linux client implemented; Windows server half UNWRITTEN
6. **NPU (XDNA)**: 50+ TOPS available via Windows Ryzen AI stack
7. **VirtioFS for /mnt/c and /mnt/d**: Working via FUSE 7.38 compatibility patch (see below)

### The Core Problem
GPU compute (HIP/ROCm) from WSL2 is blocked by AMD's driver timeline. NPU is also not passthrough to WSL2. The **only** way to use accelerators from WSL2 is through a Windows-side bridge. The question is: **what's the thinnest bridge that gives us the most compute?**

---

## Revised Implementation Phases

### Phase 1: Bridge to Ryzen AI Stack (1-2 weeks)

#### 1A. Rebuild NPU Bridge on Ryzen AI 1.7 OGA ← REVISED
**Source**: TRIZ Principle 24 (Intermediary) + prior art (Ryzen AI 1.7)
**Feasibility**: HIGH | **Impact**: HIGH

**What changed**: Instead of fixing our raw DirectML bridge, rebuild it as a thin wrapper around AMD's Ryzen AI OGA APIs. This gives us hybrid NPU+iGPU execution for free — AMD already solved the hard problem of model partitioning.

**Architecture**:
```
WSL2 Linux                          Windows Host
┌──────────────┐    shared mem     ┌─────────────────────┐
│ strix_client │ ◄──────────────► │ strix_bridge_service │
│  (Python/C)  │    or HvSocket   │    (Python/C++)      │
└──────────────┘                   ├─────────────────────┤
                                   │ Ryzen AI 1.7 OGA    │
                                   │  ├─ Vitis AI EP (NPU)│
                                   │  ├─ DirectML EP (GPU)│
                                   │  └─ CPU EP (fallback)│
                                   └─────────────────────┘
```

**Key changes from original plan**:
- Replace raw `DmlExecutionProvider` with Ryzen AI OGA's hybrid execution
- Use OGA's model loading (supports quantized INT4/INT8/BF16 via AMD Quark)
- Use OGA's built-in NPU+iGPU partitioning instead of manual splitting
- Keep our bridge protocol but upgrade serialization (JSON → MessagePack)
- Increase buffer from 64KB → 16MB for tensor transfer

**Files to modify**:
- `tools/strix-turbo/npu_bridge_windows.py` → rewrite to wrap OGA
- `tools/strix-turbo/npu_client/client.py` → update protocol
- `tools/strix-turbo/npu_client/async_client.py` → update protocol

**New dependency**: AMD Ryzen AI Software 1.7 installed on Windows host

**Acceptance criteria**: Run Llama3.1 8B at >40 TPS from WSL2 via bridge, using hybrid NPU+iGPU.

#### 1B. Complete Shared Memory IPC (Windows Server) ← UNCHANGED
**Source**: TRIZ Principle 2 (Extraction) + AD FR1/FR2 decoupling
**Feasibility**: MEDIUM | **Impact**: HIGH
**Prior art note**: Microsoft is testing virtio-fs in WSL 2.7.0, but targets filesystem access not compute IPC. Our shared memory IPC serves a different purpose (low-latency tensor/command transfer for the bridge), so it remains valuable regardless of virtio-fs.

The Linux client (`shared_memory_ipc.cpp`) is complete. The Windows server is unwritten.

**Implementation**:
- Create `shared_memory_ipc_windows.cpp` implementing `SharedMemoryServer` class
- Use Windows named shared memory (`CreateFileMapping`/`MapViewOfFile`)
- Hyper-V socket or VMBus for signaling
- Handle all command types defined in the header

**Files to create**:
- `tools/strix-turbo/shared_memory_ipc_windows.cpp`
- `tools/strix-turbo/shared_memory_ipc_windows.h`

**Acceptance criteria**: Round-trip latency <1μs for metadata, >2GB/s for bulk data transfer.

#### 1C. Blacklist AMDGPU Module ← UNCHANGED
**Feasibility**: HIGH | **Impact**: LOW (prevents hangs)

```bash
echo "blacklist amdgpu" | sudo tee /etc/modprobe.d/blacklist-amdgpu.conf
sudo depmod -a
```

---

### Phase 2: WSL2 Accelerator Layer (2-4 weeks)

#### 2A. Thin Accelerator Abstraction for WSL2 ← REVISED
**Source**: TRIZ Principle 6 (Universality) + AD decoupled matrix
**Feasibility**: MEDIUM | **Impact**: HIGH
**Prior art note**: Windows ML does this on Windows. We need a WSL2-side equivalent that routes to our bridge. Keep it minimal — don't recreate Windows ML's EP management.

```
┌──────────────────────────────────────────┐
│     strix_compute (WSL2 Python/C)        │
│  compute.infer(model, input, hints)      │
├──────────┬──────────┬────────────────────┤
│ CPU      │ Bridge   │ Native GPU         │
│ OpenBLAS │ → Win ML │ → ROCm (future)    │
│ onnxrt   │ → OGA    │                    │
│ Local    │ HvSocket │ /dev/dxg           │
└──────────┴──────────┴────────────────────┘
```

**Design**: Thin dispatcher, not a framework. ~500 lines of Python.
- Probe available backends at startup
- Route to bridge if NPU/GPU needed
- Fall back to CPU ONNX Runtime for small models
- No EP management (that's Windows ML's / OGA's job on the other side)

**Files to create**:
- `tools/strix-turbo/accel/strix_compute.py` - Dispatcher (~500 LOC)
- `tools/strix-turbo/accel/backend_cpu.py` - Local ONNX Runtime CPU
- `tools/strix-turbo/accel/backend_bridge.py` - Wraps Phase 1A bridge client

#### 2B. GPU Readiness Scaffold with Hot-Switch ← UNCHANGED (still novel)
**Source**: TRIZ Principle 11 (Cushioning) + Principle 26 (Copying)
**Feasibility**: HIGH | **Impact**: MEDIUM

No existing solution found for this. Build the GPU path now so it activates automatically when AMD ships the driver:

1. **Detection daemon**: Polls `/dev/dxg` capabilities every 60s
2. **Capability cache**: Records what dxgkrnl exposes (adapters, compute queues)
3. **Hot-switch trigger**: When GPU adapter appears, migrate workloads from bridge→native
4. **Shadow execution**: Run small test kernels on GPU to validate before switching

**Files to create**:
- `tools/strix-turbo/accel/gpu_readiness.py` - Detection + hot-switch daemon
- `tools/strix-turbo/accel/gpu_probe.c` - Low-level dxgkrnl capability probe

#### ~~2C. NPU+CPU Pipeline~~ ← REMOVED (already exists)
**Reason**: AMD Ryzen AI 1.7 already implements optimal NPU+iGPU hybrid execution with automatic model partitioning. Phase 1A's bridge exposes this to WSL2. Building our own partitioning would be inferior to AMD's implementation.

---

### Phase 3: HIP-to-D3D12 Bridge (4-8 weeks, speculative) ← REVISED

#### 3A. HIP Kernel Bridge via Windows-side D3D12
**Source**: TRIZ Principle 2 (Extraction) + deep analysis
**Feasibility**: LOW | **Impact**: VERY HIGH (if it works)
**Prior art note**: No existing HIP-to-DirectML project found. Community considers translation layers impractical. DirectML is 2-4x slower than ROCm on same hardware. This phase should only proceed if AMD delays GPU-P beyond H2 2026.

```
WSL2 App → HIP call → libhip_intercept.so (LD_PRELOAD)
  → Serialize kernel + args
  → Shared memory IPC → Windows service
  → D3D12 compute dispatch → GPU hardware
  → Results back via shared memory
```

**Revised scope**: GEMM-only bridge for llama.cpp. Not a general HIP runtime.
- Intercept `hipblas*gemm*` calls only (~10 functions)
- Translate to D3D12 compute via AMD's metacommand intrinsics (wavemma)
- Accept 50-70% of native ROCm performance as success criteria

**Dependencies**: Phase 1B (shared memory IPC) must be complete.
**Go/no-go gate**: Only proceed if AMD hasn't shipped gfx1151 GPU-P by Phase 2 completion.

---

### Phase 4: Upstream & Monitor (Ongoing)

#### 4A. Monitor AMD Driver Releases
- Track Adrenalin driver releases for gfx1151 WSL2 support
- Expected: H1 2026 (per ROCm roadmap)
- When available: GPU readiness scaffold (2B) triggers automatic switch

#### 4B. VirtioFS Status ← RESOLVED
VirtioFS is now working on our custom kernel with these changes:
1. **FUSE 7.38 compatibility patch**: `FUSE_KERNEL_MINOR_VERSION` capped at 38 (matches WSL host server)
2. **fstab auto-mount**: Added `/etc/fstab` entries for `drvfsaC0` and `drvfsaD1`
3. **Build script updated**: `build-mainline-wsl2-kernel.sh` now auto-patches FUSE version

**Performance (without DAX)**:
| Metric | 9p (fd, 64KB msize) | VirtioFS (no DAX) | Notes |
|--------|---------------------|-------------------|-------|
| Write 100MB | 187 MB/s | 178-193 MB/s | Similar |
| Read 100MB | 252 MB/s | 191-206 MB/s | ~20% slower |
| Stat 1000 DLLs | 2.7s | 3.7-5.6s | Slower (FUSE per-op overhead) |

Without DAX cache, virtiofs performance is comparable to 9p. The drvfs shares show "No cache capability" while WSLg gets an 8GB DAX cache. DAX would provide memory-mapped zero-copy access and significant speedups. Monitoring Microsoft for drvfs DAX support.

**What's left**: Track WSL releases for drvfs DAX cache support (would give 2-8x improvement)

#### 4C. Upstream dxgkrnl Patches
- 5 compatibility patches for 6.18.8 → submit to Microsoft/WSL2-Linux-Kernel
- Benefits community, reduces our maintenance burden

#### 4D. ROCm Contributions
- File issues/PRs for gfx1151 support
- Test pre-release drivers when available

---

## Revised Priority Matrix

| Phase | Item | Feasibility | Impact | Prior Art | Priority |
|-------|------|-------------|--------|-----------|----------|
| 1C | Blacklist amdgpu | 10/10 | 2/10 | N/A | Do first |
| 1A | Rebuild bridge on OGA | 8/10 | 8/10 | Ryzen AI 1.7 (use it) | **64** |
| 1B | Shared memory IPC server | 6/10 | 9/10 | virtio-fs (different purpose) | **54** |
| 2A | Thin accelerator layer | 7/10 | 6/10 | Windows ML (Win-only) | **42** |
| 2B | GPU readiness scaffold | 8/10 | 5/10 | Nothing found | **40** |
| 3A | HIP GEMM bridge | 2/10 | 10/10 | Nothing found | **20** (gated) |

**Recommended execution order**: 1C → 1A → 1B → 2A → 2B → (gate) → 3A

**Removed**: Phase 2C (NPU+CPU pipeline) — AMD Ryzen AI 1.7 already does this better.

---

## What This Gives Us

### After Phase 1
- **Hybrid NPU+iGPU inference from WSL2**: 50+ TOPS via Ryzen AI OGA bridge
- **40+ TPS on Llama3.1 8B**: Using AMD's optimized model partitioning
- **Low-latency IPC**: 2GB/s tensor transfer via shared memory
- **No more hangs**: AMDGPU blacklisted

### After Phase 2
- **Unified compute API**: `strix_compute.infer()` — works today with bridge, tomorrow with native GPU
- **GPU-ready**: Automatic activation when AMD ships driver
- **Graceful degradation**: CPU fallback for small models, bridge for heavy inference

### When AMD Ships GPU-P Driver (H1-H2 2026)
- **Native ROCm/HIP**: Full GPU compute via dxgkrnl passthrough
- **GPU readiness scaffold**: Auto-detects and switches to native path
- **Zero code changes**: Apps using `strix_compute` API just get faster

---

## Risks and Mitigations

| Risk | Probability | Mitigation |
|------|-------------|------------|
| AMD delays gfx1151 GPU-P beyond H2 2026 | Medium | Phase 3 GEMM bridge; native Linux as escape hatch |
| Ryzen AI 1.7 OGA APIs change in 1.8 | Low | Pin version; OGA is Microsoft-backed, stable |
| Shared memory IPC Windows server is complex | Medium | Start with tensor transfer only; add filesystem later |
| virtio-fs ships and obsoletes our IPC | Low | Our IPC targets compute tensor transfer, not filesystem |
| Bridge latency too high for interactive use | Medium | Shared memory IPC replaces TCP; batch inference |
| Windows ML becomes available in WSL2 | Low | Good problem — replace our dispatcher with WinML |

---

## Eliminated Ideas (With Reasoning)

### Ruled Out by Specialist Agents
1. **Custom AMDGPU driver for WSL2**: dxgkrnl architecture incompatible with direct PCIe access
2. **Hyper-V DDA for iGPU**: Hardware/firmware restriction, not software-fixable
3. **torch-directml as primary path**: Maintenance mode, 4x slower, limited ops
4. **Nested VM with KVM+AMDGPU**: No GPU passthrough inside Hyper-V guest
5. **D3D12 compute via CLon12**: Enumeration fails at kernel level for AMD

### Ruled Out by Prior Art Research
6. **Build our own NPU+iGPU partitioning**: Ryzen AI 1.7 already does this optimally
7. **Build Windows ML equivalent**: Windows ML already exists; we just need a WSL2-side thin wrapper
8. **Full HIP runtime translation**: Community consensus: impractical; narrow GEMM-only bridge is feasible
9. **Google LiteRT for AMD**: Wrong vendor, no XDNA support
10. **Intel NPU Acceleration Library**: EOL, replaced by OpenVINO; Intel-only anyway

---

## References

- [AMD Ryzen AI Software 1.7](https://www.amd.com/en/developer/resources/technical-articles/2026/amd-ryzen-ai-software-1-7-release.html)
- [AMD Hybrid NPU/iGPU Agent](https://www.amd.com/en/developer/resources/technical-articles/2025/hybrid-npu-igpu-optimized-agent-on-amd-ryzen-ai-powered-pc-.html)
- [AMD Model Pipelining NPU+GPU](https://www.amd.com/en/developer/resources/technical-articles/2025/model-pipelining-on-npu-and-gpu-using-ryzen-ai-software.html)
- [Windows ML GA](https://blogs.windows.com/windowsdeveloper/2025/09/23/windows-ml-is-generally-available-empowering-developers-to-scale-local-ai-across-windows-devices/)
- [Windows ML Overview](https://learn.microsoft.com/en-us/windows/ai/new-windows-ml/overview)
- [WSL 2.7.0 Release (virtiofs testing)](https://github.com/microsoft/WSL/releases/tag/2.7.0)
- [WSL Open-Sourced (9P drivers still proprietary)](https://blogs.windows.com/windowsdeveloper/2025/05/19/the-windows-subsystem-for-linux-is-now-open-source/)
- [virtio-fs Project](https://virtio-fs.gitlab.io/)
- [gfx1151 Strix Halo LLM Tracker](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
- [DirectML (maintenance mode)](https://github.com/microsoft/DirectML)
- [Intel NPU Driver WSL2 Issue](https://github.com/intel/linux-npu-driver/issues/56)
- [Google LiteRT Acceleration](https://ai.google.dev/edge/litert/next/acceleration)
