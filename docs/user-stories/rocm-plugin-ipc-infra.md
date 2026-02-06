# User Stories: ROCm, Plugin Architecture, IPC Infrastructure, and Kernel/SIMD

**Project:** WSL2 Performance Optimization for AMD Strix Halo
**Date:** 2026-02-06
**Branch:** `claude/optimize-wsl2-performance-IZSfc`

---

## Epic 7: ROCm 7.2 Integration for AI Workloads

### US-ROCM-001: As an AI developer, I want automated ROCm 7.2 installation for gfx1151 so that I can run GPU-accelerated workloads from WSL2 when drivers are available
**Priority:** High | **Points:** 8

**Acceptance Criteria:**
- Script detects AMD GPU presence and gfx1151 architecture
- Installs ROCm 7.2 packages (rocm-dev, hip-runtime-amd, rocblas, rocm-smi-lib) from AMD apt repository
- Configures environment variables (ROCM_PATH, HIP_VISIBLE_DEVICES, HSA_OVERRIDE_GFX_VERSION)
- Validates installation with rocminfo and hipcc smoke test
- Documents that full gfx1151 passthrough requires unreleased Windows Adrenalin driver
- Script is idempotent and handles partial installations

**Files:** `tools/strix-turbo/rocm/setup-rocm72.sh`

---

### US-ROCM-002: As an AI developer, I want llama.cpp compiled with ROCm support so that I can run LLM inference on the integrated GPU
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script clones llama.cpp and builds with GGML_HIP=ON targeting gfx1151
- Configures HIP compiler flags for RDNA 3.5 architecture
- Downloads a test model (TinyLlama or similar) for validation
- Benchmark script measures tokens/second and reports results
- Documents current limitation: CPU fallback until GPU passthrough driver ships
- Build uses all available cores for parallel compilation

**Files:** `tools/strix-turbo/rocm/setup-llamacpp.sh`

---

### US-ROCM-003: As an AI developer, I want vLLM installed with ROCm backend so that I can serve LLM APIs from WSL2
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script installs vLLM with ROCm support from source or pip
- Configures PyTorch with ROCm backend
- Creates a test script that validates model loading and inference
- Documents memory requirements and recommended model sizes for 94GB system
- Provides systemd service file for persistent vLLM serving
- Handles dependency conflicts between ROCm and existing CUDA installations

**Files:** `tools/strix-turbo/rocm/setup-vllm.sh`

---

### US-ROCM-004: As a developer, I want ROCm documentation that covers the current state and roadmap so that I understand what works now vs what requires future driver updates
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Documents which ROCm features work on gfx1151 today (CPU fallback, build preparation)
- Explains the GPU passthrough dependency chain: Windows driver -> dxgkrnl -> /dev/dxg -> ROCm
- Lists expected timeline for official gfx1151 support (first half 2026)
- Covers the mainline kernel builder as a workaround for AMDGPU module support
- Includes architecture diagram showing the WSL2 GPU passthrough stack

**Files:** `tools/strix-turbo/rocm/README.md`

---

## Epic 8: Plugin Architecture for Upstream Compatibility

### US-PLG-001: As a WSL contributor, I want a capability-based plugin interface so that performance optimizations can be shipped without modifying core WSL source
**Priority:** Critical | **Points:** 13

**Acceptance Criteria:**
- Plugin host header defines lifecycle: `WslPluginInit`, `WslPluginCleanup`, `WslPluginGetCapabilities`
- Capability flags cover: compute offload, storage optimization, network acceleration, monitoring
- Plugin discovery scans a configurable directory for shared libraries matching naming convention
- Version negotiation ensures plugin API compatibility (major.minor.patch)
- Plugin isolation prevents a crashed plugin from taking down the host process
- CMake build system discovers and links plugins automatically

**Files:** `tools/strix-turbo/plugin-architecture/include/WslPluginHost.h`, `CMakeLists.txt`

---

### US-PLG-002: As a WSL contributor, I want a compute plugin interface so that GPU/NPU acceleration can be added as a pluggable module
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- `WslComputePlugin.h` defines: `SubmitWorkload`, `GetDeviceInfo`, `AllocateBuffer`, `FreeBuffer`
- Supports multiple device types (GPU, NPU, CPU) via device enumeration
- Workload descriptor includes: input buffers, output buffers, kernel name, grid dimensions
- Async completion via callback mechanism
- Error codes cover: device not found, out of memory, kernel compilation failed, timeout

**Files:** `tools/strix-turbo/plugin-architecture/include/WslComputePlugin.h`

---

### US-PLG-003: As a WSL contributor, I want a storage plugin interface so that filesystem optimizations can bypass the default I/O path
**Priority:** High | **Points:** 8

**Acceptance Criteria:**
- `WslStoragePlugin.h` defines POSIX-like operations: open, read, write, close, stat, readdir
- Path filtering allows plugins to claim specific mount points (e.g., /mnt/c only)
- Supports both synchronous and asynchronous I/O models
- Cache control interface allows plugins to manage their own caching strategy
- Metrics reporting for throughput, latency, and cache hit ratio
- Fallback to default I/O path if plugin rejects a path

