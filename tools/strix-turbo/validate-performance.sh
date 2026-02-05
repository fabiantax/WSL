#!/bin/bash
# Comprehensive Performance Validation Script
# Tests all claimed performance improvements from optimization cycles

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

RESULTS_DIR="$HOME/performance-validation-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="$RESULTS_DIR/validation-$TIMESTAMP.txt"

mkdir -p "$RESULTS_DIR"

echo "================================================================"
echo "WSL2 Strix-Turbo Performance Validation Suite"
echo "================================================================"
echo "Timestamp: $(date)"
echo "Results: $RESULT_FILE"
echo ""

# System info
{
    echo "=== SYSTEM INFORMATION ==="
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "Mount type: $(mount | grep '/mnt/c' | awk '{print $5}')"
    echo ""
} | tee "$RESULT_FILE"

# =============================================================================
# TEST 1: VIRTIOFS BLOCK SIZE OPTIMIZATION
# =============================================================================

echo -e "${GREEN}=== TEST 1: VIRTIOFS BLOCK SIZE VALIDATION ===${NC}"
echo ""
echo "Testing claimed improvement: 256K blocks optimal (not 64K)"
echo ""
echo "=== TEST 1: BLOCK SIZE VALIDATION ===" >> "$RESULT_FILE"

# Prepare test file
TEST_DIR="/mnt/c/temp/validation-test"
mkdir -p "$TEST_DIR"

echo "Creating 512MB test file..."
dd if=/dev/zero of="$TEST_DIR/test512mb.dat" bs=1M count=512 conv=fsync 2>/dev/null

echo ""
echo -e "${YELLOW}Block Size Performance Comparison:${NC}"
echo ""
echo "| Block Size | Write Speed | Read Speed | Notes |" | tee -a "$RESULT_FILE"
echo "|------------|-------------|------------|-------|" | tee -a "$RESULT_FILE"

# Test various block sizes
for bs in 4K 16K 64K 128K 256K 512K 1M 4M; do
    echo -n "Testing ${bs}... "

    # Drop caches
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

    # Write test
    write_speed=$(dd if=/dev/zero of="$TEST_DIR/test512mb.dat" bs=$bs count=$((524288 * 1024 / $(numfmt --from=iec $bs))) conv=fsync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "0 MB/s")

    # Drop caches again
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

    # Read test
    read_speed=$(dd if="$TEST_DIR/test512mb.dat" of=/dev/null bs=$bs 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "0 MB/s")

    # Extract numeric values for comparison
    write_val=$(echo "$write_speed" | grep -oP '^\d+(\.\d+)?')
    read_val=$(echo "$read_speed" | grep -oP '^\d+(\.\d+)?')

    echo "Write: $write_speed, Read: $read_speed"

    # Mark optimal
    note=""
    if [ "$bs" = "64K" ]; then
        note="Previous optimal"
    elif [ "$bs" = "256K" ]; then
        note="Claimed optimal"
    fi

    echo "| $bs | $write_speed | $read_speed | $note |" | tee -a "$RESULT_FILE"
done

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# TEST 2: PARASITIC BATCHING VALIDATION
# =============================================================================

echo -e "${GREEN}=== TEST 2: PARASITIC BATCHING VALIDATION ===${NC}"
echo ""
echo "Testing claimed improvement: 10-64 ops per batch (was 1)"
echo ""
echo "=== TEST 2: PARASITIC BATCHING ===" >> "$RESULT_FILE"

BATCH_LIB="parasitic_batch/libparasitic_batch.so"

