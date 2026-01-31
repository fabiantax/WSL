#!/bin/bash
################################################################################
# WSL2 Zen 5 Kernel Builder - Dependency Checker
#
# Checks for all required dependencies and provides installation commands
# Usage: ./check-dependencies.sh [--install]
#
################################################################################

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Required dependencies
declare -a REQUIRED_DEPS=(
    "build-essential"
    "flex"
    "bison"
    "libssl-dev"
    "libelf-dev"
    "bc"
    "git"
    "wget"
)

# Optional dependencies
declare -a OPTIONAL_DEPS=(
    "clang"
    "llvm"
    "lld"
    "linux-tools-generic"
    "sysstat"
)

AUTO_INSTALL=false

# Parse arguments
if [[ "${1:-}" == "--install" || "${1:-}" == "-i" ]]; then
    AUTO_INSTALL=true
fi

echo -e "${BLUE}"
echo "================================================================================"
echo "  WSL2 Zen 5 Kernel Builder - Dependency Checker"
echo "================================================================================"
echo -e "${NC}"

# Check Ubuntu/Debian version
if ! command -v lsb_release &> /dev/null; then
    echo -e "${YELLOW}Warning:${NC} lsb_release not found, assuming Ubuntu/Debian"
else
    OS=$(lsb_release -is)
    VERSION=$(lsb_release -rs)
    echo -e "${BLUE}System:${NC} $OS $VERSION"
fi

echo ""

# Check required dependencies
echo -e "${BLUE}Checking Required Dependencies:${NC}"
echo "================================================================================"

missing_required=0
for dep in "${REQUIRED_DEPS[@]}"; do
    if dpkg -l | grep -q "^ii.*$dep"; then
        echo -e "${GREEN}✓${NC} $dep"
    else
        echo -e "${RED}✗${NC} $dep"
        missing_required=$((missing_required + 1))
    fi
done

echo ""

# Check optional dependencies
echo -e "${BLUE}Checking Optional Dependencies:${NC}"
echo "================================================================================"

missing_optional=0
for dep in "${OPTIONAL_DEPS[@]}"; do
    if dpkg -l 2>/dev/null | grep -q "^ii.*$dep" || command -v "${dep%-*}" &> /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $dep"
    else
        echo -e "${YELLOW}○${NC} $dep (optional, for better performance)"
        missing_optional=$((missing_optional + 1))
    fi
done

echo ""
echo "================================================================================"

# Summary
if [ $missing_required -eq 0 ] && [ $missing_optional -eq 0 ]; then
    echo -e "${GREEN}✓ All dependencies are installed!${NC}"
    echo ""
    echo "You're ready to build the kernel with:"
    echo -e "${YELLOW}/home/user/WSL/tools/strix-turbo/build-zen5-kernel.sh${NC}"
    exit 0
else
    if [ $missing_required -gt 0 ]; then
        echo -e "${RED}✗ Missing $missing_required required dependency(ies)${NC}"
    fi
    if [ $missing_optional -gt 0 ]; then
        echo -e "${YELLOW}○ Missing $missing_optional optional dependency(ies)${NC}"
    fi
    echo ""

    # Installation commands
    echo -e "${BLUE}Installation Instructions:${NC}"
    echo "================================================================================"
    echo ""

    if [ $missing_required -gt 0 ]; then
        echo -e "${RED}Required dependencies:${NC}"
        echo ""
        echo "Run the following command:"
        echo ""
        echo -e "${YELLOW}sudo apt-get update && sudo apt-get install -y \${NC}"
        for dep in "${REQUIRED_DEPS[@]}"; do
            if ! dpkg -l | grep -q "^ii.*$dep"; then
                echo "  $dep \"
            fi
        done | head -c -3
        echo ""
        echo ""
    fi

    if [ $missing_optional -gt 0 ]; then
        echo -e "${BLUE}Optional dependencies (for better performance):${NC}"
        echo ""
        echo "Run the following command:"
        echo ""
        echo -e "${YELLOW}sudo apt-get install -y \${NC}"
        for dep in "${OPTIONAL_DEPS[@]}"; do
            if ! dpkg -l 2>/dev/null | grep -q "^ii.*$dep" && ! command -v "${dep%-*}" &> /dev/null 2>&1; then
                echo "  $dep \"
            fi
        done | head -c -3
        echo ""
        echo ""
    fi

    # Auto-install if requested
    if [ "$AUTO_INSTALL" = true ] && [ $missing_required -gt 0 ]; then
        echo -e "${BLUE}Installing missing required dependencies...${NC}"
        echo ""

        sudo apt-get update

        for dep in "${REQUIRED_DEPS[@]}"; do
            if ! dpkg -l | grep -q "^ii.*$dep"; then
                echo -e "${BLUE}Installing $dep...${NC}"
                sudo apt-get install -y "$dep"
            fi
        done

        echo ""
        echo -e "${GREEN}✓ Required dependencies installed!${NC}"
        echo ""

        if [ $missing_optional -gt 0 ]; then
            echo -e "${YELLOW}Optional dependencies still available for installation:${NC}"
            echo "sudo apt-get install -y clang llvm lld linux-tools-generic sysstat"
            echo ""
        fi
    fi

    exit 1
fi
