#!/bin/bash
#
# Quick Kernel Performance Benchmark (no sudo required, fast)
#

OUTPUT_FILE="${1:-quick-benchmark-$(date +%Y%m%d-%H%M%S).json}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Quick Zen 5 Kernel Benchmark"
echo "═══════════════════════════════════════════════════════════════"

KERNEL=$(uname -r)
CPU=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
CORES=$(nproc)

echo "Kernel: $KERNEL"
echo "CPU: $CPU"
echo "Cores: $CORES"
echo ""

# Start JSON
cat > "$OUTPUT_FILE" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "kernel": "$KERNEL",
  "cpu": "$CPU",
  "cores": $CORES,
  "tests": {
EOF

# Test 1: Parallel compilation
echo "[1/5] Parallel compilation..."
cd "$(mktemp -d)"
for i in {1..50}; do
  echo '#include <stdio.h>
#include <math.h>
int main() { printf("%f\\n", sqrt(123.456)); return 0; }' > "test$i.c"
done
cat > Makefile << 'MF'
all: $(patsubst %.c,%.out,$(wildcard *.c))
%.out: %.c
	gcc -O2 -o $@ $< -lm
MF

START=$(date +%s.%N)
make -j$CORES > /dev/null 2>&1
END=$(date +%s.%N)
COMPILE_TIME=$(echo "scale=3; $END - $START" | bc)
echo "  Time: ${COMPILE_TIME}s"
cd - > /dev/null

# Test 2: CPU intensive (no dependencies)
echo "[2/5] CPU intensive computation..."
START=$(date +%s.%N)
python3 -c "import math; sum(math.sqrt(i) * math.sin(i) for i in range(1000000))" > /dev/null
END=$(date +%s.%N)
CPU_TIME=$(echo "scale=3; $END - $START" | bc)
echo "  Time: ${CPU_TIME}s"

# Test 3: Small file I/O (WSL2 stress test)
echo "[3/5] Small file operations..."
TEMP_DIR=$(mktemp -d)
START=$(date +%s.%N)
for i in {1..500}; do
  echo "test$i" > "$TEMP_DIR/file$i.txt"
done
END=$(date +%s.%N)
IO_TIME=$(echo "scale=3; $END - $START" | bc)
rm -rf "$TEMP_DIR"
echo "  Time: ${IO_TIME}s"

# Test 4: Syscall overhead
echo "[4/5] Syscall overhead..."
START=$(date +%s.%N)
for i in {1..10000}; do
  pwd > /dev/null
done
END=$(date +%s.%N)
SYSCALL_TIME=$(echo "scale=3; $END - $START" | bc)
echo "  Time: ${SYSCALL_TIME}s"

# Test 5: Git operations (real-world workflow)
echo "[5/5] Git workflow..."
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
START=$(date +%s.%N)
git init > /dev/null 2>&1
for i in {1..20}; do
  echo "content$i" > "file$i.txt"
done
git add . > /dev/null 2>&1
git commit -m "test" > /dev/null 2>&1
END=$(date +%s.%N)
GIT_TIME=$(echo "scale=3; $END - $START" | bc)
cd - > /dev/null
rm -rf "$TEMP_DIR"
echo "  Time: ${GIT_TIME}s"

# Finish JSON
cat >> "$OUTPUT_FILE" << EOF
    "parallel_compilation": ${COMPILE_TIME},
    "cpu_computation": ${CPU_TIME},
    "small_file_io": ${IO_TIME},
    "syscall_overhead": ${SYSCALL_TIME},
    "git_workflow": ${GIT_TIME}
  }
}
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Results saved to: $OUTPUT_FILE"
cat "$OUTPUT_FILE"
