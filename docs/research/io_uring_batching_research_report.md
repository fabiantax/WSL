# io_uring LD_PRELOAD Batching Research Report
**Research Date**: 2026-02-05
**Target Platform**: WSL2 / Hyper-V Virtualization
**Purpose**: Evaluate feasibility and best patterns for io_uring-based syscall batching via LD_PRELOAD

---

## Executive Summary

**Key Finding**: The Strix-Turbo `parasitic_batch` library approach has **fundamental architectural limitations** that prevent effective batching of synchronous I/O operations. While the library is well-implemented, the research reveals that:

1. **Synchronous read/write cannot be effectively batched** via LD_PRELOAD
2. **io_uring is designed to BYPASS LD_PRELOAD**, not work with it
3. **The "caller needs result immediately" problem is unsolvable** for synchronous operations
4. **Only async operations and write-behind caching can be batched** transparently

**Recommendation**: Pivot from LD_PRELOAD batching to:
- Shared memory IPC to bypass 9P protocol entirely
- Async I/O wrappers for applications that can be modified
- Write-behind caching for write operations only
- Focus on the root cause: 9P protocol overhead

---

## 1. The Fundamental Problem: Synchronous vs Asynchronous I/O

### 1.1 How io_uring Works

io_uring creates two shared memory ring buffers:
- **Submission Queue (SQ)**: Application submits I/O requests
- **Completion Queue (CQ)**: Kernel posts completion events

Applications can:
1. Queue multiple operations in the SQ
2. Submit them with a single `io_uring_enter()` syscall
3. Wait for completions in the CQ

**Performance Benefit**: 1000 operations → 1-2 syscalls instead of 1000 syscalls

### 1.2 The LD_PRELOAD Intercept Pattern

Traditional LD_PRELOAD intercepts synchronous libc calls:

```c
ssize_t read(int fd, void *buf, size_t count) {
    // Application EXPECTS result NOW
    // Cannot return until we have the data
}
```

**The Catch-22**:
- If we batch the operation, we need to wait for it to complete
- Waiting means calling `io_uring_enter()` or `io_uring_wait_cqe()`
- This is still **1 syscall per operation** (VM exit every time)
- **No batching benefit achieved**

### 1.3 Why io_uring Bypasses LD_PRELOAD

From research findings, applications using io_uring directly **bypass all libc wrappers**:

> "io_uring minimizes user-kernel transitions by batching operations through shared memory queues, issuing only a few essential syscalls (e.g., io_uring_enter, io_uring_setup) for coordination. The complete execution is handled via direct syscall preparation and completion queues, meaning no libc API (like open(), write(), or close()) is ever invoked."

**Implication**: io_uring is designed to be a **replacement** for synchronous I/O, not a transparent accelerator for it.

---

## 2. What CAN Be Batched via LD_PRELOAD

### 2.1 Write-Behind Caching (Viable)

**Pattern**: Buffer writes and flush lazily

```c
ssize_t write(int fd, const void *buf, size_t count) {
    // Copy data to internal buffer
    memcpy(write_buffer[fd], buf, count);

    // Queue io_uring write operation (don't wait)
    io_uring_prep_write(sqe, fd, write_buffer[fd], count, offset);

    // Return immediately (pretend write succeeded)
    return count;

    // Later: flush on fsync(), close(), or timeout
}
```

**Works Because**:
- Applications don't expect write() to guarantee persistence
- POSIX allows write-behind caching
- We only need to ensure flush on fsync()/close()

**Limitations**:
- Buffer memory overhead
- Data loss risk if process crashes before flush
- Complex error handling (errors surface later)

### 2.2 Async Operations (Viable for Specific Cases)

**Pattern**: Applications that can tolerate async behavior

```c
// Operations that can be deferred:
- close() - No return value needed
- fsync() - Can batch multiple fsyncs together
- Prefetch reads for sequential access patterns
```

**Works Because**:
- Some operations don't need immediate results
- Applications may not check return values
- Sequential patterns are predictable

### 2.3 What CANNOT Be Batched

**Synchronous reads**:
```c
ssize_t read(int fd, void *buf, size_t count) {
    // Application needs data in 'buf' RIGHT NOW
    // Cannot defer or batch
    // MUST wait for result
}
```

**Synchronous open**:
```c
int fd = open("file.txt", O_RDONLY);
// Application needs fd RIGHT NOW to use it
// Cannot defer
```

**stat operations**:
```c
struct stat sb;
stat("file.txt", &sb);
// Application needs sb.st_size RIGHT NOW
// Cannot defer
```

---

## 3. Research Findings: Real-World Implementations

