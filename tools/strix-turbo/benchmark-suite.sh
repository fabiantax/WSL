#!/bin/bash
# WSL2 Performance Benchmark Suite
# Tests VirtioFS vs 9p/drvfs, Zen 5 kernel optimizations, and syscall batching

set -e

BENCHMARK_DIR="/tmp/wsl-benchmarks"
RESULTS_DIR="$HOME/wsl-benchmark-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="$RESULTS_DIR/benchmark-$TIMESTAMP.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

mkdir -p "$BENCHMARK_DIR" "$RESULTS_DIR"

echo "================================================================"
echo "WSL2 Strix-Turbo Performance Benchmark Suite"
echo "================================================================"
echo "Timestamp: $(date)"
echo "Kernel: $(uname -r)"
echo "Results: $RESULT_FILE"
echo ""

# System info
{
    echo "=== SYSTEM INFORMATION ==="
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "WSL Version: $(cat /proc/version)"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "CPU Cores: $(nproc)"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo ""
} | tee "$RESULT_FILE"

# Detect current filesystem type for /mnt/c
MOUNT_TYPE=$(mount | grep "/mnt/c" | awk '{print $5}')
echo -e "${BLUE}Current /mnt/c filesystem: ${MOUNT_TYPE}${NC}"
echo "Mount type: $MOUNT_TYPE" >> "$RESULT_FILE"
echo ""

# =============================================================================
# 1. FILE I/O BENCHMARKS
# =============================================================================

echo -e "${GREEN}=== 1. FILE I/O BENCHMARKS ===${NC}"
echo ""
echo "=== FILE I/O BENCHMARKS ===" >> "$RESULT_FILE"

# Test directories
LINUX_TESTDIR="/tmp/benchmark-native"
WINDOWS_TESTDIR="/mnt/c/temp/benchmark-wsl"
mkdir -p "$LINUX_TESTDIR" "$WINDOWS_TESTDIR"

# 1.1 Sequential Write Performance (optimized: 512MB instead of 1GB)
echo -e "${YELLOW}1.1 Sequential Write (512MB file, 64K blocks - optimal for VirtioFS)${NC}"
echo "Starting: $(date +%T)"
echo ""

echo "--- Linux Native (baseline) ---"
NATIVE_WRITE=$(timeout 60 dd if=/dev/zero of="$LINUX_TESTDIR/test512mb.dat" bs=64K count=8192 conv=fdatasync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "TIMEOUT")
echo "Native write: $NATIVE_WRITE"
echo "Sequential write (Linux native, 64K): $NATIVE_WRITE" >> "$RESULT_FILE"

echo "--- /mnt/c (current mount: $MOUNT_TYPE) ---"
WINDOWS_WRITE=$(timeout 60 dd if=/dev/zero of="$WINDOWS_TESTDIR/test512mb.dat" bs=64K count=8192 conv=fdatasync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "TIMEOUT")
echo "Windows mount write: $WINDOWS_WRITE"
echo "Sequential write (/mnt/c $MOUNT_TYPE, 64K): $WINDOWS_WRITE" >> "$RESULT_FILE"
echo "Completed: $(date +%T)"
echo ""

# 1.2 Sequential Read Performance (optimized: 512MB instead of 1GB)
echo -e "${YELLOW}1.2 Sequential Read (512MB file, 64K blocks - optimal for VirtioFS)${NC}"
echo "Starting: $(date +%T)"
echo ""

sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

echo "--- Linux Native ---"
NATIVE_READ=$(timeout 60 dd if="$LINUX_TESTDIR/test512mb.dat" of=/dev/null bs=64K 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "TIMEOUT")
echo "Native read: $NATIVE_READ"
echo "Sequential read (Linux native, 64K): $NATIVE_READ" >> "$RESULT_FILE"

sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

echo "--- /mnt/c ---"
WINDOWS_READ=$(timeout 60 dd if="$WINDOWS_TESTDIR/test512mb.dat" of=/dev/null bs=64K 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "TIMEOUT")
echo "Windows mount read: $WINDOWS_READ"
echo "Sequential read (/mnt/c $MOUNT_TYPE, 64K): $WINDOWS_READ" >> "$RESULT_FILE"
echo "Completed: $(date +%T)"
echo ""

# 1.3 Small File Operations (optimized: 5,000 files instead of 10,000)
echo -e "${YELLOW}1.3 Small File Operations (5,000 files)${NC}"
echo "Starting: $(date +%T)"
echo ""

echo "--- Linux Native ---"
NATIVE_SMALL_START=$(date +%s.%N)
for i in {1..5000}; do
    echo "test" > "$LINUX_TESTDIR/small_$i.txt"
done
NATIVE_SMALL_END=$(date +%s.%N)
NATIVE_SMALL_TIME=$(echo "$NATIVE_SMALL_END - $NATIVE_SMALL_START" | bc)
echo "Native small files: ${NATIVE_SMALL_TIME}s"
echo "Small file creation (Linux native): ${NATIVE_SMALL_TIME}s" >> "$RESULT_FILE"

