# WSL2 Performance Benchmarking Guide

## Overview

This guide helps you validate the performance improvements claimed in the Strix-Turbo suite by comparing:
- **Baseline** (9p/drvfs) vs **Optimized** (VirtioFS)
- **Stock kernel** vs **Zen 5 optimized kernel**
- **Standard syscalls** vs **io_uring batching**

## Quick Start

### 1. Run Baseline Benchmark (9p/drvfs)

```bash
# First, ensure virtiofs is DISABLED
# Edit C:\Users\<Username>\.wslconfig:
[wsl2]
virtiofs=false

# Restart WSL
wsl --shutdown

# Run benchmark
cd tools/strix-turbo
chmod +x benchmark-suite.sh
./benchmark-suite.sh
```

Results saved to: `~/wsl-benchmark-results/benchmark-TIMESTAMP.txt`

### 2. Run Optimized Benchmark (VirtioFS)

```bash
# Enable virtiofs
# Edit C:\Users\<Username>\.wslconfig:
[wsl2]
virtiofs=true

# Restart WSL
wsl --shutdown

# Run benchmark again
./benchmark-suite.sh
```

### 3. Compare Results

```bash
# Compare the two result files
diff -y ~/wsl-benchmark-results/benchmark-<baseline>.txt \
        ~/wsl-benchmark-results/benchmark-<optimized>.txt
```

## Comprehensive Testing Strategy

### Test Matrix

| Configuration | Filesystem | Kernel | Syscall Batching | Test |
|---------------|------------|--------|------------------|------|
| Baseline | 9p/drvfs | Stock | No | ✅ |
| Optimized FS | VirtioFS | Stock | No | ✅ |
| Optimized Kernel | 9p/drvfs | Zen 5 | No | ✅ |
| Full Optimization | VirtioFS | Zen 5 | Yes | ✅ |

### Configuration Matrix Script

```bash
#!/bin/bash
# Run all configuration combinations

RESULTS_DIR="$HOME/wsl-benchmark-matrix"
mkdir -p "$RESULTS_DIR"

echo "Running benchmark matrix..."
echo "This will take approximately 30-40 minutes"
echo ""

# You'll need to manually switch kernels between runs
# But we can automate the virtiofs switching

# 1. Baseline: 9p + stock kernel
echo "=== Test 1: Baseline (9p/drvfs) ==="
# Manually ensure stock kernel in .wslconfig
read -p "Ensure stock kernel is configured. Press enter to continue..."
./benchmark-suite.sh
mv ~/wsl-benchmark-results/benchmark-*.txt "$RESULTS_DIR/01-baseline-9p-stock.txt"

# 2. VirtioFS + stock kernel
echo "=== Test 2: VirtioFS + Stock Kernel ==="
# Enable virtiofs
read -p "Enable virtiofs in .wslconfig. Press enter to continue..."
wsl.exe --shutdown
sleep 5
./benchmark-suite.sh
mv ~/wsl-benchmark-results/benchmark-*.txt "$RESULTS_DIR/02-virtiofs-stock.txt"

# 3. 9p + Zen 5 kernel
echo "=== Test 3: 9p + Zen 5 Kernel ==="
read -p "Switch to Zen 5 kernel, disable virtiofs. Press enter to continue..."
wsl.exe --shutdown
sleep 5
./benchmark-suite.sh
mv ~/wsl-benchmark-results/benchmark-*.txt "$RESULTS_DIR/03-9p-zen5.txt"

# 4. VirtioFS + Zen 5 kernel
echo "=== Test 4: VirtioFS + Zen 5 Kernel (Full Optimization) ==="
read -p "Enable virtiofs with Zen 5 kernel. Press enter to continue..."
wsl.exe --shutdown
sleep 5
./benchmark-suite.sh
mv ~/wsl-benchmark-results/benchmark-*.txt "$RESULTS_DIR/04-virtiofs-zen5.txt"

echo ""
echo "Matrix complete! Results in: $RESULTS_DIR"
```

## CRITICAL: Block Size Optimization

**ALWAYS use 64K block size for VirtioFS benchmarks.** Using default 1M blocks reduces performance by 55%.

```bash
# WRONG - 1M blocks = 194 MB/s
dd if=/mnt/c/file of=/dev/null bs=1M

# CORRECT - 64K blocks = 429 MB/s (2.2x faster)
dd if=/mnt/c/file of=/dev/null bs=64K
```

**Why 64K?**
- VirtioFS lacks DAX (Direct Access) in Windows WSL2
- All I/O goes through FUSE protocol with round-trips
- 4K: IOPS-limited (31.8 MB/s)
- 64K: Optimal balance (429 MB/s)
- 1M+: Protocol overhead (194 MB/s)

