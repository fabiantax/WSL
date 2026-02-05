#!/bin/bash
# WSL2 Project Initializer - Creates projects on Linux FS with Windows symlinks
# Ensures new projects start fast by default

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default project root on Linux FS
LINUX_ROOT="${WSL_PROJECT_ROOT:-$HOME/projects}"
# Windows symlink location
WIN_LINK_ROOT="/mnt/c/Users/${USER:-$LOGNAME}/wsl-projects"

usage() {
    echo "WSL2 Project Initializer"
    echo ""
    echo "Creates projects on Linux FS (fast) with Windows symlinks (convenient)"
    echo ""
    echo "Usage: $0 <project-name> [template]"
    echo ""
    echo "Templates:"
    echo "  bare       Empty directory (default)"
    echo "  node       Node.js with package.json"
    echo "  python     Python with venv"
    echo "  rust       Cargo project"
    echo "  git        Git repo with .gitignore"
    echo ""
    echo "Examples:"
    echo "  $0 myapp"
    echo "  $0 myapp node"
    echo "  $0 backend python"
    echo ""
    echo "Environment:"
    echo "  WSL_PROJECT_ROOT  Linux project root (default: ~/projects)"
}

init_bare() {
    mkdir -p "$1"
}

init_node() {
    mkdir -p "$1"
    cat > "$1/package.json" <<EOF
{
  "name": "$(basename "$1")",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "test": "echo \"No tests\" && exit 0"
  }
}
EOF
    echo "console.log('Hello from WSL2!');" > "$1/index.js"
}

init_python() {
    mkdir -p "$1"
    python3 -m venv "$1/.venv" 2>/dev/null || python -m venv "$1/.venv"
    cat > "$1/main.py" <<EOF
#!/usr/bin/env python3
"""Main entry point."""

def main():
    print("Hello from WSL2!")

if __name__ == "__main__":
    main()
EOF
    cat > "$1/requirements.txt" <<EOF
# Add dependencies here
EOF
    chmod +x "$1/main.py"
}

init_rust() {
    if command -v cargo &>/dev/null; then
        cargo new "$1"
    else
        mkdir -p "$1/src"
        cat > "$1/Cargo.toml" <<EOF
[package]
name = "$(basename "$1")"
version = "0.1.0"
edition = "2021"

[dependencies]
EOF
        cat > "$1/src/main.rs" <<EOF
fn main() {
    println!("Hello from WSL2!");
}
EOF
    fi
}

init_git() {
    mkdir -p "$1"
    git init "$1"
    cat > "$1/.gitignore" <<EOF
# Dependencies
node_modules/
.venv/
target/

# Build outputs
dist/
build/
*.o
*.exe

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
Thumbs.db

# Env
.env
.env.local
EOF
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local name="$1"
    local template="${2:-bare}"
    local project_path="$LINUX_ROOT/$name"

    # Validate name
    if [[ "$name" =~ [^a-zA-Z0-9_-] ]]; then
        echo "Error: Project name should only contain letters, numbers, dashes, hyphens"
        exit 1
    fi

    # Check if exists
    if [[ -e "$project_path" ]]; then
        echo "Error: Project already exists: $project_path"
        exit 1
    fi

    # Create Linux root if needed
    mkdir -p "$LINUX_ROOT"

    echo -e "${BLUE}Creating project:${NC} $name"
    echo -e "${BLUE}Location:${NC} $project_path"
    echo -e "${BLUE}Template:${NC} $template"
    echo ""

    # Initialize based on template
    case "$template" in
        bare)   init_bare "$project_path" ;;
        node)   init_node "$project_path" ;;
        python) init_python "$project_path" ;;
        rust)   init_rust "$project_path" ;;
        git)    init_git "$project_path" ;;
        *)
            echo "Unknown template: $template"
            usage
            exit 1
            ;;
    esac

    # Create Windows symlink directory
    mkdir -p "$WIN_LINK_ROOT" 2>/dev/null || true

    # Create symlink for Windows access
    local win_link="$WIN_LINK_ROOT/$name"
    if [[ ! -e "$win_link" ]]; then
        ln -s "$project_path" "$win_link" 2>/dev/null && \
            echo -e "${GREEN}✓${NC} Windows symlink: $win_link"
    fi

    echo ""
    echo -e "${GREEN}✓ Project created!${NC}"
    echo ""
    echo "Next steps:"
    echo -e "  ${GREEN}cd $project_path${NC}"
    echo "  code ."
    echo ""
    echo "Access from Windows:"
    echo -e "  Explorer: ${BLUE}\\\\wsl\$\\Ubuntu$project_path${NC}"
    if [[ -e "$win_link" ]]; then
        echo -e "  Symlink:  ${BLUE}C:\\Users\\$USER\\wsl-projects\\$name${NC}"
    fi
}

main "$@"