**Files:** `tools/strix-turbo/plugin-architecture/include/WslStoragePlugin.h`

---

### US-PLG-004: As a WSL contributor, I want a capability negotiation system so that plugins declare what they provide and the host selects the best available implementation
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- `WslPluginCapabilities.h` defines capability flags as a bitmask
- Capabilities include: compute offload, storage optimization, network acceleration, monitoring, memory management
- Priority system allows multiple plugins to claim the same capability (highest priority wins)
- Runtime capability query allows applications to check available features
- Capability changes (plugin load/unload) trigger notification callbacks

**Files:** `tools/strix-turbo/plugin-architecture/include/WslPluginCapabilities.h`

---

### US-PLG-005: As a developer, I want example plugin implementations so that I can use them as templates for new plugins
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Scalar compute plugin demonstrates the compute interface with a simple matrix multiply
- SPDK storage plugin demonstrates the storage interface with an NVMe passthrough proof-of-concept
- Each plugin builds independently with CMake
- Each plugin includes inline documentation explaining the interface contract
- Build produces shared libraries that can be loaded by the plugin host

**Files:** `tools/strix-turbo/plugin-architecture/plugins/scalar-compute/`, `plugins/spdk-storage/`

---

### US-PLG-006: As a developer, I want plugin architecture documentation so that contributors understand the design rationale and extension points
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Design document covers: motivation (upstream compatibility), architecture (host/plugin boundary), interface contracts
- Comparison with Microsoft's existing WSL plugin API and how this extends it
- Migration path for integrating plugins into upstream WSL if accepted
- Security model for plugin sandboxing and resource limits

**Files:** `tools/strix-turbo/plugin-architecture/PLUGIN_ARCHITECTURE_DESIGN.md`, `README.md`

---

## Epic 9: IPC Lock-Free Ring Buffer

### US-IPC-001: As a systems developer, I want a lock-free SPSC ring buffer implementation so that the shared memory IPC can transfer data between producer and consumer without mutex overhead
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Ring buffer uses C11 atomics with acquire/release memory ordering
- Cache-line aligned (64 bytes) head and tail pointers prevent false sharing
- Supports variable-size messages up to `capacity - 1` bytes
- `spsc_write` returns bytes written, 0 if buffer full (non-blocking)
- `spsc_read` returns bytes read, 0 if buffer empty (non-blocking)
- Memory barrier correctness verified by inspection against C11 memory model

**Files:** `src/ipc/spsc_ring_buffer.c`, `src/ipc/spsc_ring_buffer.h`

---

### US-IPC-002: As a developer, I want comprehensive tests for the ring buffer so that correctness under concurrent access is verified
**Priority:** Critical | **Points:** 5

**Acceptance Criteria:**
- Tests cover: single-byte write/read, full-buffer write, empty-buffer read, wrap-around
- Concurrent producer-consumer test with configurable message count (default 100,000)
- Data integrity check: every byte written is verified on read
- Stress test with multiple message sizes (1B, 64B, 1KB, 64KB)
- Tests compile and run on Linux without external dependencies (pthreads only)

**Files:** `src/ipc/spsc_ring_buffer_test.c`

---

### US-IPC-003: As a developer, I want an example demonstrating the ring buffer in a WSL2 IPC scenario so that the intended usage pattern is clear
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Example shows producer (Linux side) and consumer (simulated Windows side) using the ring buffer
- Demonstrates message framing (length-prefixed messages)
- Shows the three-tier backoff pattern for the consumer (spin, yield, sleep)
- Includes performance measurement (messages/second, bytes/second)
- Compiles and runs as a standalone program

**Files:** `src/ipc/wsl2_ipc_example.c`

---

### US-IPC-004: As a developer, I want implementation verification for the ring buffer so that I can confirm the code matches the design document
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- Verification script checks: struct alignment (64-byte cache lines), atomic operation ordering, power-of-2 capacity enforcement
- Reports pass/fail for each design invariant
- Can be run as part of CI to catch regressions

**Files:** `src/ipc/verify_implementation.c`

---

### US-IPC-005: As a developer, I want IPC documentation that covers the design decisions and performance characteristics so that contributors understand the trade-offs
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Documents: why SPSC (single producer, single consumer), why lock-free, why cache-line alignment
- Performance characteristics: expected throughput (GB/s range on modern hardware), latency (sub-microsecond)
- Comparison with alternatives: mutex-based queue, mpsc ring, pipe-based IPC
- Integration guide for using the ring buffer in the shared memory IPC system
- Memory ordering explanation for the acquire/release pattern used

**Files:** `src/ipc/README.md`

---

## Epic 10: Kernel Builder, SIMD Utilities, and Architecture Components

### US-KRN-001: As a WSL2 developer on AMD Strix Halo, I want an automated mainline kernel builder that includes dxgkrnl patches so that I have a current kernel with GPU passthrough support
**Priority:** Critical | **Points:** 13