See `docs/VIRTIOFS_READ_INVESTIGATION.md` for full analysis.

## Benchmark Categories

### 1. File I/O Benchmarks

**Tests**:
- Sequential write (512MB file, **64K blocks**)
- Sequential read (512MB file, **64K blocks**)
- Small file operations (5,000 files)
- Directory traversal (ls -R)

**Expected Results** (with 64K blocks):
| Operation | Baseline (9p) | Optimized (VirtioFS) | Target |
|-----------|---------------|----------------------|--------|
| Sequential write | ~200 MB/s | **~400 MB/s** | 2x |
| Sequential read | ~200 MB/s | **~429 MB/s** | 2x |
| Small files | 100-200x slower | <10x slower | <10x |
| ls -R | 50-100x slower | <10x slower | <10x |

**Note**: VirtioFS without DAX cannot reach 2000 MB/s. Expected max is ~400-500 MB/s.

### 2. Build Workload

**Test**: Compile 50-file C project

**Expected Results**:
- Baseline: 15-30 seconds
- VirtioFS: 2-5 seconds
- Target: ~5-10x improvement

### 3. Metadata Operations

**Test**: stat() on 10,000 files

**Expected Results**:
- Baseline: 50-100x slower than native
- VirtioFS: <10x slower than native

### 4. VM Exit Analysis

**Test**: Count VM exits during file operations

**Expected Results**:
- Baseline: ~50,000 exits/sec
- Optimized: <500 exits/sec (with syscall batching)

## Real-World Workload Tests

### Node.js Build (npm install)

```bash
# Create test project
mkdir -p /mnt/c/test-npm
cd /mnt/c/test-npm
npm init -y
npm install express react webpack

# Measure with time
time npm ci
```

**Expected**:
- 9p: 5-10 minutes
- VirtioFS: 30-60 seconds

### Git Repository Operations

```bash
# Clone a medium-sized repo
cd /mnt/c/test-git

time git clone https://github.com/microsoft/TypeScript.git
cd TypeScript
time git status
time git log --oneline | head -100
```

**Expected**:
- 9p: Very slow (minutes for status)
- VirtioFS: Normal git speeds

### Docker Build

```bash
# Simple Dockerfile on /mnt/c
cd /mnt/c/test-docker
cat > Dockerfile << 'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y build-essential
COPY . /app
WORKDIR /app
RUN make
EOF

time docker build .
```

## Syscall Batching Tests

### With Parasitic Batch Library

```bash
# Build the library
cd tools/strix-turbo/parasitic_batch
make

# Test with batching
time LD_PRELOAD=./parasitic_batch.so ls -R /mnt/c/Windows

# Test without batching
time ls -R /mnt/c/Windows

# Compare VM exits (requires perf)
sudo perf kvm stat -e vmexit -a -- \
    LD_PRELOAD=./parasitic_batch.so ls -R /mnt/c/Windows > /dev/null
```

**Expected**: 99% reduction in VM exits with batching

## Zen 5 Kernel Tests

### CPU Scheduler Responsiveness

```bash
# Install stress tool
sudo apt-get install stress-ng

# Test responsiveness under load
stress-ng --cpu 32 --timeout 60s &
time ls /mnt/c/Windows/System32

# Compare with stock kernel
```

### Network Performance (BBRv3)

```bash
# Install iperf3
sudo apt-get install iperf3

# Test throughput
iperf3 -c <server>

# Check BBRv3 is active
sysctl net.ipv4.tcp_congestion_control
```

## Automated Comparison Script

