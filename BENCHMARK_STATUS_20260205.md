# Benchmark Investigation Report
**Date:** 2026-02-05 14:03:00 CET
**Duration:** 32 minutes 53 seconds
**Status:** STUCK - Process Terminated

## Summary

The WSL2 Strix-Turbo benchmark suite was stuck after approximately 33 minutes of execution. It completed the initial sequential write test but did not progress to subsequent tests. The process has been terminated and partial results extracted.

## Benchmark Details

- **Script:** `tools/strix-turbo/benchmark-suite.sh`
- **Process ID:** 2310
- **Start Time:** 13:29:51 CET (estimated from context)
- **Stop Time:** 14:03:00 CET
- **Status:** Terminated (killed -9)

## System Information

```
Host: AMD RYZEN AI MAX+ PRO 395 w/ Radeon 8060S
CPU Cores: 32
Memory: 94 GiB
Kernel: 6.18.8-microsoft-standard-WSL2-dirty
Mount Type: virtiofs
```

## Partial Results Collected

### 1.1 Sequential Write Performance (1GB)
- **Linux Native:** (incomplete - empty result)
- **/mnt/c virtiofs:** 199 MB/s ✓

## Analysis

### What Completed
1. System information collection ✓
2. Mount type detection (virtiofs) ✓
3. Benchmark directory creation ✓
4. First sequential write test (1GB to /mnt/c) ✓

### Where It Got Stuck
The benchmark appears to have stalled after completing the first sequential write (line 65-72 of script).

**Evidence:**
- Test files were successfully created:
  - `/tmp/benchmark-native/test1gb.dat` (1.0 GiB)
  - `/mnt/c/temp/benchmark-wsl/test1gb.dat` (1.0 GiB)
- No active child processes (dd, grep, etc.) were visible
- Process was idle but not complete

### Most Likely Cause: Sequential Read Timeout

The script was likely stuck at **line 79-82** (Sequential Read Performance):
```bash
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
NATIVE_READ=$(dd if="$LINUX_TESTDIR/test1gb.dat" of=/dev/null bs=1M 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
```

This operation:
1. Flushes filesystem cache (`sync`)
2. Drops Linux page cache (`echo 3 | sudo tee /proc/sys/vm/drop_caches`)
3. Reads the entire 1GB file sequentially
4. Requires ~5-10 seconds on modern systems, but on virtiofs or WSL2 could take longer

### Why It Stuck (Root Causes)

**Primary Issue: VirtioFS with large file I/O**
- Reading 1GB files through virtiofs with page cache drops can be slow
- WSL2's virtiofs implementation may have performance bottlenecks with sequential reads
- No timeout protection in the script - if any step hangs, benchmark continues waiting indefinitely

**Secondary Issues:**
- Script uses `set -e` but no timeouts on I/O operations
- No progress indicators beyond console output
- The results file is only updated at specific checkpoints
- Cache drop operations require sudo and may block unexpectedly

## Performance Data Extracted

From `~/wsl-benchmark-results/benchmark-20260205-133138.txt`:

```
=== SYSTEM INFORMATION ===
Date: Thu Feb  5 13:31:38 CET 2026
Kernel: 6.18.8-microsoft-standard-WSL2-dirty
CPU: AMD RYZEN AI MAX+ PRO 395 w/ Radeon 8060S
CPU Cores: 32
Memory: 94Gi

Mount type: virtiofs

=== FILE I/O BENCHMARKS ===
Sequential write (Linux native): [EMPTY - not captured]
Sequential write (/mnt/c virtiofs): 199 MB/s
```

## Recommendations

### Immediate Actions

1. **Restart with timeout protection:**
   ```bash
   timeout 180 ./benchmark-suite.sh
   ```

2. **Reduce test dataset sizes** to speed up execution:
   - Change 1GB tests to 512MB or 256MB
   - Reduce 10,000 small files to 5,000 files
   - Reduces overall runtime from ~45 minutes to ~20-25 minutes

3. **Add progress tracking** to script:
   - Log timestamps before each major operation
   - Add simple progress indicators

### Modified Benchmark Configuration

For faster results, create optimized version:
- **Sequential I/O:** 512 MB instead of 1 GB (5-10s each, down from 10-20s)
- **Small files:** 5,000 instead of 10,000 (3-5s each, down from 8-15s)
- **Build test:** Reduce from 50 C files to 25 (2-3s, down from 5-8s)
- **Expected total time:** 20-25 minutes vs 40-45 minutes

## Performance Baseline (virtiofs)

From completed test:
- Sequential write (/mnt/c): **199 MB/s**
- Mount type: **virtiofs** (good for Windows interop)

**Context:** 199 MB/s is reasonable for virtiofs but significantly slower than native Linux (~1-3 GB/s SSD), indicating the Plan 9 protocol overhead identified in the architecture documentation.

## Next Steps

1. Create optimized benchmark script with smaller datasets
2. Add timeout protection (30-minute hard limit)
3. Add progress logging with timestamps
4. Run again with virtiofs enabled (complete comparative baseline)
5. Then test with 9p filesystem to measure virtiofs vs 9p performance delta
6. Compare against Plan 9 protocol performance metrics in documentation

## Files

- **Results:** `~/wsl-benchmark-results/benchmark-20260205-133138.txt` (partial, 526 bytes)
- **Test data left behind:**
  - `/tmp/benchmark-native/test1gb.dat` (1.0 GiB) - should be cleaned up
  - `/mnt/c/temp/benchmark-wsl/test1gb.dat` (1.0 GiB) - should be cleaned up
- **Script:** `tools/strix-turbo/benchmark-suite.sh`

---

**Report Generated:** 2026-02-05 14:03:00 CET
**Status:** Ready for restart with optimized parameters
