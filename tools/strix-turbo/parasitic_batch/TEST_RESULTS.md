# Strix-Turbo Parasitic Batching Library - Test Results

**Test Date:** 2026-02-05
**Kernel Version:** 6.18.8-microsoft-standard-WSL2-dirty
**WSL Distribution:** UbuntuD
**Library Version:** Latest build (February 2026)

---

## Executive Summary

The Strix-Turbo parasitic batching library has been successfully tested with the following outcomes:

- **Build Status:** ✅ PASSED - Library built successfully (`libparasitic_batch.so`)
- **Unit Tests:** ✅ PASSED - All 8 tests passed (with and without batching)
- **Benchmarks:** ⚠️ MIXED RESULTS - Performance regression observed in synthetic tests
- **Real-World Tests:** ⚠️ NEUTRAL - Minimal difference in actual workloads
- **io_uring Support:** ✅ CONFIRMED - Kernel support enabled, library available

---

## 1. Build Status

### Library Files
```
libparasitic_batch.so    51,976 bytes   ✅ Built
test_parasitic           21,200 bytes   ✅ Built
bench_parasitic          21,072 bytes   ✅ Built
```

### Dependencies Verified
- liburing.so.2 ✅ Available
- liburing-ffi.so.2 ✅ Available
- io_uring kernel support ✅ CONFIG_IO_URING=y
- io_uring_disabled=0 ✅ Enabled

---

## 2. Unit Test Results

### Test Suite: Without Batching (Baseline)
```
========================================
  Strix-Turbo Parasitic Batch Tests
========================================
Batching: DISABLED (baseline)

TEST: basic write/read...          PASSED ✅
TEST: pread/pwrite...              PASSED ✅
TEST: multiple files...            PASSED ✅
TEST: large I/O...                 PASSED ✅
TEST: fsync/fdatasync...           PASSED ✅
TEST: error handling...            PASSED ✅
TEST: rapid open/close...          PASSED ✅
TEST: stdio passthrough...         PASSED ✅

Results: 8 passed, 0 failed
```

### Test Suite: With Batching (LD_PRELOAD)
```
========================================
  Strix-Turbo Parasitic Batch Tests
========================================
Batching: ENABLED

TEST: basic write/read...          PASSED ✅
TEST: pread/pwrite...              PASSED ✅
TEST: multiple files...            PASSED ✅
TEST: large I/O...                 PASSED ✅
TEST: fsync/fdatasync...           PASSED ✅
TEST: error handling...            PASSED ✅
TEST: rapid open/close...          PASSED ✅
TEST: stdio passthrough...         PASSED ✅

Results: 8 passed, 0 failed
```

### Batching Statistics (Debug Mode)
```
Final stats:
  ops_queued:        362
  ops_submitted:     362
  batches_submitted: 362
  sync_fallbacks:    0
  bytes_read:        0
  bytes_written:     65,825
```

**Analysis:** All functional tests pass. Library correctly intercepts syscalls and submits them via io_uring without errors.

---

## 3. Benchmark Results

### Small Writes (100 files × 4096 bytes × 10 iterations = ~3.9 MB)

| Metric | Without Batching | With Batching | Change |
|--------|------------------|---------------|--------|
| **Time** | 7.02 ms | 166.40 ms | **-23.7x slower** ⚠️ |
| **Throughput** | 556.31 MB/s | 23.48 MB/s | -95.8% |
| **Ops/sec** | 142,415 | 6,010 | -95.8% |

### Small Reads (100 files × 4096 bytes × 10 iterations)

| Metric | Without Batching | With Batching | Change |
|--------|------------------|---------------|--------|
| **Time** | 2.67 ms | 89.15 ms | **-33.4x slower** ⚠️ |
| **Throughput** | 1464.08 MB/s | 43.81 MB/s | -97.0% |
| **Ops/sec** | 374,804 | 11,216 | -97.0% |

### Large Sequential I/O (64 KB file = 6.25 MB)

| Operation | Without Batching | With Batching | Change |
|-----------|------------------|---------------|--------|
| **Write** | 2560.61 MB/s (2.44 ms) | 587.30 MB/s (10.64 ms) | **-4.4x slower** ⚠️ |
| **Read** | 8107.10 MB/s (0.77 ms) | 698.20 MB/s (8.95 ms) | **-11.6x slower** ⚠️ |

### Mixed Workload (1000 operations, git-like access pattern)

| Metric | Without Batching | With Batching | Change |
|--------|------------------|---------------|--------|
| **Time** | 2.75 ms | 85.68 ms | **-31.2x slower** ⚠️ |
| **Ops/sec** | 363,539 | 11,671 | -96.8% |

### Rapid Open/Close (10,000 metadata operations)

