#!/bin/bash
# WSL2 Performance Hook - Add to .bashrc/.zshrc for automatic warnings
# Warns immediately when you cd into a slow /mnt/* path

# Colors
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check if current directory is slow
__wsl_perf_check() {
    case "$PWD" in
        /mnt/[a-zA-Z]/*)
            echo -e "${YELLOW}⚠ Performance warning:${NC} You're on Windows filesystem (/mnt/c)"
            echo -e "  File operations are ${RED}10-100x slower${NC} than Linux FS (~)"
            echo -e "  Consider: ${NC}cd ~ && cp -r \"$PWD\" .${NC}"
            ;;
    esac
}

# Hook into cd command
__wsl_perf_cd() {
    builtin cd "$@" && __wsl_perf_check
}

# Install hook
wsl_perf_hook_install() {
    alias cd='__wsl_perf_cd'
    echo "WSL2 performance hook installed. You'll be warned when entering /mnt/* paths."
}

# Uninstall hook
wsl_perf_hook_uninstall() {
    unalias cd 2>/dev/null
    echo "WSL2 performance hook removed."
}

# Auto-install if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Being sourced
    wsl_perf_hook_install
fi
