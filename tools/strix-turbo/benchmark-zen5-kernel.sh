#!/bin/bash
#
# Zen 5 Kernel Performance Benchmark Suite
# Compares baseline vs optimized kernel performance
#
# Usage: ./benchmark-zen5-kernel.sh [output_file]
#

set -e

OUTPUT_FILE="${1:-benchmark-results-$(date +%Y%m%d-%H%M%S).json}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}"
echo "═══════════════════════════════════════════════════════════════"
echo "  Zen 5 Kernel Performance Benchmark Suite"
echo "═══════════════════════════════════════════════════════════════"
echo -e "${NC}"

# Get system info
KERNEL_VERSION=$(uname -r)
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
TOTAL_RAM=$(free -h | grep Mem | awk '{print $2}')

echo -e "${BLUE}[INFO]${NC} System Information:"
echo "  Kernel: $KERNEL_VERSION"
echo "  CPU: $CPU_MODEL"
echo "  Cores: $CPU_CORES"
echo "  RAM: $TOTAL_RAM"
echo ""

# Initialize JSON output
cat > "$OUTPUT_FILE" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "kernel_version": "$KERNEL_VERSION",
  "cpu_model": "$CPU_MODEL",
  "cpu_cores": $CPU_CORES,
  "total_ram": "$TOTAL_RAM",
  "benchmarks": {
EOF

# Function to add JSON entry
add_result() {
    local name=$1
    local value=$2
    local unit=$3
    echo "    \"$name\": {\"value\": $value, \"unit\": \"$unit\"}," >> "$OUTPUT_FILE"
}

# ═══════════════════════════════════════════════════════════════
# 1. CPU Performance - Kernel Compilation
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 1/10]${NC} CPU: Kernel module compilation (parallel make)..."

# Create a small C project to compile
mkdir -p "$TEMP_DIR/compile_test"
cd "$TEMP_DIR/compile_test"

# Generate 100 simple C files
for i in {1..100}; do
    cat > "file_$i.c" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

double compute_heavy(int n) {
    double result = 0.0;
    for (int i = 0; i < n; i++) {
        result += sqrt(i) * sin(i) * cos(i);
    }
    return result;
}

int main() {
    compute_heavy(100000);
    return 0;
}
CEOF
done

# Create Makefile
cat > Makefile << 'MEOF'
CC=gcc
CFLAGS=-O2 -march=native -mtune=native
TARGETS=$(patsubst %.c,%,$(wildcard file_*.c))

all: $(TARGETS)

%: %.c
	$(CC) $(CFLAGS) -o $@ $< -lm

clean:
	rm -f $(TARGETS)
MEOF

# Benchmark compilation
START=$(date +%s.%N)
make -j$CPU_CORES > /dev/null 2>&1
END=$(date +%s.%N)
COMPILE_TIME=$(echo "$END - $START" | bc)
echo -e "  ${GREEN}✓${NC} Compilation time: ${COMPILE_TIME}s"
add_result "cpu_parallel_compilation" "$COMPILE_TIME" "seconds"

cd - > /dev/null

# ═══════════════════════════════════════════════════════════════
# 2. CPU Performance - Compression
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 2/10]${NC} CPU: gzip compression (single-threaded)..."

dd if=/dev/zero of="$TEMP_DIR/testfile" bs=1M count=500 2>/dev/null
START=$(date +%s.%N)
gzip -c "$TEMP_DIR/testfile" > "$TEMP_DIR/testfile.gz"
END=$(date +%s.%N)
GZIP_TIME=$(echo "$END - $START" | bc)
echo -e "  ${GREEN}✓${NC} gzip time: ${GZIP_TIME}s"
add_result "cpu_gzip_compression" "$GZIP_TIME" "seconds"

# ═══════════════════════════════════════════════════════════════
# 3. CPU Performance - Parallel Compression
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 3/10]${NC} CPU: pigz compression (parallel)..."

