#!/bin/bash
# Quick Performance Validation Script
# Tests key claimed improvements

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULTS_DIR="$HOME/performance-validation-results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_FILE="$RESULTS_DIR/quick-validation-$TIMESTAMP.txt"

mkdir -p "$RESULTS_DIR"

echo "================================================================"
echo "WSL2 Strix-Turbo Quick Performance Validation"
echo "================================================================"
echo "Timestamp: $(date)"
echo ""

# System info
{
    echo "=== SYSTEM INFORMATION ==="
    echo "Date: $(date)"
    echo "Kernel: $(uname -r)"
    echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo "Mount type: $(mount | grep '/mnt/c' | awk '{print $5}')"
    echo ""
} | tee "$RESULT_FILE"

# =============================================================================
# TEST 1: KEY BLOCK SIZES ONLY (64K, 128K, 256K, 512K)
# =============================================================================

echo -e "${GREEN}=== TEST 1: BLOCK SIZE VALIDATION (KEY SIZES) ===${NC}"
echo ""
echo "=== TEST 1: BLOCK SIZE VALIDATION ===" >> "$RESULT_FILE"

TEST_DIR="/mnt/c/temp/validation-test"
mkdir -p "$TEST_DIR"

echo "Creating 256MB test file (faster)..."
dd if=/dev/zero of="$TEST_DIR/test256mb.dat" bs=1M count=256 conv=fsync 2>/dev/null

echo ""
echo "| Block Size | Write Speed | Read Speed | Notes |" | tee -a "$RESULT_FILE"
echo "|------------|-------------|------------|-------|" | tee -a "$RESULT_FILE"

# Test key block sizes only
for bs in 64K 128K 256K 512K; do
    echo -n "Testing ${bs}... "

    # Drop caches
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

    # Write test (smaller file = faster)
    write_speed=$(dd if=/dev/zero of="$TEST_DIR/test256mb.dat" bs=$bs count=$((262144 * 1024 / $(numfmt --from=iec $bs))) conv=fsync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "0 MB/s")

    # Drop caches
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1

    # Read test
    read_speed=$(dd if="$TEST_DIR/test256mb.dat" of=/dev/null bs=$bs 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1 || echo "0 MB/s")

    echo "Write: $write_speed, Read: $read_speed"

    # Mark sizes
    note=""
    if [ "$bs" = "64K" ]; then
        note="Previous optimal"
    elif [ "$bs" = "256K" ]; then
        note="**Claimed optimal**"
    fi

    echo "| $bs | $write_speed | $read_speed | $note |" | tee -a "$RESULT_FILE"
done

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# TEST 2: PARASITIC BATCHING - DEBUG OUTPUT ONLY
# =============================================================================

echo -e "${GREEN}=== TEST 2: PARASITIC BATCHING VERIFICATION ===${NC}"
echo ""
echo "=== TEST 2: PARASITIC BATCHING ===" >> "$RESULT_FILE"

BATCH_LIB="parasitic_batch/libparasitic_batch.so"

if [ -f "$BATCH_LIB" ]; then
    echo "Checking batch sizes with debug output..."
    echo ""

    # Test with small sample to see batch sizes
    echo "Debug output (expecting batch sizes 10-64):" | tee -a "$RESULT_FILE"
    STRIX_BATCH_DEBUG=1 STRIX_BATCH_SIZE=32 \
        LD_PRELOAD=./$BATCH_LIB \
        bash -c 'for i in {1..20}; do cat /etc/hosts > /dev/null 2>&1; done' 2>&1 | \
        grep -i "batch" | head -5 | tee -a "$RESULT_FILE"

    echo "" | tee -a "$RESULT_FILE"

    # Quick performance comparison
    echo "Quick performance test:" | tee -a "$RESULT_FILE"

    # Without batching
    time_without=$(bash -c 'start=$(date +%s.%N); for i in {1..50}; do stat /etc/hosts > /dev/null 2>&1; done; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "50 stat calls without batching: ${time_without}s" | tee -a "$RESULT_FILE"

    # With batching
    time_with=$(STRIX_BATCH_SIZE=32 LD_PRELOAD=./$BATCH_LIB bash -c 'start=$(date +%s.%N); for i in {1..50}; do stat /etc/hosts > /dev/null 2>&1; done; end=$(date +%s.%N); echo "$end - $start" | bc')
    echo "50 stat calls with batching: ${time_with}s" | tee -a "$RESULT_FILE"

    # Calculate improvement
    if [ $(echo "$time_without > 0" | bc) -eq 1 ] && [ $(echo "$time_with > 0" | bc) -eq 1 ]; then
        improvement=$(echo "scale=2; $time_without / $time_with" | bc)
        echo "Improvement: ${improvement}x faster" | tee -a "$RESULT_FILE"
    fi
else
    echo "Parasitic batch library not found" | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# TEST 3: CHECK LATEST BENCHMARK RESULTS
# =============================================================================

echo -e "${GREEN}=== TEST 3: LATEST BENCHMARK RESULTS ===${NC}"
echo ""
echo "=== TEST 3: LATEST BENCHMARKS ===" >> "$RESULT_FILE"

latest_result=$(ls -t ~/wsl-benchmark-results/benchmark-*.txt 2>/dev/null | head -1)
if [ -n "$latest_result" ]; then
    echo "Latest benchmark from: $latest_result" | tee -a "$RESULT_FILE"
    echo "" | tee -a "$RESULT_FILE"

    # Extract key metrics
    echo "Key Metrics:" | tee -a "$RESULT_FILE"
    grep -E "Sequential (read|write).*64K|Sequential (read|write).*256K|Small file ratio|Directory traversal ratio" "$latest_result" | tee -a "$RESULT_FILE" || echo "No metrics found with 64K or 256K block sizes" | tee -a "$RESULT_FILE"
else
    echo "No previous benchmark results found" | tee -a "$RESULT_FILE"
    echo "Run: ./benchmark-suite.sh for comprehensive tests" | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"

# =============================================================================
# SUMMARY
# =============================================================================

echo -e "${GREEN}=== VALIDATION SUMMARY ===${NC}"
echo ""
echo "=== SUMMARY ===" >> "$RESULT_FILE"

{
    echo "Quick Validation Complete"
    echo "========================="
    echo ""
    echo "1. Block Size Test:"
    echo "   - Tested 64K, 128K, 256K, 512K"
    echo "   - Review table above for optimal size"
    echo "   - Claimed: 256K with 668-787 MB/s"
    echo ""
    echo "2. Parasitic Batching:"
    echo "   - Debug output shows batch sizes"
    echo "   - Target: 10-64 ops per batch"
    echo "   - Performance improvement measured"
    echo ""
    echo "3. Historical Benchmarks:"
    echo "   - Latest results extracted"
    echo "   - Compare with current test results"
    echo ""
    echo "Full results: $RESULT_FILE"
    echo ""
    echo "For comprehensive validation, run: ./benchmark-suite.sh"
} | tee -a "$RESULT_FILE"

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo -e "${BLUE}Quick validation complete!${NC}"
echo -e "${BLUE}Results: $RESULT_FILE${NC}"
echo ""
