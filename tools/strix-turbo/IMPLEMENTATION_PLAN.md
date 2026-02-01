# Implementation Plan: Strix-Turbo Remaining Components

## Definition of Ready (DoR)

A component is **READY** when it meets ALL of the following criteria:

### Functional Requirements
- [ ] Compiles without errors on target platform
- [ ] All public APIs have implementations (not just declarations)
- [ ] Fallback path exists for unsupported hardware
- [ ] Error handling for all failure modes
- [ ] No hardcoded paths or magic numbers

### Testing Requirements
- [ ] Unit tests exist and pass
- [ ] Integration test with at least one real use case
- [ ] Performance benchmark vs baseline
- [ ] Memory leak check (valgrind/ASan)

### Documentation Requirements
- [ ] Header comments explain purpose and usage
- [ ] Example code demonstrating typical use
- [ ] Build instructions in README
- [ ] Known limitations documented

### Deployment Requirements
- [ ] Build script includes component
- [ ] Install script deploys component
- [ ] Uninstall/rollback path exists
- [ ] Version compatibility documented

---

## Components to Implement

### 1. LD_PRELOAD Parasitic Batching Library

**Purpose:** Intercept libc I/O calls and batch them via io_uring transparently.

**Definition of Ready:**
| Requirement | Status | Notes |
|-------------|--------|-------|
| Intercepts: open, read, write, close, stat, fstat, lstat | ❌ | Core functionality |
| Uses io_uring for batching | ❌ | Requires liburing |
| Thread-safe batch queues | ❌ | Per-thread batching |
| Configurable batch size/timeout | ❌ | Via env vars |
| Fallback to direct syscalls | ❌ | If io_uring unavailable |
| Unit tests | ❌ | Mock filesystem |
| Benchmark vs unbatched | ❌ | fio comparison |

**Files to Create:**
```
tools/strix-turbo/parasitic_batch/
├── libparasitic_batch.c      # Main LD_PRELOAD library
├── batch_queue.c             # Thread-local batch management
├── batch_queue.h
├── uring_backend.c           # io_uring submission
├── uring_backend.h
├── config.c                  # Environment variable config
├── config.h
├── Makefile
├── test_parasitic.c          # Unit tests
└── README.md
```

**Missing Information Needed:**
- [ ] Exact libc function signatures to intercept
- [ ] io_uring SQE format for each operation
- [ ] Thread-local storage best practices for LD_PRELOAD
- [ ] WSL2-specific io_uring limitations (if any)

---

### 2. NPU Client for WSL2

**Purpose:** Python/C library to communicate with Windows NPU bridge from WSL2.

**Definition of Ready:**
| Requirement | Status | Notes |
|-------------|--------|-------|
| TCP connection to Windows bridge | ❌ | localhost:9999 |
| JSON protocol for commands | ❌ | Matches bridge API |
| Async inference support | ❌ | Non-blocking calls |
| Connection pooling | ❌ | Reuse connections |
| Auto-reconnect on failure | ❌ | Resilience |
| Python package installable | ❌ | pip install . |
| C library for native apps | ❌ | libstrix_npu.so |
| Unit tests | ❌ | Mock server |

**Files to Create:**
```
tools/strix-turbo/npu_client/
├── python/
│   ├── strix_npu/__init__.py
│   ├── strix_npu/client.py       # Main client class
│   ├── strix_npu/async_client.py # Async version
│   ├── setup.py
│   └── tests/test_client.py
├── c/
│   ├── strix_npu.h
│   ├── strix_npu.c
│   ├── Makefile
│   └── test_npu.c
└── README.md
```

**Missing Information Needed:**
- [ ] Full JSON protocol spec (all commands/responses)
- [ ] Optimal batch size for inference requests
- [ ] Timeout values for different operations
- [ ] Error codes from Windows bridge

---

### 3. io_uring Batch Implementation (uring_batch.cpp)

**Purpose:** Implement the interfaces defined in uring_batch.h

**Definition of Ready:**
| Requirement | Status | Notes |
|-------------|--------|-------|
| UringContext initialization | ❌ | Ring setup |
| BatchBuilder all methods | ❌ | read/write/open/close/etc |
| Completion processing | ❌ | CQE handling |
| File/buffer registration | ❌ | Zero-copy optimization |
| SQPOLL mode support | ❌ | Kernel-side polling |
| Statistics collection | ❌ | For monitoring |
| Unit tests | ❌ | All operations |
| Benchmark | ❌ | vs sync I/O |

