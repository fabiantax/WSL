#!/bin/bash
#
# Complete Kernel Performance Comparison Workflow
# This script guides you through baseline testing, kernel switching, and comparison
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$RESULTS_DIR"

echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║     Zen 5 Kernel Performance Comparison Workflow             ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check current kernel
CURRENT_KERNEL=$(uname -r)
echo -e "${BLUE}[INFO]${NC} Current kernel: ${BOLD}$CURRENT_KERNEL${NC}"
echo ""

# Check if we're on the baseline or optimized kernel
if [[ "$CURRENT_KERNEL" == *"6.8.12"* ]]; then
    KERNEL_TYPE="optimized"
    echo -e "${GREEN}✓${NC} Running on Zen 5 optimized kernel"
    BASELINE_EXISTS=false

    if [ -f "$RESULTS_DIR/baseline.json" ]; then
        BASELINE_EXISTS=true
        echo -e "${BLUE}[INFO]${NC} Baseline results found: $RESULTS_DIR/baseline.json"
    fi
else
    KERNEL_TYPE="baseline"
    echo -e "${YELLOW}⚠${NC} Running on baseline kernel (not optimized yet)"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Step selection
if [ "$KERNEL_TYPE" == "baseline" ]; then
    echo -e "${BOLD}Step 1: Establish Baseline${NC}"
    echo "This will run comprehensive benchmarks on your current kernel."
    echo ""
    read -p "Run baseline benchmarks now? [Y/n] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo -e "${BLUE}[INFO]${NC} Starting baseline benchmark suite..."
        echo -e "${YELLOW}[WARN]${NC} This will take approximately 3-5 minutes"
        echo ""

        "$SCRIPT_DIR/benchmark-zen5-kernel.sh" "$RESULTS_DIR/baseline.json"

        echo ""
        echo -e "${GREEN}✓${NC} Baseline results saved to: $RESULTS_DIR/baseline.json"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${BOLD}Next Steps:${NC}"
        echo ""
        echo "1. ${BOLD}Switch to the optimized kernel:${NC}"
        echo "   Exit WSL and run in PowerShell/CMD:"
        echo -e "   ${CYAN}wsl --shutdown${NC}"
        echo ""
        echo "2. ${BOLD}Restart WSL${NC} (it will load the new kernel automatically)"
        echo ""
        echo "3. ${BOLD}Run this script again${NC} to benchmark the optimized kernel:"
        echo -e "   ${CYAN}./run-kernel-comparison.sh${NC}"
        echo ""
    else
        echo "Benchmark cancelled."
        exit 0
    fi

elif [ "$KERNEL_TYPE" == "optimized" ]; then
    if [ "$BASELINE_EXISTS" = false ]; then
        echo -e "${RED}✗${NC} No baseline results found!"
        echo ""
        echo "You need to run baseline benchmarks first on the stock kernel."
        echo ""
        echo -e "${BOLD}To fix this:${NC}"
        echo "1. Comment out the kernel line in .wslconfig"
        echo "2. Run: wsl --shutdown"
        echo "3. Restart WSL with stock kernel"
        echo "4. Run this script to establish baseline"
        exit 1
    fi

    echo -e "${BOLD}Step 2: Benchmark Optimized Kernel${NC}"
    echo "This will run the same benchmarks on the Zen 5 optimized kernel."
    echo ""
    read -p "Run optimized kernel benchmarks now? [Y/n] " -n 1 -r
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        echo -e "${BLUE}[INFO]${NC} Starting optimized kernel benchmark suite..."
        echo -e "${YELLOW}[WARN]${NC} This will take approximately 3-5 minutes"
        echo ""

        "$SCRIPT_DIR/benchmark-zen5-kernel.sh" "$RESULTS_DIR/optimized.json"

        echo ""
        echo -e "${GREEN}✓${NC} Optimized kernel results saved to: $RESULTS_DIR/optimized.json"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${BOLD}Step 3: Compare Results${NC}"
        echo ""

        # Install jq if needed
        if ! command -v jq &> /dev/null; then
            echo -e "${YELLOW}[WARN]${NC} jq not found, installing..."
            sudo apt-get update > /dev/null 2>&1
            sudo apt-get install -y jq > /dev/null 2>&1
        fi

        # Run comparison
        chmod +x "$SCRIPT_DIR/compare-benchmarks.py"
        python3 "$SCRIPT_DIR/compare-benchmarks.py" "$RESULTS_DIR/baseline.json" "$RESULTS_DIR/optimized.json"

        echo ""
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  Benchmark Comparison Complete!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${BLUE}[INFO]${NC} Full results available at:"
        echo "  Baseline:  $RESULTS_DIR/baseline.json"
        echo "  Optimized: $RESULTS_DIR/optimized.json"
        echo ""
    else
        echo "Benchmark cancelled."
        exit 0
    fi
fi