| Metric | Without Batching | With Batching | Change |
|--------|------------------|---------------|--------|
| **Time** | 20.95 ms | 33.15 ms | **-1.6x slower** ⚠️ |
| **Ops/sec** | 477,347 | 301,618 | -36.8% |

**Analysis:** Synthetic benchmarks show significant performance degradation. The library is completing individual operations one-by-one (batch size of 1) instead of batching multiple operations together.

---

## 4. Real-World Workload Tests

### Test A: Sequential Reads (200 files, ~4KB each)

| Configuration | Time | Result |
|---------------|------|--------|
| Without batching | 206ms | Baseline |
| With batching | 192ms | **6.8% faster** ✅ |

### Test B: Write Operations (200 files)

| Configuration | Time | Result |
|---------------|------|--------|
| Without batching | 2ms | Baseline |
| With batching | 3ms | **50% slower** ⚠️ |

### Test C: Directory Listing (ls -R /mnt/c/Windows/System32)

| Configuration | Time | Result |
|---------------|------|--------|
| Without batching | 59ms | Baseline |
| With batching | 58ms | **1.7% faster** (within margin of error) |

**Analysis:** Real-world tests show minimal to no performance improvement. The library is not effectively batching operations in practice.

---

## 5. Root Cause Analysis

### Issue: No Effective Batching

From debug output, the library shows:
```
[strix-batch] Submitted and completed batch of 1 operations
[strix-batch] Submitted and completed batch of 1 operations
[strix-batch] Submitted and completed batch of 1 operations
...
```

**Expected behavior:** Multiple operations should accumulate before submission:
```
[strix-batch] Submitted and completed batch of 64 operations  <- Expected
```

### Potential Root Causes

1. **Synchronous Syscall Pattern**: Applications making sequential syscalls with immediate results required prevent batching opportunities
2. **Flush Triggers Too Aggressive**: The 1000μs (1ms) timeout or buffer flush logic may be triggering prematurely
3. **Thread-Local Queue Isolation**: Each thread's queue operates independently, fragmenting batch opportunities
4. **Test Environment**: WSL2 Plan9 filesystem may have different characteristics than expected

### Configuration Used
```bash
STRIX_BATCH_ENABLE=1
STRIX_BATCH_SIZE=64         # Max batch size
STRIX_BATCH_TIMEOUT=1000    # 1ms flush timeout
STRIX_RING_ENTRIES=256      # io_uring queue size
STRIX_BATCH_SQPOLL=0        # SQPOLL disabled
```

---

## 6. VM Exit Reduction Analysis

### Expected: 50x VM Exit Reduction

Based on theoretical performance (1000 syscalls → 20 batches = 50x reduction)

### Observed: Minimal Reduction

Since operations are submitted in batches of 1, the VM exit reduction is effectively:
- **1000 syscalls → ~1000 batches = 1x (no reduction)**

**Measurement Note:** Direct VM exit counting requires kernel instrumentation or hypervisor-level tracing not available in standard WSL2. The performance degradation suggests overhead is exceeding any batching benefits.

---

## 7. Performance Overhead Analysis

### Sources of Overhead

1. **io_uring Submission Overhead**: Even single-operation batches incur queue management costs
2. **LD_PRELOAD Function Interception**: Additional function call overhead per syscall
3. **Thread-Local Storage Access**: Queue lookup on every intercepted call
4. **Synchronous Completion**: Immediate wait for results prevents async benefits
5. **Memory Copies**: Potential extra copies through io_uring buffers

### Overhead Estimate

For single-operation "batches":
- Direct syscall: ~1000 CPU cycles (VM exit)
- Batched via io_uring: ~1000 cycles (VM exit) + ~500 cycles (queue overhead) = 1500 cycles

**Result:** 50% overhead per operation when batch size = 1

---

## 8. Recommendations

### Short-Term Fixes

1. **Increase Batch Timeout**: Extend `STRIX_BATCH_TIMEOUT` from 1ms to 10-50ms to allow more accumulation
   ```bash
   STRIX_BATCH_TIMEOUT=50000  # 50ms
   ```

2. **Adjust Batch Size**: Lower threshold for flushing
   ```bash
   STRIX_BATCH_SIZE=16  # Flush at 16 instead of 64
   ```

3. **Enable SQPOLL Mode**: Reduce syscall overhead for submissions
   ```bash
   STRIX_BATCH_SQPOLL=1
   ```

4. **Profile Hot Paths**: Identify why batches aren't accumulating
   ```bash
   STRIX_BATCH_DEBUG=1  # Full debug logging
   ```

### Medium-Term Improvements

1. **Async-First Design**: Modify library to return immediately and complete async
2. **Cross-Thread Batching**: Aggregate operations across all threads before submission
3. **Operation Coalescing**: Merge adjacent reads/writes to same file
4. **Selective Interception**: Only intercept high-volume syscalls, skip others

### Long-Term Architecture

