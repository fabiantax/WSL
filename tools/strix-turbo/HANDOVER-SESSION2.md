# Session Handover: Phase 1A + 1B Implementation

## Context

This continues from a session that completed:
- Custom WSL2 kernel 6.18.8 with dxgkrnl + Zen 5 optimizations
- VirtioFS fix (FUSE 7.38 compatibility patch) — /mnt/c and /mnt/d now mount via virtiofs
- Prior art research validating the implementation plan
- AMDGPU blacklist (no firmware/device exposed in WSL2)

## Current System State

- **Kernel**: 6.18.8-microsoft-standard-WSL2-dirty
- **Kernel source**: `/home/fabia/kernel-build-mainline/linux-mainline/`
- **VirtioFS**: Working for /mnt/c (drvfsaC0) and /mnt/d (drvfsaD1) via fstab
- **DAX**: NOT available for drvfs (host-side limitation, no .wslconfig option)
- **.wslconfig**: `C:\Users\fabia\.wslconfig` — 96GB RAM, 32 processors, virtiofs=true
- **WSL config**: `/etc/wsl.conf` — systemd=true, appendWindowsPath=false
- **AMDGPU**: Blacklisted (`/etc/modprobe.d/blacklist-amdgpu.conf`)
- **GPU status**: dxgkrnl /dev/dxg present, but AMD gfx1151 GPU-P not shipped in Adrenalin driver

## Task 1: Phase 1A — Rebuild NPU Bridge on Ryzen AI 1.7 OGA

### Goal
Rewrite `npu_bridge_windows.py` to wrap AMD Ryzen AI 1.7 OGA APIs instead of raw DirectML. Target: 40+ TPS on Llama3.1 8B from WSL2 via bridge.

### Current State of Bridge
- **Windows side**: `tools/strix-turbo/npu_bridge_windows.py` — functional but limited
  - Uses raw DirectML ONNX Runtime execution provider
  - 64KB buffer (too small for tensors)
  - JSON serialization (slow)
  - ONNX-only model support
- **Linux client**: `tools/strix-turbo/npu_client/` — Python package
  - `client.py` — synchronous client
  - `async_client.py` — async client
  - Uses TCP over HvSocket or localhost

### What Needs to Change

#### Windows Bridge (`npu_bridge_windows.py` → rewrite)
1. Replace `DmlExecutionProvider` with Ryzen AI OGA hybrid execution
2. Use OGA's model loading (INT4/INT8/BF16 via AMD Quark quantization)
3. Use OGA's built-in NPU+iGPU partitioning (don't manually split)
4. Upgrade serialization: JSON → MessagePack (msgpack-python)
5. Increase buffer: 64KB → 16MB for tensor transfer
6. New dependency: AMD Ryzen AI Software 1.7 installed on Windows host

#### Linux Client (`npu_client/`)
1. Update protocol to match new bridge (MessagePack, larger buffers)
2. Add streaming support for token-by-token generation
3. Keep HvSocket transport (fastest for VM↔host)

### Architecture
```
WSL2 Linux                          Windows Host
┌──────────────┐    HvSocket       ┌─────────────────────┐
│ strix_client │ ◄──────────────► │ strix_bridge_service │
│  (Python/C)  │    MessagePack   │    (Python/C++)      │
└──────────────┘                   ├─────────────────────┤
                                   │ Ryzen AI 1.7 OGA    │
                                   │  ├─ Vitis AI EP (NPU)│
                                   │  ├─ DirectML EP (GPU)│
                                   │  └─ CPU EP (fallback)│
                                   └─────────────────────┘
```