```bash
#!/bin/bash
# compare-benchmarks.sh

if [ $# -ne 2 ]; then
    echo "Usage: $0 <baseline-result> <optimized-result>"
    exit 1
fi

BASELINE=$1
OPTIMIZED=$2

echo "=== PERFORMANCE COMPARISON ==="
echo ""

# Extract and compare key metrics
extract_metric() {
    local file=$1
    local metric=$2
    grep "$metric" "$file" | head -1 | awk '{print $(NF-1)}'
}

# Small file ratio
BASELINE_SMALL=$(extract_metric "$BASELINE" "Small file ratio:")
OPTIMIZED_SMALL=$(extract_metric "$OPTIMIZED" "Small file ratio:")

echo "Small File Operations:"
echo "  Baseline: ${BASELINE_SMALL}x slower"
echo "  Optimized: ${OPTIMIZED_SMALL}x slower"
IMPROVEMENT=$(echo "scale=2; $BASELINE_SMALL / $OPTIMIZED_SMALL" | bc)
echo "  Improvement: ${IMPROVEMENT}x faster"
echo ""

# Directory traversal
BASELINE_LS=$(extract_metric "$BASELINE" "Directory traversal ratio:")
OPTIMIZED_LS=$(extract_metric "$OPTIMIZED" "Directory traversal ratio:")

echo "Directory Traversal:"
echo "  Baseline: ${BASELINE_LS}x slower"
echo "  Optimized: ${OPTIMIZED_LS}x slower"
IMPROVEMENT=$(echo "scale=2; $BASELINE_LS / $OPTIMIZED_LS" | bc)
echo "  Improvement: ${IMPROVEMENT}x faster"
echo ""

# Build time
BASELINE_BUILD=$(extract_metric "$BASELINE" "Build time")
OPTIMIZED_BUILD=$(extract_metric "$OPTIMIZED" "Build time")

echo "Build Time:"
echo "  Baseline: ${BASELINE_BUILD}s"
echo "  Optimized: ${OPTIMIZED_BUILD}s"
IMPROVEMENT=$(echo "scale=2; $BASELINE_BUILD / $OPTIMIZED_BUILD" | bc)
echo "  Improvement: ${IMPROVEMENT}x faster"
echo ""

# Summary
echo "=== SUMMARY ==="
if (( $(echo "$OPTIMIZED_SMALL < 10" | bc -l) )); then
    echo "✅ Met <10x goal for small files"
else
    echo "❌ Did not meet <10x goal for small files"
fi

if (( $(echo "$OPTIMIZED_LS < 10" | bc -l) )); then
    echo "✅ Met <10x goal for directory traversal"
else
    echo "❌ Did not meet <10x goal for directory traversal"
fi
```

## Performance Validation Checklist

- [ ] Run baseline benchmark (9p/drvfs)
- [ ] Run VirtioFS benchmark
- [ ] Run Zen 5 kernel benchmark
- [ ] Run full optimization (VirtioFS + Zen 5)
- [ ] Test real workload (npm install)
- [ ] Test git operations
- [ ] Test syscall batching
- [ ] Measure VM exits
- [ ] Document results in performance tracking spreadsheet
- [ ] Update README.md with validated metrics

## Reporting Results

### Create Performance Report

```bash
#!/bin/bash
# generate-report.sh

REPORT="performance-report-$(date +%Y%m%d).md"

cat > "$REPORT" << 'EOF'
# WSL2 Strix-Turbo Performance Report

## Test Configuration

- **Date**: $(date)
- **Kernel**: $(uname -r)
- **CPU**: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2)
- **RAM**: $(free -h | grep Mem | awk '{print $2}')
- **WSL Version**: $(wsl.exe --version | head -1)

## Test Results

### File I/O Performance

| Operation | Baseline (9p) | Optimized (VirtioFS) | Improvement |
|-----------|---------------|----------------------|-------------|
| Sequential Write | ... | ... | ...x |
| Sequential Read | ... | ... | ...x |
| Small Files | ... | ... | ...x |
| Directory Traversal | ... | ... | ...x |

### Real-World Workloads

| Workload | Baseline | Optimized | Improvement |
|----------|----------|-----------|-------------|
| npm install (Express) | ... | ... | ...x |
| git clone TypeScript | ... | ... | ...x |
| C project build | ... | ... | ...x |

### Goals Met

- [ ] <10x slowdown vs native for small files
- [ ] <10x slowdown for directory traversal
- [ ] <500 VM exits/sec with syscall batching
- [ ] 2-3x faster builds with all optimizations

## Conclusion

[Summary of findings]
EOF

echo "Report template created: $REPORT"
echo "Fill in actual metrics from benchmark results"
```

## Troubleshooting

### Benchmark Script Fails

```bash
# Ensure permissions
chmod +x benchmark-suite.sh

# Install dependencies
sudo apt-get install bc time

# Check disk space
df -h /tmp
df -h /mnt/c
```

### Inconsistent Results

- Run benchmarks multiple times (3-5 runs)
- Average the results
- Ensure no other heavy processes running
- Clear caches between runs: `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches`

### VM Exit Measurement Not Working

```bash
# Install perf
sudo apt-get install linux-tools-generic linux-tools-$(uname -r)

# May need to run as root or with capabilities
sudo perf kvm stat -e vmexit -a sleep 1
```

## Next Steps

After benchmarking:

1. **Document results** in the performance report
2. **Update README.md** with validated metrics (replace estimates with actuals)
3. **File issues** for any goals not met
4. **Share results** with the community
5. **Track over time** to catch regressions

---

**Last Updated**: February 5, 2026
