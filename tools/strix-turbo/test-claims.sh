#!/bin/bash
# Direct test of performance claims
# Quick spot checks only

echo "=== TESTING PERFORMANCE CLAIMS ==="
echo ""
echo "System: $(uname -r)"
echo "Mount: $(mount | grep '/mnt/c' | awk '{print $5}')"
echo ""

TEST_DIR="/mnt/c/temp/claim-test"
mkdir -p "$TEST_DIR"

# Create small test file
echo "Creating 128MB test file..."
dd if=/dev/zero of="$TEST_DIR/test128mb.dat" bs=1M count=128 conv=fsync 2>/dev/null
echo ""

# Test claim: 256K blocks give 668-787 MB/s
echo "=== CLAIM 1: 256K blocks optimal (668-787 MB/s) ==="
echo ""

# Test 64K (previous optimal)
echo "Testing 64K blocks (previous optimal):"
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
write_64k=$(dd if=/dev/zero of="$TEST_DIR/test128mb.dat" bs=64K count=2048 conv=fsync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
read_64k=$(dd if="$TEST_DIR/test128mb.dat" of=/dev/null bs=64K 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
echo "  Write: $write_64k"
echo "  Read:  $read_64k"
echo ""

# Test 256K (claimed optimal)
echo "Testing 256K blocks (claimed optimal):"
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
write_256k=$(dd if=/dev/zero of="$TEST_DIR/test128mb.dat" bs=256K count=512 conv=fsync 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1
read_256k=$(dd if="$TEST_DIR/test128mb.dat" of=/dev/null bs=256K 2>&1 | grep -oP '\d+(\.\d+)? MB/s' | tail -1)
echo "  Write: $write_256k"
echo "  Read:  $read_256k"
echo ""

echo "=== COMPARISON ==="
echo "64K:  Write=$write_64k, Read=$read_64k"
echo "256K: Write=$write_256k, Read=$read_256k"
echo ""

# Extract numeric values
write_64k_val=$(echo "$write_64k" | grep -oP '^\d+(\.\d+)?')
write_256k_val=$(echo "$write_256k" | grep -oP '^\d+(\.\d+)?')
read_64k_val=$(echo "$read_64k" | grep -oP '^\d+(\.\d+)?')
read_256k_val=$(echo "$read_256k" | grep -oP '^\d+(\.\d+)?')

# Check if 256K is actually better
if [ $(echo "$write_256k_val > $write_64k_val" | bc -l 2>/dev/null) -eq 1 ]; then
    echo "✅ 256K write IS faster than 64K"
else
    echo "❌ 256K write is NOT faster than 64K"
fi

if [ $(echo "$read_256k_val > $read_64k_val" | bc -l 2>/dev/null) -eq 1 ]; then
    echo "✅ 256K read IS faster than 64K"
else
    echo "❌ 256K read is NOT faster than 64K"
fi

# Check if we hit claimed targets
if [ $(echo "$write_256k_val >= 668" | bc -l 2>/dev/null) -eq 1 ]; then
    echo "✅ 256K write meets claim (≥668 MB/s)"
else
    echo "❌ 256K write below claim: $write_256k vs 668 MB/s target"
fi

if [ $(echo "$read_256k_val >= 787" | bc -l 2>/dev/null) -eq 1 ]; then
    echo "✅ 256K read meets claim (≥787 MB/s)"
else
    echo "❌ 256K read below claim: $read_256k vs 787 MB/s target"
fi

echo ""

# Test claim 2: Parasitic batching works
echo "=== CLAIM 2: Parasitic batching (10-64 ops/batch) ==="
echo ""

BATCH_LIB="parasitic_batch/libparasitic_batch.so"
if [ -f "$BATCH_LIB" ]; then
    echo "Testing with STRIX_BATCH_SIZE=32..."
    output=$(STRIX_BATCH_DEBUG=1 STRIX_BATCH_SIZE=32 \
        LD_PRELOAD=./$BATCH_LIB \
        bash -c 'for i in {1..10}; do cat /etc/hosts > /dev/null 2>&1; done' 2>&1 | grep -i "batch" | head -3)

    if [ -n "$output" ]; then
        echo "$output"
        # Check if batch sizes are in range
        if echo "$output" | grep -qE "batch.*([1-9][0-9]|[1-5][0-9]|6[0-4])"; then
            echo "✅ Batching appears to be working (10-64 range)"
        else
            echo "⚠ Batching output found but may not be in expected range"
        fi
    else
        echo "❌ No batch debug output detected"
    fi
else
    echo "❌ Parasitic batch library not found at: $BATCH_LIB"
fi

echo ""

# Cleanup
rm -rf "$TEST_DIR"

echo "=== QUICK VALIDATION COMPLETE ==="
echo ""
echo "Summary:"
echo "- Block size tests completed"
echo "- Parasitic batching checked"
echo "- Review results above for validation status"
