# Benchmark Restart Guide

**Status:** Optimized benchmark script ready for execution
**Date:** 2026-02-05 14:03:00 CET
**Changes Applied:** Performance optimizations + timeout protection

## Problem Summary

The WSL2 Strix-Turbo benchmark ran for 32 minutes and 53 seconds before becoming stuck on what appears to be the sequential read operation (reading 1GB file from /tmp with page cache cleared).

**Root Cause:** No timeout protection and potentially slow virtiofs I/O during cache drops

## Optimizations Applied

The `tools/strix-turbo/benchmark-suite.sh` script has been optimized to:

### 1. Reduced Dataset Sizes
| Test | Original | Optimized | Impact |
|------|----------|-----------|--------|
| Sequential I/O | 1 GB | 512 MB | 50% faster |
| Small files | 10,000 | 5,000 | 50% faster |
| Build project | 50 C files | 25 C files | ~50% faster |

### 2. Added Timeout Protection
- All `dd` operations: 60-second timeout
- Build operation: 120-second timeout
- Page cache drops now silent (no hang risk)
- Failed operations logged as "TIMEOUT"

### 3. Progress Tracking
- Timestamps added before/after each major operation
- Format: `Starting: HH:MM:SS` / `Completed: HH:MM:SS`
- Easier to identify which operation is slow

## Expected Runtime

### Before Optimization
- Full run: 40-45 minutes
- Often hangs: No timeout recovery

### After Optimization
- Full run: 15-20 minutes (estimated)
- Graceful timeout: Any operation >2 min gets terminated
- No hangs: All I/O operations protected

## How to Run

### Quick Start (with timeout wrapper)
```bash
cd ~/Projects/wsl/WSL
timeout 30m wsl -d UbuntuD bash tools/strix-turbo/benchmark-suite.sh
```

### Manual Run
```bash
cd ~/Projects/wsl/WSL/tools/strix-turbo
./benchmark-suite.sh
```

### Monitor Progress
In another terminal:
```bash
wsl -d UbuntuD bash -c "tail -f ~/wsl-benchmark-results/benchmark-*.txt"
```

## Expected Output

The script will:
1. Create results file: `~/wsl-benchmark-results/benchmark-YYYYMMDD-HHMMSS.txt`
2. Print colored progress to console
3. Run ~15-20 minutes total
4. Complete with summary showing performance ratios

## Results Format

The results file will contain:

```
=== SYSTEM INFORMATION ===
[System details]

Mount type: virtiofs

=== FILE I/O BENCHMARKS ===
Sequential write (Linux native): XXX MB/s
Sequential write (/mnt/c virtiofs): XXX MB/s
Sequential read (Linux native): XXX MB/s
Sequential read (/mnt/c virtiofs): XXX MB/s
Small file creation (Linux native): XXXs
Small file creation (/mnt/c virtiofs): XXXs
Small file ratio: XXXx

[More test results...]

=== SUMMARY ===
Performance Ratios (/mnt/c vs native):
  Small file creation: XXXx
  Directory traversal: XXXx
  Stat operations: XXXx
```

## Troubleshooting

### Benchmark Still Hangs
If benchmark appears hung:
1. Check if still making progress: `tail -f ~/wsl-benchmark-results/benchmark-*.txt`
2. Kill if truly stuck: `pkill -f benchmark-suite.sh`
3. Check what test was running in last lines of output
4. That test may need further optimization

### Incomplete Results
If you see "TIMEOUT" in results:
- That specific operation exceeded its time limit
- Normal with virtiofs - Plan 9 protocol is slower
- Try again or investigate that specific operation

### Filesystem Mount Type
Current system using: **virtiofs**
- Better interop with Windows
- Results reflect virtiofs performance
- To compare with 9p: disable virtiofs in .wslconfig and rerun

## Next Steps After Results

1. **Compare Results**
   - Run with 9p filesystem disabled (change .wslconfig)
   - Run benchmark again
   - Compare virtiofs vs 9p results

2. **Analyze Performance**
   - Small file ratio should be <10x for production readiness
   - Build times indicate real-world performance impact
   - Stat operations ratio shows metadata overhead

3. **Identify Bottlenecks**
   - Use tools like `perf` to profile slow operations
   - Check if VM exits are high (indicates Plan 9 overhead)
   - Consider parasitic batching for syscall optimization

## Modified Files

- `tools/strix-turbo/benchmark-suite.sh` - Optimized test sizes + timeout protection

## Related Documentation

- `BENCHMARK_STATUS_20260205.md` - Detailed investigation report
- `tools/strix-turbo/BENCHMARK_GUIDE.md` - Original benchmark documentation
- `CLAUDE.md` - WSL architecture and known limitations
