#!/usr/bin/env bash
# build-kernel.sh
#
# Builds a custom WSL2 kernel with AMD GPU (ROCm) + Docker support,
# tuned for Zen 5 / Strix Halo (AMD Ryzen AI 395 Pro / HX 395).
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt update && sudo apt install -y \
#       build-essential flex bison libssl-dev libelf-dev bc pahole \
#       dwarves python3 cpio zstd
#
# Usage:
#   ./tools/build-kernel.sh [--kernel-src <path>] [--output <path>]
#
# Defaults:
#   --kernel-src  ~/WSL2-Linux-Kernel   (cloned from microsoft/WSL2-Linux-Kernel)
#   --output      ~/wsl2-custom-kernel
#
# After a successful build, point WSL at the new kernel via ~/.wslconfig:
#   [wsl2]
#   kernel=C:\\Users\\<You>\\wsl2-custom-kernel\\arch\\x86\\boot\\bzImage
#
# Then restart WSL: wsl --shutdown && wsl

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KERNEL_SRC="${HOME}/WSL2-Linux-Kernel"
OUTPUT_DIR="${HOME}/wsl2-custom-kernel"
FRAGMENT="$(dirname "$(realpath "$0")")/../kernel/config-fragment-amd-docker"
JOBS=$(nproc)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-src)  KERNEL_SRC="$2";  shift 2 ;;
        --output)      OUTPUT_DIR="$2";  shift 2 ;;
        --jobs|-j)     JOBS="$2";        shift 2 ;;
        --help|-h)
            sed -n '/^# /s/^# \?//p' "$0" | head -30
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -d "${KERNEL_SRC}" ]]; then
    echo "ERROR: Kernel source not found at '${KERNEL_SRC}'."
    echo "Clone it first:"
    echo "  git clone https://github.com/microsoft/WSL2-Linux-Kernel.git ${KERNEL_SRC}"
    exit 1
fi

if [[ ! -f "${FRAGMENT}" ]]; then
    echo "ERROR: Config fragment not found at '${FRAGMENT}'."
    echo "This script expects the fragment at kernel/config-fragment-amd-docker"
    echo "relative to the WSL repository root."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 – Start with Microsoft's shipping WSL2 config
# ---------------------------------------------------------------------------
echo "==> Step 1: Copying Microsoft base config..."
cp "${KERNEL_SRC}/Microsoft/config-wsl" "${KERNEL_SRC}/.config"

# ---------------------------------------------------------------------------
# Step 2 – Merge the AMD GPU + Docker fragment on top
#           merge_config.sh sets missing symbols to =y and leaves the rest
# ---------------------------------------------------------------------------
echo "==> Step 2: Merging AMD GPU + Docker config fragment..."
if [[ -x "${KERNEL_SRC}/scripts/kconfig/merge_config.sh" ]]; then
    cd "${KERNEL_SRC}"
    scripts/kconfig/merge_config.sh -m .config "${FRAGMENT}"
    cd - > /dev/null
else
    # Fallback: append the fragment and run olddefconfig to resolve conflicts
    echo "  (merge_config.sh not found, falling back to cat + olddefconfig)"
    grep -v '^#' "${FRAGMENT}" | grep -v '^$' >> "${KERNEL_SRC}/.config"
    make -C "${KERNEL_SRC}" olddefconfig
fi

# ---------------------------------------------------------------------------
# Step 3 – Optional interactive review
#           Uncomment the next two lines to open menuconfig before building.
# ---------------------------------------------------------------------------
# echo "==> Step 3: Opening menuconfig for review..."
# make -C "${KERNEL_SRC}" menuconfig

# ---------------------------------------------------------------------------
# Step 4 – Compile
# ---------------------------------------------------------------------------
echo "==> Step 4: Compiling kernel with ${JOBS} jobs..."
make -C "${KERNEL_SRC}" -j"${JOBS}" LOCALVERSION="-wsl2-amd-docker"

# ---------------------------------------------------------------------------
# Step 5 – Copy output artifacts
# ---------------------------------------------------------------------------
echo "==> Step 5: Copying build artifacts to ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
cp "${KERNEL_SRC}/arch/x86/boot/bzImage" "${OUTPUT_DIR}/bzImage"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Build complete."
echo ""
echo "  Kernel image : ${OUTPUT_DIR}/bzImage"
echo ""
echo "To use this kernel, add the following to %USERPROFILE%\\.wslconfig on Windows:"
echo ""
echo "  [wsl2]"

# Convert Linux path to a Windows-style path hint
WIN_PATH=$(wslpath -w "${OUTPUT_DIR}/bzImage" 2>/dev/null || echo "C:\\\\path\\\\to\\\\bzImage")
echo "  kernel=${WIN_PATH}"
echo ""
echo "Then restart WSL:"
echo "  wsl --shutdown && wsl"