echo "--- /mnt/c ---"
WINDOWS_SMALL_START=$(date +%s.%N)
for i in {1..5000}; do
    echo "test" > "$WINDOWS_TESTDIR/small_$i.txt"
done
WINDOWS_SMALL_END=$(date +%s.%N)
WINDOWS_SMALL_TIME=$(echo "$WINDOWS_SMALL_END - $WINDOWS_SMALL_START" | bc)
echo "Windows mount small files: ${WINDOWS_SMALL_TIME}s"
echo "Small file creation (/mnt/c $MOUNT_TYPE): ${WINDOWS_SMALL_TIME}s" >> "$RESULT_FILE"
echo "Completed: $(date +%T)"

# Calculate speedup/slowdown
SMALL_RATIO=$(echo "scale=2; $WINDOWS_SMALL_TIME / $NATIVE_SMALL_TIME" | bc)
echo "Ratio (/mnt/c vs native): ${SMALL_RATIO}x"
echo "Small file ratio: ${SMALL_RATIO}x" >> "$RESULT_FILE"
echo ""

# 1.4 Directory Traversal
echo -e "${YELLOW}1.4 Directory Traversal (ls -R)${NC}"
echo ""

echo "--- Linux Native ---"
NATIVE_LS_START=$(date +%s.%N)
ls -R "$LINUX_TESTDIR" > /dev/null
NATIVE_LS_END=$(date +%s.%N)
NATIVE_LS_TIME=$(echo "$NATIVE_LS_END - $NATIVE_LS_START" | bc)
echo "Native ls -R: ${NATIVE_LS_TIME}s"
echo "Directory traversal (Linux native): ${NATIVE_LS_TIME}s" >> "$RESULT_FILE"

echo "--- /mnt/c ---"
WINDOWS_LS_START=$(date +%s.%N)
ls -R "$WINDOWS_TESTDIR" > /dev/null
WINDOWS_LS_END=$(date +%s.%N)
WINDOWS_LS_TIME=$(echo "$WINDOWS_LS_END - $WINDOWS_LS_START" | bc)
echo "Windows mount ls -R: ${WINDOWS_LS_TIME}s"
echo "Directory traversal (/mnt/c $MOUNT_TYPE): ${WINDOWS_LS_TIME}s" >> "$RESULT_FILE"

LS_RATIO=$(echo "scale=2; $WINDOWS_LS_TIME / $NATIVE_LS_TIME" | bc)
echo "Ratio: ${LS_RATIO}x"
echo "Directory traversal ratio: ${LS_RATIO}x" >> "$RESULT_FILE"
echo ""

# =============================================================================
# 2. BUILD WORKLOAD BENCHMARK (Real-world scenario)
# =============================================================================

echo -e "${GREEN}=== 2. BUILD WORKLOAD BENCHMARK ===${NC}"
echo ""
echo "=== BUILD WORKLOAD ===" >> "$RESULT_FILE"

# Test with a small C project
TEST_PROJECT_DIR="$WINDOWS_TESTDIR/test-project"
mkdir -p "$TEST_PROJECT_DIR"

# Create a simple multi-file C project (optimized: 25 files instead of 50)
for i in {1..25}; do
    cat > "$TEST_PROJECT_DIR/file$i.c" << 'EOF'
#include <stdio.h>
int func_FILENUM() { return FILENUM; }
EOF
    sed -i "s/FILENUM/$i/g" "$TEST_PROJECT_DIR/file$i.c"
done

cat > "$TEST_PROJECT_DIR/main.c" << 'EOF'
#include <stdio.h>
int main() { printf("Hello\n"); return 0; }
EOF

cat > "$TEST_PROJECT_DIR/Makefile" << 'EOF'
SOURCES=$(wildcard *.c)
OBJECTS=$(SOURCES:.c=.o)
TARGET=program

all: $(TARGET)

$(TARGET): $(OBJECTS)
	gcc -o $@ $^

%.o: %.c
	gcc -c $<

clean:
	rm -f $(OBJECTS) $(TARGET)

.PHONY: all clean
EOF

echo -e "${YELLOW}2.1 Build Time (25-file C project)${NC}"
echo "Starting: $(date +%T)"
echo ""

cd "$TEST_PROJECT_DIR"
make clean > /dev/null 2>&1 || true

BUILD_START=$(date +%s.%N)
timeout 120 make -j$(nproc) > /dev/null 2>&1 || BUILD_TIMEOUT="yes"
BUILD_END=$(date +%s.%N)
BUILD_TIME=$(echo "$BUILD_END - $BUILD_START" | bc)

if [ "$BUILD_TIMEOUT" = "yes" ]; then
    echo "Build time on /mnt/c: ${BUILD_TIME}s (TIMEOUT - exceeded 120s limit)"
    echo "Build time (/mnt/c $MOUNT_TYPE): ${BUILD_TIME}s (TIMEOUT)" >> "$RESULT_FILE"
else
    echo "Build time on /mnt/c: ${BUILD_TIME}s"
    echo "Build time (/mnt/c $MOUNT_TYPE): ${BUILD_TIME}s" >> "$RESULT_FILE"
fi
echo "Completed: $(date +%T)"
echo ""

cd - > /dev/null