**Acceptance Criteria:**
- Script fetches latest mainline kernel (6.12+) source
- Auto-applies Microsoft dxgkrnl patches from community forks
- Applies 5+ compatibility patches for API changes between kernel versions
- Pre-flight compile check catches configuration errors before full build
- Zen 5 CPU optimizations enabled (CONFIG_MZEN5, AMD P-State, schedutil governor)
- All WSL2-critical configs enabled: VSOCK, Hyper-V, VirtIO, 9P, io_uring, VirtioFS
- AMDGPU module built but blacklisted until driver support ships
- Build uses all available cores and produces installable bzImage

**Files:** `tools/strix-turbo/build-mainline-wsl2-kernel.sh`

---

### US-KRN-002: As a developer, I want a Zen 5 optimized kernel builder based on the stock WSL2 kernel so that I get CPU optimizations without the risk of mainline kernel changes
**Priority:** High | **Points:** 8

**Acceptance Criteria:**
- Script patches the Microsoft WSL2 kernel with Zen 5 tuning flags
- Applies kernel config fragments for: CPU scheduler, memory management, I/O scheduler, network stack
- Enables io_uring with full feature set for async I/O
- Enables VirtioFS for improved filesystem transport
- Build time documented and under 30 minutes on the target system
- Kernel comparison benchmark script validates performance improvement

**Files:** `tools/strix-turbo/build-zen5-kernel.sh`, `tools/strix-turbo/kconfig-zen5.fragment`

---

### US-KRN-003: As a developer, I want SIMD-accelerated path utilities so that path canonicalization and comparison in the storage layer are vectorized
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- AVX2 path canonicalization: normalize separators, resolve `.` and `..` components
- SSE4.2 case-insensitive path comparison for Windows path matching
- Fallback scalar implementation for systems without AVX2/SSE4.2
- Runtime CPU feature detection selects the fastest available implementation
- Property-based tests verify SIMD and scalar implementations produce identical results
- Benchmark shows speedup factor vs scalar for representative path lengths

**Files:** `tools/strix-turbo/simd_path_utils.h`, `tools/strix-turbo/test_simd_path_utils.cpp`, `tools/strix-turbo/test_simd_properties.cpp`

---

### US-KRN-004: As a developer, I want a decoupled architecture design for the storage and compute layers so that components can be developed and tested independently
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Header defines interfaces for: FileSystem, ComputeEngine, NetworkTransport, ConfigProvider
- Each interface has a mock implementation for testing
- Dependency injection pattern allows swapping implementations at runtime
- GPU plane and NPU plane headers define the heterogeneous compute abstraction
- SPDK integration header provides the storage acceleration interface
- All headers compile independently without circular dependencies

**Files:** `tools/strix-turbo/decoupled_architecture.h`, `tools/strix-turbo/gpu_plane.h`, `tools/strix-turbo/npu_plane.h`, `tools/strix-turbo/spdk_integration.h`

---

### US-KRN-005: As a developer, I want a FUSE client that routes I/O through shared memory when available so that /mnt/c access bypasses the VirtioFS overhead
**Priority:** High | **Points:** 8

**Acceptance Criteria:**
- FUSE operations (read, write, open, close, stat, readdir) check for shared memory client first
- Falls back to direct syscalls if shared memory is unavailable
- Path translation from Linux mount point to Windows path (e.g., /mnt/c/foo -> C:\foo)
- Configurable mount point and shared memory region name
- Inode cache with TTL to reduce metadata round-trips
- Handles concurrent access from multiple threads safely

**Files:** `tools/strix-turbo/strix_fuse.cpp`

---

### US-KRN-006: As a developer, I want io_uring batch utilities so that the parasitic batch queue has a clean abstraction over the io_uring submission/completion rings
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Header provides: `UringBatch::submit_write`, `submit_read`, `submit_fsync`, `flush`, `wait_completions`
- Configurable ring depth (default 256 entries)
- Supports registered file descriptors for reduced kernel overhead
- Completion callback mechanism for async result delivery
- Property-based tests verify correctness under various submission patterns
- Benchmark measures throughput vs direct syscall baseline

**Files:** `tools/strix-turbo/uring_batch.h`, `tools/strix-turbo/uring_batch.cpp`, `tools/strix-turbo/uring_batch_test.cpp`, `tools/strix-turbo/test_uring_properties.cpp`

---

## Summary Table

| Epic | ID Range | Story Count | Total Points | Critical | High | Medium | Low |
|------|----------|-------------|--------------|----------|------|--------|-----|
| **7. ROCm 7.2 Integration** | US-ROCM-001 to 004 | 4 | 21 | 0 | 3 | 1 | 0 |
| **8. Plugin Architecture** | US-PLG-001 to 006 | 6 | 39 | 1 | 3 | 2 | 0 |
| **9. IPC Ring Buffer** | US-IPC-001 to 005 | 5 | 21 | 2 | 0 | 3 | 0 |
| **10. Kernel/SIMD/Arch** | US-KRN-001 to 006 | 6 | 44 | 1 | 3 | 3 | 0 |
| **TOTAL** | | **22** | **120** | **4** | **9** | **9** | **0** |
