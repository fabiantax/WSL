# Zen 5 Kernel Performance Benchmarking Guide

This guide explains how to establish a performance baseline and verify the improvements from the Zen 5 optimized kernel.

## Quick Start (Automated)

The easiest way is to use the automated workflow script:

```bash
cd tools/strix-turbo
./run-kernel-comparison.sh
```

This script will:
1. Detect your current kernel
2. Run appropriate benchmarks
3. Guide you through kernel switching
4. Compare results automatically

## Manual Process

### Step 1: Establish Baseline (Before Switching Kernels)

Run benchmarks on your current kernel:

```bash
cd tools/strix-turbo
./benchmark-zen5-kernel.sh baseline.json
```

This takes ~3-5 minutes and tests:
- **CPU Performance**: Parallel compilation, compression
- **Memory Bandwidth**: memcpy throughput
- **File I/O**: Sequential read/write, small file creation
- **System Performance**: Syscall overhead, context switching
- **Real-world Workflow**: Git operations, file searches

### Step 2: Switch to Optimized Kernel

Exit WSL and run in **PowerShell/CMD**:

```powershell
# Shutdown WSL completely
wsl --shutdown

# Restart WSL (will load new kernel from .wslconfig)
wsl
```

Verify the new kernel is loaded:

```bash
uname -r
# Should show: 6.8.12-g2192722c809b-dirty
```

### Step 3: Run Optimized Kernel Benchmarks

```bash
cd tools/strix-turbo
./benchmark-zen5-kernel.sh optimized.json
```

### Step 4: Compare Results

```bash
./compare-benchmarks.py baseline.json optimized.json
```

## What Gets Tested

### CPU Benchmarks
- **Parallel Compilation**: Compiles 100 C files with `make -j32` (tests multi-core scaling)
- **gzip Compression**: Single-threaded compression (tests IPC improvements)
- **pigz Compression**: Parallel compression (tests multi-core + memory bandwidth)

### Memory Benchmarks
- **Memory Bandwidth**: 512MB memcpy test (tests DDR5 + L3 cache improvements)

### I/O Benchmarks
- **Sequential Write**: 2GB write test with fsync (tests Plan9 protocol efficiency)
- **Sequential Read**: 2GB read test (tests caching and prefetch)
- **Small Files**: 1000 file creation (tests WSL2 syscall overhead)

### System Benchmarks
- **Syscall Overhead**: 1M getpid() calls (tests VM exit latency)
- **Context Switch**: 100K sched_yield() calls (tests scheduler performance)
- **Dev Workflow**: git init/commit/grep simulation (tests real-world usage)

## Expected Improvements

Based on Zen 5 optimizations, you should see:

| Benchmark | Expected Improvement |
|-----------|---------------------|
| Parallel Compilation | 25-35% faster |
| Memory Bandwidth | 15-25% higher |
| Sequential I/O | 10-20% faster |
| Syscall Overhead | 20-30% lower |
| Context Switch | 15-25% faster |

## Results Format

Results are saved in JSON format:

```json
{
  "timestamp": "2026-02-02T16:00:00+01:00",
  "kernel_version": "6.8.12-g2192722c809b-dirty",
  "cpu_model": "AMD Ryzen AI Max+ 395",
  "cpu_cores": 32,
  "total_ram": "96Gi",
  "benchmarks": {
    "cpu_parallel_compilation": {"value": 2.35, "unit": "seconds"},
    "memory_bandwidth": {"value": 42.5, "unit": "GB/s"},
    ...
  }
}
```

## Troubleshooting

### "jq: command not found"
```bash
sudo apt-get update
sudo apt-get install -y jq
```

### "pigz: command not found"
```bash
sudo apt-get install -y pigz
```

### Inconsistent Results
- Close other applications
- Run benchmarks multiple times and average
- Ensure WSL2 has allocated resources (check .wslconfig)
- Let system idle for 30 seconds before benchmarking

### High Variance in I/O Tests
This is normal for WSL2 due to:
- Windows antivirus scanning
- Plan9 protocol variability
- Host system load

Run 3 times and take the median result.

## Advanced: Custom Benchmarks

You can add your own workload-specific tests:

```bash
# Example: Test your actual build
cd ~/myproject
time make clean && time make -j32

# Example: Database performance
sysbench cpu run
sysbench memory run
```

Compare before/after manually or add to the benchmark script.

## Files

- `benchmark-zen5-kernel.sh` - Main benchmark suite
- `compare-benchmarks.py` - Results comparison tool
- `run-kernel-comparison.sh` - Automated workflow
- `benchmark-results/` - Results directory (auto-created)
  - `baseline.json` - Stock kernel results
  - `optimized.json` - Zen 5 kernel results

## Next Steps

After verifying performance improvements:

1. **Keep the optimized kernel**: Leave .wslconfig unchanged
2. **Document improvements**: Save comparison output for your records
3. **Test your workloads**: Run your actual development tasks and note improvements
4. **Report issues**: If performance regresses, check kernel logs: `dmesg | tail -100`

## Support

If you encounter issues or want to contribute additional benchmarks:
- Check logs: `dmesg`, `journalctl -xe`
- Review kernel config: `zcat /proc/config.gz | grep -i zen`
- Verify CPU features: `lscpu | grep -i Flags`
