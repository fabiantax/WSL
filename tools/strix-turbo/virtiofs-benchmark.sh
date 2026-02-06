#!/bin/bash
# VirtioFS Performance Benchmark Script
# Optimized for WSL2 Strix-Turbo
# Based on optimization cycles completed 2026-02-05

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TESTDIR="${1:-/mnt/c/temp}"
OPTIMAL_BS="256K"
COUNT_SMALL=1024  # 256MB
COUNT_LARGE=8192  # 2GB

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}WSL2 Strix-Turbo VirtioFS Benchmark${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Test Directory: $TESTDIR"
echo "Optimal Block Size: $OPTIMAL_BS"
echo ""

# Create test directory if needed
mkdir -p "$TESTDIR"

# Function to extract and display speed
extract_speed() {
    grep -E 'copied' | sed -E 's/.*, ([0-9.]+ [kMG]B\/s)/\1/'
}

echo -e "${GREEN}=== Quick Performance Test (256MB) ===${NC}"
echo -n "Write (optimal 256K): "
dd if=/dev/zero of="$TESTDIR/quick_test.dat" bs=$OPTIMAL_BS count=$COUNT_SMALL oflag=direct 2>&1 | extract_speed
echo -n "Read (optimal 256K):  "
dd if="$TESTDIR/quick_test.dat" of=/dev/null bs=$OPTIMAL_BS count=$COUNT_SMALL iflag=direct 2>&1 | extract_speed
rm -f "$TESTDIR/quick_test.dat"
echo ""

echo -e "${GREEN}=== Block Size Comparison (256MB) ===${NC}"
SIZES=(64K 128K 256K 512K 1M)
for size in "${SIZES[@]}"; do
    printf "%-6s write: " "$size"
    dd if=/dev/zero of="$TESTDIR/test_$size.dat" bs=$size count=$COUNT_SMALL oflag=direct 2>&1 | extract_speed
    rm -f "$TESTDIR/test_$size.dat"
done
echo ""

echo -e "${GREEN}=== Large File Test (2GB) ===${NC}"
echo -n "Write (2GB, 256K): "
dd if=/dev/zero of="$TESTDIR/large_test.dat" bs=$OPTIMAL_BS count=$COUNT_LARGE oflag=direct 2>&1 | extract_speed
echo -n "Read (2GB, 256K):  "
dd if="$TESTDIR/large_test.dat" of=/dev/null bs=$OPTIMAL_BS count=$COUNT_LARGE iflag=direct 2>&1 | extract_speed
rm -f "$TESTDIR/large_test.dat"
echo ""

echo -e "${GREEN}=== I/O Mode Comparison (256MB) ===${NC}"
echo -n "Buffered:      "
dd if=/dev/zero of="$TESTDIR/buffered.dat" bs=$OPTIMAL_BS count=$COUNT_SMALL 2>&1 | extract_speed
rm -f "$TESTDIR/buffered.dat"

echo -n "Direct I/O:    "
dd if=/dev/zero of="$TESTDIR/direct.dat" bs=$OPTIMAL_BS count=$COUNT_SMALL oflag=direct 2>&1 | extract_speed
rm -f "$TESTDIR/direct.dat"

echo -n "Sync:          "
dd if=/dev/zero of="$TESTDIR/sync.dat" bs=$OPTIMAL_BS count=$COUNT_SMALL oflag=sync 2>&1 | extract_speed
rm -f "$TESTDIR/sync.dat"
echo ""

echo -e "${GREEN}=== Small File Operations ===${NC}"
echo -n "Creating 1000 files: "
time bash -c "mkdir -p $TESTDIR/smallfiles && for i in {1..1000}; do echo test > $TESTDIR/smallfiles/file\$i.txt; done" 2>&1 | grep real | awk '{print $2}'
echo -n "Reading 1000 files:  "
time bash -c "for i in {1..1000}; do cat $TESTDIR/smallfiles/file\$i.txt > /dev/null; done" 2>&1 | grep real | awk '{print $2}'
rm -rf "$TESTDIR/smallfiles"
echo ""

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}Benchmark Complete${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo -e "${YELLOW}Recommendations:${NC}"
echo "1. Use 256K block size for optimal performance"
echo "2. Use oflag=direct or oflag=sync for reliable writes"
echo "3. Avoid parallel writes (single stream is faster)"
echo "4. Store active development in /home for best speed"
echo ""
echo -e "${GREEN}Expected Performance (baseline → optimized):${NC}"
echo "  Write: 382 MB/s → 654 MB/s (+71%)"
echo "  Read:  ~400 MB/s → 796 MB/s (+99%)"
echo ""