START=$(date +%s.%N)
pigz -p $CPU_CORES -c "$TEMP_DIR/testfile" > "$TEMP_DIR/testfile.pigz" 2>/dev/null || {
    echo -e "  ${RED}✗${NC} pigz not installed, installing..."
    sudo apt-get install -y pigz > /dev/null 2>&1
    pigz -p $CPU_CORES -c "$TEMP_DIR/testfile" > "$TEMP_DIR/testfile.pigz"
}
END=$(date +%s.%N)
PIGZ_TIME=$(echo "$END - $START" | bc)
echo -e "  ${GREEN}✓${NC} pigz time: ${PIGZ_TIME}s"
add_result "cpu_pigz_compression_parallel" "$PIGZ_TIME" "seconds"

# ═══════════════════════════════════════════════════════════════
# 4. Memory Bandwidth
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 4/10]${NC} Memory: bandwidth test..."

# Simple memory bandwidth test
cat > "$TEMP_DIR/membw.c" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SIZE (512 * 1024 * 1024) // 512MB

int main() {
    char *src = malloc(SIZE);
    char *dst = malloc(SIZE);

    memset(src, 0xAA, SIZE);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    memcpy(dst, src, SIZE);

    clock_gettime(CLOCK_MONOTONIC, &end);

    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    double bandwidth = (SIZE / (1024.0 * 1024.0 * 1024.0)) / elapsed;

    printf("%.2f\n", bandwidth);

    free(src);
    free(dst);
    return 0;
}
CEOF

gcc -O2 -o "$TEMP_DIR/membw" "$TEMP_DIR/membw.c"
MEMBW=$("$TEMP_DIR/membw")
echo -e "  ${GREEN}✓${NC} Memory bandwidth: ${MEMBW} GB/s"
add_result "memory_bandwidth" "$MEMBW" "GB/s"

# ═══════════════════════════════════════════════════════════════
# 5. File I/O - Sequential Write
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 5/10]${NC} I/O: Sequential write performance..."

START=$(date +%s.%N)
dd if=/dev/zero of="$TEMP_DIR/iotest" bs=1M count=2000 conv=fdatasync 2>&1 | grep -v records
END=$(date +%s.%N)
WRITE_TIME=$(echo "$END - $START" | bc)
WRITE_SPEED=$(echo "2000 / $WRITE_TIME" | bc -l)
echo -e "  ${GREEN}✓${NC} Write speed: $(printf "%.2f" $WRITE_SPEED) MB/s"
add_result "io_sequential_write" "$(printf "%.2f" $WRITE_SPEED)" "MB/s"

# ═══════════════════════════════════════════════════════════════
# 6. File I/O - Sequential Read
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 6/10]${NC} I/O: Sequential read performance..."

# Clear cache
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true

START=$(date +%s.%N)
dd if="$TEMP_DIR/iotest" of=/dev/null bs=1M 2>&1 | grep -v records
END=$(date +%s.%N)
READ_TIME=$(echo "$END - $START" | bc)
READ_SPEED=$(echo "2000 / $READ_TIME" | bc -l)
echo -e "  ${GREEN}✓${NC} Read speed: $(printf "%.2f" $READ_SPEED) MB/s"
add_result "io_sequential_read" "$(printf "%.2f" $READ_SPEED)" "MB/s"

# ═══════════════════════════════════════════════════════════════
# 7. File I/O - Random Access (WSL2 Plan9 stress test)
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 7/10]${NC} I/O: Random file access (WSL2 stress)..."

# Create many small files
mkdir -p "$TEMP_DIR/random_io"
START=$(date +%s.%N)
for i in {1..1000}; do
    echo "test data $i" > "$TEMP_DIR/random_io/file_$i.txt"
done
END=$(date +%s.%N)
SMALL_FILES_TIME=$(echo "$END - $START" | bc)
echo -e "  ${GREEN}✓${NC} 1000 small files creation: ${SMALL_FILES_TIME}s"
add_result "io_small_files_create" "$SMALL_FILES_TIME" "seconds"