### 3.1 io_uring Libraries (Not LD_PRELOAD)

Found multiple high-performance io_uring libraries:
- [tokio-rs/io-uring](https://github.com/tokio-rs/io-uring) - Rust async runtime
- [tokio-rs/tokio-uring](https://github.com/tokio-rs/tokio-uring) - io_uring-backed Tokio
- [bbeaupain/nio_uring](https://github.com/bbeaupain/nio_uring) - Java NIO with io_uring

**Key Observation**: All use **async programming models**, not transparent interception. Applications must be **rewritten** to use async I/O.

### 3.2 No LD_PRELOAD io_uring Batching Libraries Found

**Significant Finding**: Despite extensive search, found **ZERO** production libraries that transparently batch synchronous I/O via io_uring + LD_PRELOAD.

**This Suggests**:
1. It's technically infeasible
2. The performance benefit is negligible
3. The complexity isn't worth the effort

### 3.3 io_uring Security Concerns

From research:
> "Docker Desktop blocks io_uring in containers for security reasons starting with version 4.42.0. The reason is that io_uring can bypass seccomp-style syscall filtering, making it difficult to sandbox safely."

**Implication**: Even if batching worked, io_uring may be restricted in containerized environments.

---

## 4. Optimal io_uring Configuration

### 4.1 Ring Size

Research findings on batch sizes:

> "Small batches (e.g., size 8) keep latencies mostly below 25 µs, at the cost of slightly higher syscall frequency. However, batching can also increase latency variance, which is problematic for workloads requiring predictable response times."

> "Adaptive batching performance increases by about 18%, from 183k to 216k tx/s. Adjusting the batch size based on the ratio of outstanding I/Os to waiting fibers helps."

**Recommendations**:
- **Ring size**: 256-512 entries (balance memory vs capacity)
- **Batch size**: 32-64 operations (balance latency vs throughput)
- **Adaptive batching**: Flush early when few operations pending

### 4.2 SQPOLL Mode

> "When the SQPOLL flag is specified, a kernel thread is created to perform submission queue polling. In this mode, right after your program sets up polling mode, io_uring starts a special kernel thread that polls the shared submission queue."

**WSL2 Consideration**:
> "One user reported issues running io_uring with SQPOLL mode on Linux 5.15.153.1-microsoft-standard-WSL2. Additionally, io_uring support is not enabled by default in the kernel, you will need to compile a custom kernel with io_uring enabled."

**Recommendation**:
- **Avoid SQPOLL in WSL2** - May not work properly
- Use standard mode with manual submission
- Test thoroughly on WSL2 kernel before relying on it

### 4.3 Timeout-Based Flushing

> "io_uring supports passing in a minimum batch wait timeout through functions like `io_uring_submit_and_wait_min_timeout()`. The batch can be flushed either when it reaches a size threshold or a timeout expires—whichever comes first."

**Recommendation**:
- Timeout: 500-1000μs (balance latency vs batching)
- Size threshold: 32-64 operations
- Immediate flush on: fsync(), close(), read-after-write

---

## 5. WSL2 and Hyper-V Specific Considerations

### 5.1 VM Exit Overhead

Research on virtualization overhead:

> "VM exit events represent the primary source of overhead when running a virtual machine. APIC-access VM-exit is identified as a major performance bottleneck, with 139M cycles, or 90% of total virtualization overhead, being spent in APIC-access VM-exit for single VM cases."

> "When using the passthrough disk feature in Hyper-V, disk I/O overhead was found to range between 6 and 8%, with guest operating systems having available 92-94% of the disk I/O available to equivalent systems running on physical hardware."

**Key Finding**: Each syscall = VM exit = ~1000 cycles. This is why batching is attractive.

**However**: io_uring still requires syscalls for submission/completion, just fewer of them.

### 5.2 Plan 9 Protocol in WSL2

> "WSL2 uses a virtualization socket (VSOCK) communication channel to facilitate fast, efficient communication between the Windows host and Linux guest. WSL2 leverages the 9P protocol (originally from Plan 9) for file sharing between Windows and Linux."

> "The 9P protocol was chosen likely because it is very simple to implement."

**Critical Insight**: The **9P protocol is the real bottleneck**, not syscalls:

From `ARCHITECTURE_10X.md`:
> "The Plan 9 protocol (src/linux/plan9/) for /mnt/c access is the primary performance bottleneck (~100x slower than native)."

**This means**:
- io_uring batching of 9P operations still goes through 9P protocol
- Each batched read still needs a 9P Tread/Rread message round-trip
- **Batching syscalls doesn't fix the 9P overhead**

---

## 6. Analysis of Strix-Turbo parasitic_batch Implementation

### 6.1 Current Architecture

The library implements:
- LD_PRELOAD interception of read/write/open/close
- Thread-local batch queues
- io_uring backend with liburing
- Recursion guards and fallback mechanisms

### 6.2 Fundamental Issues

**Issue 1: Immediate Waits Required**

From `libparasitic_batch.c`:
```c
ssize_t read(int fd, void *buf, size_t count) {
    // Use batched read
    ssize_t result = strix_queue_read(fd, buf, count, true);
                                                          // ^^^^
                                                          // 'true' = wait for result
    return result;
}
```

Looking at the queue implementation, the `wait` parameter means:
- Submit operation to io_uring
- **Immediately call io_uring_wait_cqe()** to get result
- Return result to caller

**This is 1 syscall per operation - NO BATCHING BENEFIT**.

**Issue 2: Cannot Batch Reads**

Synchronous reads cannot be deferred:
```c
char buf[1024];
ssize_t n = read(fd, buf, sizeof(buf));
// Application needs data in buf RIGHT NOW
// Cannot defer this read
printf("Read %s\n", buf);  // Expects valid data
```

**Issue 3: 9P Protocol Overhead Remains**

Even if batching worked perfectly:
```c
// Batch 1000 reads via io_uring
io_uring_submit(&ring);  // 1 syscall

// But each read still goes through:
// 1. 9P Tread message (Linux → Windows)
// 2. VM exit
// 3. Windows ReadFile()
// 4. 9P Rread message (Windows → Linux)
// 5. VM exit
// 6. Copy data to buffer

// Result: Slightly fewer syscalls, but still 1000 × 9P round-trips
```

### 6.3 What Works in Current Implementation

**Write-Behind (Potentially)**:

If modified to not wait on writes:
```c
ssize_t write(int fd, const void *buf, size_t count) {
    // Queue write WITHOUT waiting
    strix_queue_write(fd, buf, count, false);  // Don't wait

    // Return immediately
    return count;
}
```

**This could work** because:
- POSIX allows write-behind
- No immediate result needed
- Can batch 1000 writes → 1 io_uring_submit()
- Still saves VM exits

**Limitations**:
- Data must be copied to persistent buffer
- Memory overhead
- Error handling complexity
- Crash safety concerns

---

## 7. Proven Patterns from Research

### 7.1 Synchronous-to-Async Bridge Pattern

From WebSocket implementation research:

> "A bridge layer that provides synchronous Read/Write traits while internally using async owned-buffer I/O is needed. Compio provides SyncStream in the compio-io::compat module specifically for interoperating with libraries that expect synchronous I/O traits. It's a clever structure that maintains internal buffers to bridge the async/sync boundary."

**Key Insight**: This pattern **requires** the application to be designed for it. Cannot be injected transparently.

### 7.2 Database Buffer Manager Pattern

> "io_uring can be leveraged to introduce batched write submission where instead of evicting and writing one page at a time, the buffer manager collects multiple victims and issues their writes together with a single io_uring_enter() call. While execution remains synchronous and reads and writes do not yet overlap, batching lowers submission overhead and exploits device-level parallelism."

**Application**: Database page evictions are naturally batchable because:
- Background operation
- No immediate result needed
- Can collect multiple dirty pages before flush

**Not Applicable** to general synchronous I/O.

---

## 8. Expected Realistic Performance Gains

### 8.1 Best Case (Write-Behind Only)

**If parasitic_batch is modified for write-behind only**:

```
Workload: Compiling code (many small writes)
- Without batching: 1000 writes = 1000 syscalls = 1000 VM exits
- With batching: 1000 writes = ~20 io_uring_submit() = 20 VM exits
- Gain: ~50x VM exit reduction

BUT: Still limited by:
- Memory copy overhead
- 9P protocol overhead (if writing to /mnt/c)
- Buffer management complexity

Realistic gain: 20-30% for write-heavy workloads on ext4
                5-10% for /mnt/c (9P bottleneck dominates)
```

### 8.2 Read Operations (Infeasible)

```
Workload: Reading many small files
- Without batching: 1000 reads = 1000 syscalls
- With batching: 1000 reads = 1000 waits = 1000 syscalls
- Gain: 0%

Reason: Synchronous reads cannot be deferred
```

### 8.3 Mixed Workloads (Marginal)

```
Workload: git status (reads metadata + .gitignore)
- Mostly stat() and read() operations
- stat() cannot be batched (synchronous)
- read() cannot be batched (synchronous)
- Only write() to index file can be batched

Realistic gain: 5-15% (only helps with index updates)
```

### 8.4 npm install (Marginal)

```
Workload: npm install (download + extract + write)
- Download: Network I/O (not helped by io_uring)
- Extract: tar reads (synchronous, cannot batch)
- Write: node_modules creation (can batch writes)

Realistic gain: 10-20% (only helps with file creation)
```

---

## 9. Alternative Approaches That WILL Work

### 9.1 Shared Memory IPC (Highest Priority)

**From ARCHITECTURE_10X.md**:

```
Current 9p Flow (per file read):
Total: ~20μs + 2 VM exits + 2 copies = SLOW

Shared Memory Flow:
1. Linux: Write offset to ring buffer    (~10ns)
2. Linux: Read directly from shared mmap (~10ns per KB, ZERO COPY)
Total: ~20ns = 1000x FASTER
```

**Implementation**: See `shared_memory_ipc.h` (already designed)

**Expected Gain**: 100-1000x for /mnt/c access

**Why This Works**:
- Bypasses 9P protocol entirely
- Zero-copy mmap access
- No VM exits for data transfer
- Addresses root cause, not symptoms

### 9.2 virtio-fs with DAX

**Pattern**: Replace 9P with virtio-fs

```
virtio-fs provides:
- Direct memory mapping (DAX)
- Zero-copy file access
- Cache coherency
- Better performance than 9P
```

**Expected Gain**: 50-100x for /mnt/c access

**Limitation**: Requires Windows host support (not yet available)

### 9.3 NVMe Passthrough with SPDK

**Pattern**: Bypass kernel storage stack entirely

```
Current: App → libc → syscall → VFS → ext4 → block → virtio-scsi → VHDX
SPDK:    App → SPDK → NVMe SSD

Expected Gain: 5-10x for random I/O, 2-3x sequential
```

**Implementation**: See `spdk_integration.h`

**Limitation**: Requires dedicated NVMe drive

---

## 10. Recommendations

### 10.1 For parasitic_batch Library

**Short Term**:
1. **Modify write operations to write-behind** (don't wait)
   - Expected gain: 20-30% for write-heavy workloads
   - Relatively low risk

2. **Remove read/open batching** (no benefit)
   - Eliminates complexity
   - Reduces maintenance burden

3. **Focus on close() and fsync() batching**
   - These can be deferred safely
   - Low-hanging fruit

4. **Add write-behind flush on**:
   - fsync() / fdatasync()
   - close()
   - Periodic timeout (500-1000μs)
   - Read-after-write (dependency tracking)

**Example Modified Implementation**:
```c
// Write buffer pool
static __thread char* write_buffers[MAX_FDS];

ssize_t write(int fd, const void *buf, size_t count) {
    // Allocate persistent buffer
    if (!write_buffers[fd]) {
        write_buffers[fd] = malloc(BUFFER_SIZE);
    }

    // Copy data (cannot reference user buffer after return)
    memcpy(write_buffers[fd], buf, count);

    // Queue write WITHOUT waiting
    io_uring_prep_write(sqe, fd, write_buffers[fd], count, offset);
    mark_dirty(fd);

    // Try to submit if queue is full
    if (queue_full()) {
        io_uring_submit(&ring);  // Don't wait for CQE
    }

    // Return immediately
    return count;
}

int fsync(int fd) {
    // Flush pending writes for this fd
    flush_pending_writes(fd);

    // Wait for completion
    io_uring_submit_and_wait(&ring);

    // Now do fsync
    io_uring_prep_fsync(sqe, fd);
    io_uring_submit_and_wait(&ring);

    return 0;
}
```

### 10.2 Strategic Priority Shift

**Stop**: Optimizing LD_PRELOAD batching (marginal gains)

**Start**: Implementing shared memory IPC (architectural fix)

**Priority Order** (from PRIORITIZATION.md):
1. ✅ .wslconfig optimizations (already done)
2. ✅ Git fsmonitor (already done)
3. ✅ Defender exclusions (already done)
4. ⚠️ **Parasitic batching** (reduce scope, write-only)
5. ⭐ **Shared Memory IPC** (move to Tier 1) ← **HIGHEST ROI**

### 10.3 Specific Actions This Week

1. **Modify parasitic_batch**:
   - Implement write-behind for write() only
   - Remove read/open batching attempts
   - Test with build workloads (gcc, cargo, npm)
   - Measure actual gains (expect 10-30%)

2. **Start Shared Memory IPC prototype**:
   - Implement Windows shared memory server
   - Implement Linux FUSE client
   - Benchmark vs 9P
   - Expected 100x gain for /mnt/c

3. **Document limitations**:
   - Update README with realistic expectations
   - Explain why read batching doesn't work
   - Provide guidance on when library helps

---

## 11. Conclusion

### Key Takeaways

1. **io_uring cannot transparently batch synchronous I/O operations** via LD_PRELOAD
   - Synchronous calls require immediate results
   - Waiting for results = 1 syscall per operation
   - No batching benefit achieved

2. **The 9P protocol is the real bottleneck**, not syscalls
   - io_uring batching doesn't fix 9P overhead
   - Need architectural change (shared memory IPC)

3. **Write-behind caching CAN work** with proper implementation
   - Copy data to persistent buffers
   - Defer submission, flush on fsync/close
   - Expected gain: 20-30% for write workloads

4. **No production libraries do transparent io_uring batching**
   - Strong signal that approach is infeasible
   - All high-performance io_uring uses async APIs

### Path Forward

**Immediate** (Week 1-2):
- Modify parasitic_batch for write-behind only
- Document realistic expectations (10-30% for writes)
- Remove ineffective read/open batching

**Short Term** (Week 3-6):
- Implement shared memory IPC (100-1000x for /mnt/c)
- Prototype virtio-fs integration
- Test NVMe passthrough

**Long Term** (Month 2-3):
- Full shared memory filesystem implementation
- NPU prefetching integration
- Upstream PRs to WSL2

### Success Metrics

**parasitic_batch** (conservative):
- 10-30% improvement for write-heavy workloads (gcc, cargo)
- 5-15% improvement for mixed workloads (git, npm)
- 0-5% improvement for read-heavy workloads (ls, find)

**Shared Memory IPC** (game-changer):
- 100-1000x improvement for /mnt/c access
- Near-native performance for Windows↔Linux file sharing
- Eliminates 9P bottleneck entirely

---

## 12. References

### Research Sources

**io_uring and LD_PRELOAD**:
- [breaking ld_preload rootkit hooks](https://matheuzsecurity.github.io/hacking/using-io-uring-to-break-linux-rootkits-hooks/)
- [io_uring basics: Writing a file to disk](https://notes.eatonphil.com/2023-10-19-write-file-to-disk-with-io_uring.html)
- [Stupid tricks with io_uring: a server that does zero syscalls per request](https://wjwh.eu/posts/2021-10-01-no-syscall-server-iouring.html)

**Batching Patterns**:
- [Building WebSocket Protocol using io_uring](https://iggy.apache.org/blogs/2025/11/17/websocket-io-uring/)
- [Comparing sequential I/O performance between io_uring and read/write](https://radiki.dev/posts/compare-sync-uring/)
- [Understanding Asynchronous I/O in Linux - io_uring](https://sumofbytes.com/blog/understanding-asynchronous-in-linux-io-uring/)

**SQPOLL and Performance**:
- [io_uring_setup(2) - Linux manual page](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html)
- [Submission Queue Polling](https://unixism.net/loti/tutorial/sq_poll.html)
- [io_uring not working on wsl2](https://github.com/microsoft/WSL/discussions/7021)

**Optimal Batching**:
- [io_uring for High-Performance DBMSs](https://arxiv.org/html/2512.04859v1)
- [Qdrant under the hood: io_uring](https://qdrant.tech/articles/io_uring/)
- [io_uring and networking in 2023](https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023)

**WSL2 and 9P Protocol**:
- [WSL2 Forensics: Detection, Analysis & Revirtualization](https://dl.acm.org/doi/fullHtml/10.1145/3538969.3544439)
- [Plan 9 rides again; WSL file access](https://nelsonslog.wordpress.com/2019/02/16/plan-9-rides-again-wsl-file-access/)
- [9P (protocol) - Wikipedia](https://en.wikipedia.org/wiki/9P_(protocol))

**Virtualization Performance**:
- [The Cost of Virtualization Exits](http://yshalabi.github.io/VMExits/)
- [Hyper-V storage I/O performance](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/storage-io-performance)
- [Hyper-V processor performance](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/processor-performance)

**GitHub Implementations**:
- [tokio-rs/io-uring](https://github.com/tokio-rs/io-uring)
- [tokio-rs/tokio-uring](https://github.com/tokio-rs/tokio-uring)
- [bbeaupain/nio_uring](https://github.com/bbeaupain/nio_uring)
- [espoal/awesome-iouring](https://github.com/espoal/awesome-iouring)

---

**Report Compiled By**: Research Agent (Claude Flow)
**For**: Strix-Turbo Performance Optimization Project
**Next Steps**: See Section 10.3 - Specific Actions This Week