**Files to Create:**
```
tools/strix-turbo/
├── uring_batch.cpp           # Implementation
├── uring_batch_test.cpp      # Unit tests
└── uring_batch_bench.cpp     # Benchmarks
```

**Missing Information Needed:**
- [ ] liburing version requirements
- [ ] Kernel version requirements for each feature
- [ ] WSL2 kernel io_uring feature support matrix
- [ ] Best practices for error handling in io_uring

---

### 4. Shared Memory IPC Implementation (shared_memory_ipc.cpp)

**Purpose:** Implement Windows↔WSL2 shared memory communication.

**Definition of Ready:**
| Requirement | Status | Notes |
|-------------|--------|-------|
| Ring buffer implementation | ❌ | Lock-free SPSC |
| Command serialization | ❌ | Binary protocol |
| Response handling | ❌ | Async completion |
| Memory mapping | ❌ | /dev/shm on Linux |
| Windows server component | ❌ | CreateFileMapping |
| Synchronization primitives | ❌ | Futex/Event |
| Unit tests | ❌ | Both sides |
| Benchmark vs 9p | ❌ | Latency comparison |

**Files to Create:**
```
tools/strix-turbo/
├── shared_memory_ipc.cpp           # Linux client
├── shared_memory_ipc_win.cpp       # Windows server
├── ring_buffer.h                   # Lock-free ring
├── ring_buffer.cpp
├── shm_protocol.h                  # Wire format
├── test_shared_memory.cpp
└── bench_vs_9p.cpp
```

**Missing Information Needed:**
- [ ] How WSL2 exposes Windows shared memory to Linux
- [ ] Hyper-V shared memory mechanism details
- [ ] Best lock-free ring buffer algorithm for this use case
- [ ] 9p baseline performance numbers for comparison

---

## Implementation Order

Based on RICE prioritization:

```
Phase 1 (Highest Impact, Lowest Risk)
├── 1. LD_PRELOAD Parasitic Batching    [3 days]
│      └── Reason: Works with existing io_uring, no new deps
│
└── 2. NPU Client for WSL2              [1 day]
       └── Reason: Bridge already done, just client needed

Phase 2 (Foundation for Phase 3)
├── 3. uring_batch.cpp                  [2 days]
│      └── Reason: Required by parasitic batching
│
└── 4. Ring buffer implementation       [1 day]
       └── Reason: Required by shared memory IPC

Phase 3 (Advanced)
└── 5. shared_memory_ipc.cpp            [3 days]
       └── Reason: Depends on ring buffer, needs Windows side
```

---

## Information Gathering Tasks

Launch agents to gather missing information:

### Agent 1: io_uring in WSL2
- What io_uring features are supported in WSL2 kernel?
- Any known limitations or bugs?
- Recommended liburing version?

### Agent 2: LD_PRELOAD Best Practices
- How to intercept libc functions safely?
- Thread-local storage in LD_PRELOAD?
- Avoiding recursion when intercepted functions call other intercepted functions?

### Agent 3: WSL2 Shared Memory
- How does /dev/shm work in WSL2?
- Can Windows and WSL2 share memory directly?
- What's the mechanism (Hyper-V, virtio)?

### Agent 4: Lock-free Ring Buffers
- Best SPSC ring buffer implementation?
- Memory ordering requirements?
- Cache line alignment considerations?

---

## Success Criteria

| Milestone | Criteria | Target Date |
|-----------|----------|-------------|
| Phase 1 Complete | LD_PRELOAD + NPU client working | +4 days |
| Phase 2 Complete | uring_batch + ring buffer working | +7 days |
| Phase 3 Complete | Full shared memory IPC working | +10 days |
| All Tests Pass | 100% unit test coverage | +12 days |
| Benchmarks Complete | Performance data collected | +14 days |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| io_uring not fully supported in WSL2 | Fallback to libaio or sync I/O |
| Shared memory not accessible cross-VM | Use TCP/Unix socket fallback |
| LD_PRELOAD breaks specific apps | Allowlist/blocklist mechanism |
| Performance worse than expected | Profile and optimize hot paths |