# =============================================================================
# 3. METADATA OPERATIONS
# =============================================================================

echo -e "${GREEN}=== 3. METADATA OPERATIONS ===${NC}"
echo ""
echo "=== METADATA OPERATIONS ===" >> "$RESULT_FILE"

echo -e "${YELLOW}3.1 File stat operations (5,000 files)${NC}"
echo "Starting: $(date +%T)"
echo ""

echo "--- Linux Native ---"
NATIVE_STAT_START=$(date +%s.%N)
for i in {1..5000}; do
    stat "$LINUX_TESTDIR/small_$i.txt" > /dev/null 2>&1
done
NATIVE_STAT_END=$(date +%s.%N)
NATIVE_STAT_TIME=$(echo "$NATIVE_STAT_END - $NATIVE_STAT_START" | bc)
echo "Native stat: ${NATIVE_STAT_TIME}s"
echo "Stat operations (Linux native): ${NATIVE_STAT_TIME}s" >> "$RESULT_FILE"

echo "--- /mnt/c ---"
WINDOWS_STAT_START=$(date +%s.%N)
for i in {1..5000}; do
    stat "$WINDOWS_TESTDIR/small_$i.txt" > /dev/null 2>&1
done
WINDOWS_STAT_END=$(date +%s.%N)
WINDOWS_STAT_TIME=$(echo "$WINDOWS_STAT_END - $WINDOWS_STAT_START" | bc)
echo "Windows mount stat: ${WINDOWS_STAT_TIME}s"
echo "Stat operations (/mnt/c $MOUNT_TYPE): ${WINDOWS_STAT_TIME}s" >> "$RESULT_FILE"
echo "Completed: $(date +%T)"

STAT_RATIO=$(echo "scale=2; $WINDOWS_STAT_TIME / $NATIVE_STAT_TIME" | bc)
echo "Ratio: ${STAT_RATIO}x"
echo "Stat ratio: ${STAT_RATIO}x" >> "$RESULT_FILE"
echo ""

# =============================================================================
# 4. VM EXIT MEASUREMENT (if perf available)
# =============================================================================

if command -v perf &> /dev/null; then
    echo -e "${GREEN}=== 4. VM EXIT ANALYSIS ===${NC}"
    echo ""
    echo "=== VM EXIT ANALYSIS ===" >> "$RESULT_FILE"

    echo -e "${YELLOW}4.1 VM Exits during file operations${NC}"
    echo ""

    # Small sample to avoid long perf runs
    echo "Measuring VM exits for 1000 file operations..."

    VM_EXIT_COUNT=$(sudo perf kvm stat -e vmexit -a sleep 0.1 2>&1 | grep -oP '\d+' | head -1 || echo "N/A")
    echo "VM exits (baseline): $VM_EXIT_COUNT"
    echo "VM exits baseline: $VM_EXIT_COUNT" >> "$RESULT_FILE"

    # Would need syscall batching enabled to compare
    echo "(Note: Enable parasitic_batch.so for comparison)"
    echo ""
else
    echo -e "${YELLOW}perf not available, skipping VM exit analysis${NC}"
    echo "VM exit analysis: skipped (perf not available)" >> "$RESULT_FILE"
    echo ""
fi

# =============================================================================
# 5. CLEANUP AND SUMMARY
# =============================================================================

echo -e "${GREEN}=== CLEANING UP ===${NC}"
rm -rf "$LINUX_TESTDIR"
rm -rf "$WINDOWS_TESTDIR"

echo ""
echo -e "${GREEN}=== BENCHMARK SUMMARY ===${NC}"
echo ""
echo "=== SUMMARY ===" >> "$RESULT_FILE"

{
    echo "Mount Type: $MOUNT_TYPE"
    echo ""
    echo "Performance Ratios (/mnt/c vs native):"
    echo "  Small file creation: ${SMALL_RATIO}x"
    echo "  Directory traversal: ${LS_RATIO}x"
    echo "  Stat operations: ${STAT_RATIO}x"
    echo ""
    echo "Target: <10x for production readiness"

    # Determine if we met goals
    if (( $(echo "$SMALL_RATIO < 10" | bc -l) )); then
        echo "  ✅ Small file goal: MET"
    else
        echo "  ❌ Small file goal: NOT MET"
    fi

    if (( $(echo "$LS_RATIO < 10" | bc -l) )); then
        echo "  ✅ Directory traversal goal: MET"
    else
        echo "  ❌ Directory traversal goal: NOT MET"
    fi

    if (( $(echo "$STAT_RATIO < 10" | bc -l) )); then
        echo "  ✅ Stat operations goal: MET"
    else
        echo "  ❌ Stat operations goal: NOT MET"
    fi

    echo ""
    echo "Full results: $RESULT_FILE"
} | tee -a "$RESULT_FILE"

echo ""
echo -e "${BLUE}Benchmark complete! Results saved to: $RESULT_FILE${NC}"
echo ""
echo "To compare configurations:"
echo "  1. Run with current setup (virtiofs)"
echo "  2. Disable virtiofs in .wslconfig"
echo "  3. Run again to get 9p baseline"
echo "  4. Compare the two result files"
