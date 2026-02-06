# User Stories — Strix Halo WSL2 Performance Suite

## Epic: WSL2 Performance Optimization for AMD Strix Halo

### US-1: VirtioFS Filesystem Transport
**As a** WSL2 developer on Strix Halo,
**I want** /mnt/c and /mnt/d mounted via virtiofs instead of 9p,
**So that** I get lower-overhead filesystem access to Windows drives.

**Acceptance Criteria:**
- [x] Custom kernel patched to FUSE 7.38 for WSL host compatibility
- [x] Build script auto-patches FUSE version during kernel build
- [x] /etc/fstab entries auto-mount drives as virtiofs at boot
- [x] .wslconfig documents virtiofs=true requirement
- [ ] DAX cache for drvfs shares (blocked: requires Microsoft host-side change)

**Technical Notes:**
- Mainline 6.18 uses FUSE 7.45; WSL host server only supports 7.38
- Without DAX, virtiofs performance is comparable to 9p (~180 MB/s write, ~200 MB/s read)
- DAX would provide 2-8x improvement but requires `VIRTIO_FS_FLAGS_TYPE_SECTIONS` on host

---

### US-2: Mainline Kernel with GPU Passthrough
**As a** WSL2 developer on Strix Halo,
**I want** a mainline 6.18+ kernel with dxgkrnl GPU passthrough and Zen 5 optimizations,
**So that** I'm ready for AMD gfx1151 GPU-P when the driver ships.

**Acceptance Criteria:**
- [x] Build script fetches mainline kernel + community dxgkrnl patches
- [x] Auto-applies 5 compat patches (6.6→6.18 API changes)
- [x] Pre-flight compile checks catch errors before full build
- [x] Zen 5 CPU optimizations (CONFIG_MZEN5, AMD P-State, schedutil)
- [x] All WSL2 critical configs (VSOCK, Hyper-V, VirtIO, 9P, io_uring)
- [x] AMDGPU module built (blacklisted until driver ships)

---

### US-3: NPU Bridge via Ryzen AI OGA
**As a** WSL2 developer on Strix Halo,
**I want** to run LLM inference from WSL2 using the NPU and iGPU,
**So that** I can leverage all 50+ TOPS of accelerator compute from Linux.

**Acceptance Criteria:**
- [ ] Windows bridge wraps Ryzen AI 1.7 OGA APIs (hybrid NPU+iGPU)
- [ ] MessagePack serialization (replace JSON)
- [ ] 16MB+ buffer for tensor transfer (replace 64KB)
- [ ] Llama3.1 8B at >40 TPS from WSL2
- [ ] Streaming token generation support

---

### US-4: Shared Memory IPC
**As a** WSL2 developer on Strix Halo,
**I want** low-latency shared memory transport between WSL2 and Windows,
**So that** the NPU bridge can transfer tensors at >2GB/s.

**Acceptance Criteria:**
- [x] Linux client (shared_memory_ipc.cpp) — complete
- [x] Lock-free SPSC ring buffer (spsc_ring_buffer.c) — complete
- [ ] Windows server (shared_memory_ipc_windows.cpp) — TO BUILD
- [ ] Round-trip latency <1μs for metadata
- [ ] Bulk data transfer >2GB/s

---

### US-5: Accelerator Abstraction Layer
**As a** WSL2 developer on Strix Halo,
**I want** a single API (`strix_compute.infer()`) that routes to the best available backend,
**So that** my code works today via bridge and tomorrow via native GPU.

**Acceptance Criteria:**
- [ ] Thin Python dispatcher (~500 LOC)
- [ ] CPU backend (local ONNX Runtime)
- [ ] Bridge backend (wraps Phase 1A client)
- [ ] GPU backend stub (activates when AMD ships driver)
- [ ] Auto-detection of available backends at startup

---

### US-6: Quick-Win Performance Scripts
**As a** WSL2 developer on Strix Halo,
**I want** one-command scripts to apply all known performance optimizations,
**So that** I don't have to manually configure each setting.

**Acceptance Criteria:**
- [x] Optimized .wslconfig template with virtiofs
- [x] Defender exclusion script for WSL paths
- [x] Git performance optimizations (fsmonitor, manyFiles)
- [x] I/O optimizations (ext4 tuning, tmpfs for /tmp)
- [x] Bash performance settings