1. **Kernel Integration**: Direct Plan9 driver integration with io_uring (avoid LD_PRELOAD)
2. **Shared Memory IPC**: Bypass Plan9 protocol entirely for /mnt/c
3. **VirtioFS with io_uring**: Leverage native VirtioFS batching capabilities

---

## 9. Expected vs. Actual Performance

### Claimed Performance (from README.md)

| Workload | Expected Improvement |
|----------|---------------------|
| Many small files | 5-10x faster |
| git status (large repo) | 6x faster (30s → 5s) |
| npm install | 3x faster (120s → 40s) |
| Sequential I/O | 1.5-2x faster |

### Actual Performance (this test)

| Workload | Measured Result |
|----------|----------------|
| Many small files | **0.04x** (23x slower) ⚠️ |
| Sequential I/O | **0.08-0.09x** (11x slower) ⚠️ |
| Real-world reads | **1.07x** (7% faster) ✅ |
| Real-world writes | **0.67x** (33% slower) ⚠️ |

### Gap Analysis

The library does not currently achieve its performance targets. The issue is not with io_uring itself (which works correctly), but with the batching logic failing to accumulate operations before submission.

---

## 10. Conclusions

### Functional Correctness: ✅ PASS

- Library builds successfully
- All unit tests pass
- io_uring integration works correctly
- No data corruption or errors

### Performance Claims: ❌ FAIL

- Expected 5-50x improvement: **Observed 0.04-1.07x (regression to neutral)**
- Batching not occurring in practice (batch size = 1)
- Overhead exceeds benefits for current implementation

### Readiness Assessment

**Status:** Not production-ready for WSL2 performance optimization

**Blockers:**
1. Batch accumulation logic not functioning as designed
2. Performance regression under most workloads
3. Requires tuning, profiling, and architectural fixes

### Next Steps

1. **Debug batch accumulation**: Understand why operations aren't queuing
2. **Profile with real workloads**: Test with git, npm, docker to see actual patterns
3. **Implement fixes**: Apply recommendations from Section 8
4. **Re-benchmark**: Validate improvements achieve target performance
5. **Consider alternatives**: Evaluate direct Plan9 driver modification or VirtioFS optimization

---

## Appendix A: Test Environment

```
OS: Windows 11 (WSL2)
Kernel: 6.18.8-microsoft-standard-WSL2-dirty
Distribution: UbuntuD
CPU: [Not specified]
Memory: [Not specified]
Filesystem: Plan9 (/mnt/c)

Kernel Config:
  CONFIG_IO_URING=y
  CONFIG_IO_URING_ZCRX=y
  io_uring_disabled=0

Libraries:
  liburing.so.2: /lib/x86_64-linux-gnu/liburing.so.2
  liburing-ffi.so.2: /lib/x86_64-linux-gnu/liburing-ffi.so.2
```

---

## Appendix B: Raw Test Output

### Benchmark Output (Abbreviated)

```
=== Benchmark WITHOUT batching ===
Small Writes: 556.31 MB/s (142415 ops/sec)
Small Reads:  1464.08 MB/s (374804 ops/sec)
Large Write:  2560.61 MB/s
Large Read:   8107.10 MB/s
Mixed:        363539 ops/sec
Open/Close:   477347 ops/sec

=== Benchmark WITH batching ===
Small Writes: 23.48 MB/s (6010 ops/sec)      [-95.8%]
Small Reads:  43.81 MB/s (11216 ops/sec)     [-97.0%]
Large Write:  587.30 MB/s                     [-77.1%]
Large Read:   698.20 MB/s                     [-91.4%]
Mixed:        11671 ops/sec                   [-96.8%]
Open/Close:   301618 ops/sec                  [-36.8%]
```

---

## Appendix C: Debug Output Sample

```
[strix-batch] Configuration:
  enabled: yes
  batch_size: 64
  batch_timeout: 1000 us
  ring_entries: 256
  use_sqpoll: no

[strix-batch] Created io_uring context: entries=256, sqpoll=no
[strix-batch] Created batch queue for thread 136626667411264

[strix-batch] Submitted and completed batch of 1 operations  <- Issue: size=1
[strix-batch] Submitted and completed batch of 1 operations
[strix-batch] Submitted and completed batch of 1 operations
... (repeated 362 times)

[strix-batch] Final stats:
  ops_queued:        362
  ops_submitted:     362
  batches_submitted: 362      <- Should be ~6 (362/64)
  sync_fallbacks:    0
  bytes_written:     65,825
```

---

## Report Metadata

- **Generated By:** Claude Code (Strix-Turbo Test Suite)
- **Report Version:** 1.0
- **Test Duration:** ~5 minutes
- **Test Automation:** Semi-automated (manual analysis)
- **Confidence Level:** High (multiple test runs, consistent results)

---

**End of Report**
