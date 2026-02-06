# User Stories: Shared Memory IPC for WSL2

## Epic: Bypass Plan 9 Protocol for 10-1000x Faster /mnt/c Access

### US-SHM-001: As a developer, I want file reads from /mnt/c to bypass the 9p protocol so that my build tools run at near-native speed
**Priority:** Critical | **Points:** 13

**Acceptance Criteria:**
- Windows server processes Read commands via shared memory ring buffer
- Linux client submits read requests with file handle and offset
- Data is transferred through shared memory region (zero-copy from server perspective)
- Reads complete in <10us for cached files (vs ~1ms over 9p)
- Fallback to direct syscalls if shared memory is unavailable

**Implementation:** `shared_memory_ipc_win.cpp:handle_read()`, `shared_memory_ipc.cpp:pread()`

---

### US-SHM-002: As a developer, I want file writes to /mnt/c to be served through shared memory so that `git commit` and `npm install` are significantly faster
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Client copies write data into shared memory data region
- Server reads from data region and writes to Windows filesystem via WriteFile
- Positioned writes (pwrite) supported via file_offset field
- Sequential writes track position automatically
- Cache invalidation on write in FUSE layer

**Implementation:** `shared_memory_ipc_win.cpp:handle_write()`, `shared_memory_ipc.cpp:pwrite()`

---

### US-SHM-003: As a developer, I want `ls` and `find` on /mnt/c to be fast so that tab completion and file searches don't lag
**Priority:** High | **Points:** 8

**Acceptance Criteria:**
- stat() returns FileMetadata (size, timestamps, mode, inode) via shared memory
- readdir() returns DirEntry array packed into data region
- Windows server translates Win32 file attributes to Unix mode bits
- Directory entries include type (DT_DIR=4, DT_REG=8)
- Metadata cache in FUSE layer reduces repeat lookups (5s TTL)

**Implementation:** `shared_memory_ipc_win.cpp:handle_stat()`, `handle_readdir()`

---

### US-SHM-004: As a developer, I want the IPC system to handle file creation, deletion, and renaming so that full git workflows work on /mnt/c
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- open() with CREAT flag creates new files via CreateFileW
- unlink() deletes files via DeleteFileW
- mkdir()/rmdir() create/remove directories
- rename() moves files with MOVEFILE_REPLACE_EXISTING
- All operations translate /mnt/c paths to \\?\C:\ Windows paths

**Implementation:** `shared_memory_ipc_win.cpp` (Mkdir/Rmdir/Unlink/Rename cases in process())

---

### US-SHM-005: As a developer, I want the shared memory transport to gracefully fall back to direct syscalls when the Windows server isn't running
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- FUSE layer attempts to connect to shared memory on startup
- If mapping fails or control block is invalid, falls back to direct syscalls
- If server doesn't respond within 10s timeout, falls back
- User sees warning message in stderr, not a crash
- All FUSE operations work in both modes (shared memory and fallback)

**Implementation:** `strix_fuse.cpp:StrixShmClient::initialize()`, `fallback_` flag

---

### US-SHM-006: As a developer, I want the protocol to support positioned I/O so that database files and binary formats work correctly on /mnt/c
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- CommandEntry has 8-byte file_offset field for pread/pwrite
- UINT64_MAX sentinel means "use current file position"
- Server uses SetFilePointerEx on Windows, pread/pwrite on Linux test
- Client tracks per-handle position for sequential read()/write()
- Large files (>4GB) supported via 64-bit offsets

**Implementation:** CommandEntry.file_offset, `shared_memory_ipc.cpp:pread()/pwrite()`

---

### US-SHM-007: As a developer, I want a standalone Windows server executable so that I can run the shared memory IPC service independently
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- `shm_server.exe` creates named shared memory region
- CLI flags: `--name` (default: StrixWSL), `--size` (default: 64MB)
- Graceful shutdown on Ctrl+C (SIGINT handler)
- Prints stats on exit: commands processed, bytes transferred, cache hits
- Waits for Linux client to connect before processing

**Implementation:** `shm_server_main.cpp`

---

### US-SHM-008: As a developer, I want the data region to use a slab allocator so that memory doesn't fragment under sustained load
**Priority:** Medium | **Points:** 8

**Acceptance Criteria:**
- Power-of-2 slab sizes: 256B, 1KB, 4KB, 64KB, 256KB, 1MB
- Lock-free allocation via atomic CAS on free-list heads
- Lock-free deallocation pushes blocks back to slab free lists
- Bump allocator fallback for oversized (>1MB) allocations
- Memory divided among slabs by weighted usage (4KB and 64KB get largest share)

**Implementation:** `shared_memory_ipc.h:DataAllocator`

---

### US-SHM-009: As a developer, I want event signaling to reduce CPU usage when idle so that the shared memory IPC doesn't waste power
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- ControlBlock has atomic cmd_event and rsp_event counters
- Client increments cmd_event after every command submission
- Server checks cmd_event to avoid spinning when idle
- Response waiter checks rsp_event before sleeping
- Three-tier server backoff: spin (100 iters) -> 50us sleep -> 1ms sleep

**Implementation:** ControlBlock.cmd_event/rsp_event, server `run()` backoff loop

---

### US-SHM-010: As a developer, I want a comprehensive test harness so that I can validate the IPC protocol without a full Windows+WSL2 setup
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- In-process test runs entirely on Linux using memfd_create
- Server thread uses POSIX APIs to simulate Windows server
- 8 correctness tests: ping, mkdir/rmdir, open/write/read/close, stat, readdir, large read (1MB), rename, concurrent ops (50 rapid stats)
- 3 latency benchmarks: open+close, 4KB read, stat (1000 iterations each)
- Clean temp directory and report pass/fail count on exit

**Implementation:** `shm_test.cpp`

---

## Summary

| Priority | Stories | Total Points |
|----------|---------|-------------|
| Critical | 2 | 21 |
| High | 4 | 23 |
| Medium | 4 | 19 |
| **Total** | **10** | **63** |
