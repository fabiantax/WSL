#!/bin/bash
################################################################################
# Strix-Turbo Pre-Flight Test Suite
# Run this BEFORE building anything to catch issues early
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "════════════════════════════════════════════════════════════"
echo "  Strix-Turbo Pre-Flight Test Suite"
echo "════════════════════════════════════════════════════════════"
echo -e "${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"

    echo -e "${YELLOW}Testing: $name${NC}"
    if eval "$cmd"; then
        echo -e "${GREEN}✓ PASSED: $name${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAILED: $name${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    echo ""
}

# Test 1: Parasitic Batching
run_test "Parasitic Batching Library" "
    (cd parasitic_batch &&
     make clean &&
     make &&
     make test)
"

# Test 2: io_uring Framework
run_test "io_uring Batch Framework" "
    g++ -O2 -std=c++17 uring_batch_test.cpp uring_batch.cpp -luring -o test_uring &&
    ./test_uring &&
    rm -f test_uring
"

# Test 3: SIMD Path Utils
run_test "SIMD Path Utils (AVX-512)" "
    make -f Makefile clean &&
    make -f Makefile test
"

# Test 3b: SIMD Property-Based Tests
run_test "SIMD Property-Based Tests" "
    g++ -std=c++17 -mavx512f -mavx512bw -O3 test_simd_properties.cpp -o test_simd_properties &&
    ./test_simd_properties 500 &&
    rm -f test_simd_properties
"

# Note: Kernel dependency checks removed from test suite
# These are environment checks, not unit tests for the code
# Run manually: ./check-dependencies.sh
# Validate scripts: bash -n build-zen5-kernel.sh

# Summary
echo -e "${BLUE}"
echo "════════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All tests passed! Safe to proceed with builds.${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some tests failed. Fix issues before building.${NC}"
    exit 1
fi
