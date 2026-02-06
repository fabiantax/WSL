#!/bin/bash
# WSL2 Performance Monitor - Detects slow /mnt/* access patterns
# Warns users when processes are hitting the 9p performance penalty

set -euo pipefail

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurable thresholds
WARN_THRESHOLD_MB=10      # Warn if >10MB read/written to /mnt/*
POLL_INTERVAL=2           # Check every 2 seconds
SHOW_SUGGESTIONS=true     # Show fix suggestions

# Track cumulative I/O per process
declare -A PROC_IO_WARN

log_warn() {
    echo -e "${YELLOW}⚠ PERF${NC} $1"
}

log_error() {
    echo -e "${RED}✗ SLOW${NC} $1"
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

# Check if path is on slow filesystem
is_slow_path() {
    local path="$1"
    case "$path" in
        /mnt/[a-z]/*|/mnt/[A-Z]/*|/mnt/wsl/*|/mnt/wslg/*)
            return 0  # Slow
            ;;
        *)
            return 1  # Fast
            ;;
    esac
}

# Get the mount type for a path
get_mount_type() {
    local path="$1"
    df -T "$path" 2>/dev/null | tail -1 | awk '{print $2}'
}

# Find processes with open files on /mnt/*
check_open_files() {
    local found_slow=false

    # Use lsof to find open files (requires lsof installed)
    if ! command -v lsof &>/dev/null; then
        return
    fi

    # Get processes with files open on /mnt
    lsof +D /mnt 2>/dev/null | tail -n +2 | while read -r line; do
        local proc=$(echo "$line" | awk '{print $1}')
        local pid=$(echo "$line" | awk '{print $2}')
        local file=$(echo "$line" | awk '{print $9}')

        if [[ -n "$file" ]] && is_slow_path "$file"; then
            log_warn "$proc (PID $pid) has open file on slow path: $file"
            found_slow=true
        fi
    done

    $found_slow
}

# Check current working directories of shells
check_shell_cwds() {
    local found_slow=false

    for pid in $(pgrep -x "bash|zsh|fish|sh" 2>/dev/null); do
        local cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null || echo "")
        if [[ -n "$cwd" ]] && is_slow_path "$cwd"; then
            local cmd=$(ps -p $pid -o comm= 2>/dev/null || echo "shell")
            log_warn "$cmd (PID $pid) working directory is on slow path: $cwd"
            found_slow=true
        fi
    done

    $found_slow && return 0 || return 1
}

# Check for common offenders
check_common_patterns() {
    local issues=()

    # Check if node_modules exists on /mnt/c
    if [[ -d "/mnt/c/Users" ]]; then
        local nm_count=$(find /mnt/c/Users -maxdepth 5 -type d -name "node_modules" 2>/dev/null | head -5 | wc -l)
        if [[ $nm_count -gt 0 ]]; then
            issues+=("Found node_modules on /mnt/c - npm/yarn will be slow")
        fi
    fi

    # Check if .git repos exist on /mnt/c that are being accessed
    if pgrep -x git &>/dev/null; then
        local git_cwd=$(readlink -f /proc/$(pgrep -x git | head -1)/cwd 2>/dev/null || echo "")
        if is_slow_path "$git_cwd"; then
            issues+=("git running on /mnt/* path - 10-100x slower than Linux FS")
        fi
    fi

    # Check for active compilation on /mnt/*
    for compiler in gcc g++ clang cc make ninja cmake; do
        if pgrep -x "$compiler" &>/dev/null; then
            local comp_cwd=$(readlink -f /proc/$(pgrep -x "$compiler" | head -1)/cwd 2>/dev/null || echo "")
            if is_slow_path "$comp_cwd"; then
                issues+=("$compiler running on /mnt/* - builds will be very slow")
            fi
        fi
    done

    for issue in "${issues[@]:-}"; do
        [[ -n "$issue" ]] && log_error "$issue"
    done

    [[ ${#issues[@]} -gt 0 ]]
}

# Suggest fixes
suggest_fixes() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Performance Suggestions${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Move project to Linux filesystem:"
    echo "     ${GREEN}cp -r /mnt/c/project ~/project${NC}"
    echo ""
    echo "  2. Use symlink for easy Windows access:"
    echo "     ${GREEN}ln -s ~/project /mnt/c/Users/\$USER/project-fast${NC}"
    echo ""
    echo "  3. Clone repos directly to Linux FS:"
    echo "     ${GREEN}cd ~ && git clone <url>${NC}"
    echo ""
    echo "  4. For existing projects, use VS Code Remote-WSL:"
    echo "     ${GREEN}code --remote wsl+Ubuntu ~/project${NC}"
    echo ""
    echo "  5. If you MUST use /mnt/c, use 64K blocks:"
    echo "     ${GREEN}dd bs=64K ...  # 2.2x faster than default${NC}"
    echo ""
}

# Real-time I/O monitoring using /proc
monitor_io() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  WSL2 Performance Monitor - Detecting slow /mnt/* access${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Monitoring for processes accessing Windows filesystems..."
    echo "Press Ctrl+C to stop"
    echo ""

    while true; do
        local found_issues=false

        # Check shell working directories
        if check_shell_cwds 2>/dev/null; then
            found_issues=true
        fi

        # Check common slow patterns
        if check_common_patterns 2>/dev/null; then
            found_issues=true
        fi

        # If issues found and suggestions enabled, show once
        if $found_issues && $SHOW_SUGGESTIONS; then
            suggest_fixes
            SHOW_SUGGESTIONS=false  # Only show once
        fi

        sleep "$POLL_INTERVAL"
    done
}

# One-time scan
scan_once() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  WSL2 Performance Scan${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local issues_found=false

    # Check current shell
    if is_slow_path "$PWD"; then
        log_error "Current directory is on slow path: $PWD"
        issues_found=true
    else
        log_ok "Current directory is on fast path: $PWD"
    fi

    # Check shell working directories
    echo ""
    echo "Checking active shells..."
    if check_shell_cwds; then
        issues_found=true
    else
        log_ok "No shells working on /mnt/* paths"
    fi

    # Check common patterns
    echo ""
    echo "Checking for common slow patterns..."
    if check_common_patterns; then
        issues_found=true
    else
        log_ok "No obvious slow patterns detected"
    fi

    # Check open files (if lsof available)
    if command -v lsof &>/dev/null; then
        echo ""
        echo "Checking open files on /mnt/*..."
        if check_open_files; then
            issues_found=true
        else
            log_ok "No processes with open files on /mnt/*"
        fi
    fi

    if $issues_found; then
        suggest_fixes
        return 1
    else
        echo ""
        log_ok "No performance issues detected!"
        echo ""
        return 0
    fi
}

# Project migration helper
migrate_project() {
    local src="$1"
    local name=$(basename "$src")
    local dest="$HOME/$name"

    if [[ ! -d "$src" ]]; then
        log_error "Source directory not found: $src"
        return 1
    fi

    if [[ -e "$dest" ]]; then
        log_error "Destination already exists: $dest"
        return 1
    fi

    echo "Migrating $src -> $dest"
    echo ""

    # Copy with progress
    rsync -ah --progress "$src/" "$dest/"

    # Create symlink back to Windows for easy access
    local win_link="/mnt/c/Users/$USER/$(basename "$dest")-linux"
    if [[ ! -e "$win_link" ]]; then
        ln -s "$dest" "$win_link" 2>/dev/null || true
        log_info "Created Windows symlink: $win_link"
    fi

    log_ok "Migration complete!"
    echo ""
    echo "Your project is now at: ${GREEN}$dest${NC}"
    echo "Access from Windows via: ${GREEN}\\\\wsl\$\\Ubuntu$dest${NC}"
    echo ""
    echo "Next steps:"
    echo "  cd $dest"
    echo "  code ."
}

# Usage
usage() {
    echo "WSL2 Performance Monitor"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  scan      One-time performance scan (default)"
    echo "  monitor   Continuous monitoring mode"
    echo "  migrate   Migrate a project from /mnt/c to Linux FS"
    echo "  help      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 scan"
    echo "  $0 monitor"
    echo "  $0 migrate /mnt/c/Users/me/myproject"
}

# Main
case "${1:-scan}" in
    scan)
        scan_once
        ;;
    monitor)
        monitor_io
        ;;
    migrate)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 migrate /mnt/c/path/to/project"
            exit 1
        fi
        migrate_project "$2"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