# ═══════════════════════════════════════════════════════════════
# 8. System Call Overhead
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 8/10]${NC} System: syscall overhead..."

cat > "$TEMP_DIR/syscall_test.c" << 'CEOF'
#include <unistd.h>
#include <time.h>
#include <stdio.h>

#define ITERATIONS 1000000

int main() {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (int i = 0; i < ITERATIONS; i++) {
        getpid();
    }

    clock_gettime(CLOCK_MONOTONIC, &end);

    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    double ns_per_call = (elapsed * 1e9) / ITERATIONS;

    printf("%.2f\n", ns_per_call);
    return 0;
}
CEOF

gcc -O2 -o "$TEMP_DIR/syscall_test" "$TEMP_DIR/syscall_test.c"
SYSCALL_NS=$("$TEMP_DIR/syscall_test")
echo -e "  ${GREEN}✓${NC} Syscall overhead: ${SYSCALL_NS} ns/call"
add_result "syscall_overhead" "$SYSCALL_NS" "ns/call"

# ═══════════════════════════════════════════════════════════════
# 9. Context Switch Performance
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 9/10]${NC} System: context switch performance..."

cat > "$TEMP_DIR/ctxsw_test.c" << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sched.h>

#define ITERATIONS 100000

int main() {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (int i = 0; i < ITERATIONS; i++) {
        sched_yield();
    }

    clock_gettime(CLOCK_MONOTONIC, &end);

    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    double us_per_switch = (elapsed * 1e6) / ITERATIONS;

    printf("%.2f\n", us_per_switch);
    return 0;
}
CEOF

gcc -O2 -o "$TEMP_DIR/ctxsw_test" "$TEMP_DIR/ctxsw_test.c"
CTXSW_US=$("$TEMP_DIR/ctxsw_test")
echo -e "  ${GREEN}✓${NC} Context switch: ${CTXSW_US} μs/switch"
add_result "context_switch" "$CTXSW_US" "us/switch"

# ═══════════════════════════════════════════════════════════════
# 10. Overall System Responsiveness
# ═══════════════════════════════════════════════════════════════
echo -e "${CYAN}[TEST 10/10]${NC} System: overall responsiveness..."

START=$(date +%s.%N)
# Simulate typical development workflow
git init "$TEMP_DIR/git_test" > /dev/null 2>&1
cd "$TEMP_DIR/git_test"
for i in {1..50}; do
    echo "content $i" > "file$i.txt"
done
git add . > /dev/null 2>&1
git commit -m "test" > /dev/null 2>&1
ls -la > /dev/null
find . -type f > /dev/null
grep -r "content" . > /dev/null
END=$(date +%s.%N)
WORKFLOW_TIME=$(echo "$END - $START" | bc)
echo -e "  ${GREEN}✓${NC} Dev workflow simulation: ${WORKFLOW_TIME}s"
add_result "workflow_simulation" "$WORKFLOW_TIME" "seconds"

cd - > /dev/null

# ═══════════════════════════════════════════════════════════════
# Finalize JSON
# ═══════════════════════════════════════════════════════════════

# Remove trailing comma from last entry
sed -i '$ s/,$//' "$OUTPUT_FILE"

cat >> "$OUTPUT_FILE" << EOF
  }
}
EOF

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Benchmark Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Results saved to:${NC} $OUTPUT_FILE"
echo ""
echo -e "${CYAN}Summary:${NC}"
cat "$OUTPUT_FILE" | jq -r '.benchmarks | to_entries[] | "  \(.key): \(.value.value) \(.value.unit)"' 2>/dev/null || cat "$OUTPUT_FILE"

echo ""
echo -e "${BLUE}[INFO]${NC} To compare with another benchmark:"
echo "  diff <(jq '.benchmarks' baseline.json) <(jq '.benchmarks' optimized.json)"
echo ""