if [ -f "$BATCH_LIB" ]; then
    echo "Testing batching library..."

    # Test with debug output to see batch sizes
    echo -e "${YELLOW}Sample batching debug output:${NC}"
    STRIX_BATCH_DEBUG=1 STRIX_BATCH_SIZE=32 \
        LD_PRELOAD=./$BATCH_LIB \
        bash -c 'for i in {1..50}; do cat /etc/hosts > /dev/null 2>&1; done' 2>&1 | \
        grep -i "batch" | head -10 | tee -a "$RESULT_FILE"

    echo ""

    # Performance test without batching
    echo "Testing file operations WITHOUT batching..."
    time_without=$(bash -c 'start=$(date +%s.%N); for i in {1..100}; do cat /etc/hosts > /dev/null 2>&1; done; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "Time without batching: ${time_without}s" | tee -a "$RESULT_FILE"

    # Performance test with batching
    echo "Testing file operations WITH batching..."
    time_with=$(STRIX_BATCH_SIZE=64 LD_PRELOAD=./$BATCH_LIB bash -c 'start=$(date +%s.%N); for i in {1..100}; do cat /etc/hosts > /dev/null 2>&1; done; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "Time with batching: ${time_with}s" | tee -a "$RESULT_FILE"

    # Calculate improvement
    if [ $(echo "$time_without > 0" | bc) -eq 1 ] && [ $(echo "$time_with > 0" | bc) -eq 1 ]; then
        improvement=$(echo "scale=2; $time_without / $time_with" | bc)
        echo "Improvement: ${improvement}x faster" | tee -a "$RESULT_FILE"
    fi

    echo "" | tee -a "$RESULT_FILE"
else
    echo "Parasitic batch library not found at: $BATCH_LIB" | tee -a "$RESULT_FILE"
    echo "Skipping parasitic batching tests" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"
fi

# =============================================================================
# TEST 3: REAL WORKLOAD PERFORMANCE
# =============================================================================

echo -e "${GREEN}=== TEST 3: REAL WORKLOAD TESTS ===${NC}"
echo ""
echo "=== TEST 3: REAL WORKLOADS ===" >> "$RESULT_FILE"

# Git operations
if command -v git &> /dev/null; then
    echo -e "${YELLOW}3.1 Git Clone Performance${NC}"
    echo ""

    # Without batching
    rm -rf /tmp/ts-test1 2>/dev/null || true
    echo "Git clone WITHOUT batching..."
    git_time_without=$(bash -c 'start=$(date +%s.%N); git clone --depth 1 https://github.com/microsoft/TypeScript.git /tmp/ts-test1 2>/dev/null; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "Time: ${git_time_without}s" | tee -a "$RESULT_FILE"
    rm -rf /tmp/ts-test1

    # With batching (if library exists)
    if [ -f "$BATCH_LIB" ]; then
        rm -rf /tmp/ts-test2 2>/dev/null || true
        echo "Git clone WITH batching..."
        git_time_with=$(STRIX_BATCH_SIZE=64 LD_PRELOAD=./$BATCH_LIB bash -c 'start=$(date +%s.%N); git clone --depth 1 https://github.com/microsoft/TypeScript.git /tmp/ts-test2 2>/dev/null; end=$(date +%s.%N); echo "$end - $start" | bc')
        echo "Time: ${git_time_with}s" | tee -a "$RESULT_FILE"
        rm -rf /tmp/ts-test2

        # Calculate improvement
        if [ $(echo "$git_time_without > 0" | bc) -eq 1 ] && [ $(echo "$git_time_with > 0" | bc) -eq 1 ]; then
            git_improvement=$(echo "scale=2; $git_time_without / $git_time_with" | bc)
            echo "Git clone improvement: ${git_improvement}x faster" | tee -a "$RESULT_FILE"
        fi
    fi

    echo "" | tee -a "$RESULT_FILE"
fi

# Directory copy operations
echo -e "${YELLOW}3.2 Large Directory Copy${NC}"
echo ""

if [ -d "/mnt/c/Windows/System32/drivers" ]; then
    # Without batching
    rm -rf /tmp/drivers-test1 2>/dev/null || true
    echo "Directory copy WITHOUT batching..."
    copy_time_without=$(bash -c 'start=$(date +%s.%N); rsync -a /mnt/c/Windows/System32/drivers /tmp/drivers-test1 2>/dev/null; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "Time: ${copy_time_without}s" | tee -a "$RESULT_FILE"

    # With batching (if library exists)
    if [ -f "$BATCH_LIB" ]; then
        rm -rf /tmp/drivers-test2 2>/dev/null || true
        echo "Directory copy WITH batching..."
        copy_time_with=$(STRIX_BATCH_SIZE=64 LD_PRELOAD=./$BATCH_LIB bash -c 'start=$(date +%s.%N); rsync -a /mnt/c/Windows/System32/drivers /tmp/drivers-test2 2>/dev/null; end=$(date +%s.%N); echo "$end - $start" | bc')
        echo "Time: ${copy_time_with}s" | tee -a "$RESULT_FILE"

        # Calculate improvement
        if [ $(echo "$copy_time_without > 0" | bc) -eq 1 ] && [ $(echo "$copy_time_with > 0" | bc) -eq 1 ]; then
            copy_improvement=$(echo "scale=2; $copy_time_without / $copy_time_with" | bc)
            echo "Directory copy improvement: ${copy_improvement}x faster" | tee -a "$RESULT_FILE"
        fi
    fi

    # Cleanup
    rm -rf /tmp/drivers-test1 /tmp/drivers-test2 2>/dev/null || true
fi

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# TEST 4: RUN OFFICIAL BENCHMARK SUITE
# =============================================================================

echo -e "${GREEN}=== TEST 4: OFFICIAL BENCHMARK SUITE ===${NC}"
echo ""
echo "=== TEST 4: OFFICIAL BENCHMARKS ===" >> "$RESULT_FILE"

if [ -f "benchmark-suite.sh" ]; then
    echo "Running official benchmark suite..."
    echo "(This may take several minutes)"
    echo ""

    bash benchmark-suite.sh

    # Find latest benchmark result
    latest_result=$(ls -t ~/wsl-benchmark-results/benchmark-*.txt 2>/dev/null | head -1)
    if [ -n "$latest_result" ]; then
        echo "Latest benchmark results:" | tee -a "$RESULT_FILE"
        echo "=========================" | tee -a "$RESULT_FILE"
        grep -E "Sequential (read|write)|Small file|Directory traversal|Build time" "$latest_result" | tee -a "$RESULT_FILE"
    fi
else
    echo "benchmark-suite.sh not found in current directory" | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# SUMMARY AND VALIDATION
# =============================================================================

echo -e "${GREEN}=== VALIDATION SUMMARY ===${NC}"
echo ""
echo "=== VALIDATION SUMMARY ===" >> "$RESULT_FILE"

{
    echo "Test Results:"
    echo "============="
    echo ""
    echo "1. Block Size Optimization:"
    echo "   - Check table above to determine optimal block size"
    echo "   - Claimed: 256K optimal with 668-787 MB/s"
    echo "   - Validation: See measured values"
    echo ""
    echo "2. Parasitic Batching:"
    if [ -f "$BATCH_LIB" ]; then
        echo "   - Library found and tested"
        echo "   - Check debug output for batch sizes (target: 10-64 ops)"
        echo "   - Performance improvement measured"
    else
        echo "   - Library not found - unable to validate"
    fi
    echo ""
    echo "3. Real Workload Performance:"
    echo "   - Git clone and directory copy tested"
    echo "   - Results show practical impact"
    echo ""
    echo "4. Official Benchmarks:"
    echo "   - See benchmark results for comprehensive metrics"
    echo ""
    echo "Conclusion:"
    echo "==========="
    echo "Review the detailed results above to validate each claimed improvement."
    echo ""
    echo "Full results saved to: $RESULT_FILE"
} | tee -a "$RESULT_FILE"

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo -e "${BLUE}Validation complete!${NC}"
echo -e "${BLUE}Results: $RESULT_FILE${NC}"
echo ""