### Key References
- [AMD Ryzen AI Software 1.7](https://www.amd.com/en/developer/resources/technical-articles/2026/amd-ryzen-ai-software-1-7-release.html)
- [AMD Hybrid NPU/iGPU Agent](https://www.amd.com/en/developer/resources/technical-articles/2025/hybrid-npu-igpu-optimized-agent-on-amd-ryzen-ai-powered-pc-.html)
- [AMD Model Pipelining NPU+GPU](https://www.amd.com/en/developer/resources/technical-articles/2025/model-pipelining-on-npu-and-gpu-using-ryzen-ai-software.html)
- OGA API docs: Check `C:\Program Files\AMD\RyzenAI\` if installed

### Acceptance Criteria
- Run Llama3.1 8B at >40 TPS from WSL2 via bridge
- Hybrid NPU+iGPU execution (not CPU-only fallback)
- MessagePack serialization (not JSON)
- 16MB+ buffer for tensor transfer

---

## Task 2: Phase 1B — Complete Shared Memory IPC (Windows Server)

### Goal
Write the Windows server half of shared_memory_ipc for low-latency tensor transfer between WSL2 and Windows host. Target: <1μs latency for metadata, >2GB/s for bulk data.

### Current State
- **Linux client**: `tools/strix-turbo/shared_memory_ipc.h` + `shared_memory_ipc.cpp` — COMPLETE
- **Windows server**: NOT WRITTEN
- **Ring buffer**: `src/ipc/spsc_ring_buffer.c/h` — lock-free SPSC, cache-line aligned, C11 atomics

### What Needs to Be Created

#### `tools/strix-turbo/shared_memory_ipc_windows.cpp` + `.h`
1. `SharedMemoryServer` class implementing the server protocol
2. Use Windows named shared memory (`CreateFileMapping` / `MapViewOfFile`)
3. Hyper-V socket (AF_HYPERV) or VMBus for signaling
4. Handle all command types defined in `shared_memory_ipc.h`
5. Integrate with the NPU bridge (Phase 1A) as the transport layer

### Architecture
```
WSL2 (Linux)                    Windows Host
┌────────────────┐             ┌────────────────────┐
│ SharedMemory   │  shared     │ SharedMemoryServer  │
│ Client         │  memory     │                     │
│ (existing)     │ ◄────────► │ (TO BUILD)          │
├────────────────┤  region     ├────────────────────┤
│ SPSC Ring Buf  │             │ SPSC Ring Buf       │
│ (existing)     │             │ (reuse from src/ipc)│
└────────────────┘             └────────────────────┘
      ↕ HvSocket (signaling)          ↕
```

### Key Files to Read First
- `tools/strix-turbo/shared_memory_ipc.h` — Protocol definition, command types
- `tools/strix-turbo/shared_memory_ipc.cpp` — Linux client implementation
- `src/ipc/spsc_ring_buffer.c` — Lock-free ring buffer (reuse on Windows)
- `src/ipc/spsc_ring_buffer.h` — Ring buffer header

### Acceptance Criteria
- Round-trip latency <1μs for metadata commands
- Bulk data transfer >2GB/s
- Compatible with existing Linux client
- Integrates with Phase 1A bridge as transport upgrade

---

## Files Modified in This Session

### Kernel
- `/home/fabia/kernel-build-mainline/linux-mainline/include/uapi/linux/fuse.h` — FUSE_KERNEL_MINOR_VERSION 45→38

### WSL Config
- `C:\Users\fabia\.wslconfig` — Added `virtiofs=true`
- `/etc/fstab` — Added virtiofs mount entries for C: and D:
- `/etc/modprobe.d/blacklist-amdgpu.conf` — Created

### Repository (C:\Users\fabia\projects\wsl\WSL)
- `tools/strix-turbo/build-mainline-wsl2-kernel.sh` — Added `patch_fuse_version()` function
- `tools/strix-turbo/IMPLEMENTATION-PLAN.md` — Updated with prior art + virtiofs results
- `tools/strix-turbo/quick-wins/wslconfig-optimized.txt` — Added virtiofs config

### Key Documentation
- `tools/strix-turbo/IMPLEMENTATION-PLAN.md` — Full plan with phases, priority matrix
- `tools/strix-turbo/ARCHITECTURE_10X.md` — 10x performance architecture
- `tools/strix-turbo/PRIORITIZATION.md` — Performance work prioritization
- `CLAUDE.md` — Build instructions, architecture overview

## Confirmed Dead Ends (Don't Retry)
1. Native AMDGPU in WSL2 — no PCIe device exposed
2. D3D12 compute via dxgkrnl — ioctl returns EINVAL for AMD GPUs
3. Hyper-V DDA for iGPU — hardware restriction
4. torch-directml — maintenance mode, 4x slower
5. VirtioFS DAX for drvfs — host-side only, no .wslconfig option
6. virtio-9p transport — disabled by WSL service since 2.3.11
