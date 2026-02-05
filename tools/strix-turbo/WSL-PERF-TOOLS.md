# WSL2 Performance Tools

Practical tools to help you avoid the `/mnt/c` performance trap.

## The Problem

| Filesystem | Speed | Relative |
|------------|-------|----------|
| Linux FS (`~/`) | 2-6 GB/s | **Baseline** |
| Windows FS (`/mnt/c`) | 200-400 MB/s | **10-30x slower** |

Every file operation on `/mnt/c` goes through the 9p/VirtioFS protocol — network-style overhead for local files.

## Quick Start

```bash
# One-time scan - are you working on slow paths?
./wsl-perf-monitor.sh scan

# Continuous monitoring
./wsl-perf-monitor.sh monitor

# Migrate existing project to Linux FS
./wsl-perf-monitor.sh migrate /mnt/c/Users/me/myproject

# Create new project on Linux FS (with Windows symlink)
./wsl-project-init.sh myapp node
```

## Tools

### 1. `wsl-perf-monitor.sh` - Detection & Migration

Scans for processes hitting slow paths and offers migration help.

```bash
# Scan current state
./wsl-perf-monitor.sh scan

# Output:
# ✗ SLOW git running on /mnt/* path - 10-100x slower than Linux FS
# ⚠ PERF bash (PID 1234) working directory is on slow path: /mnt/c/Users/...
#
# Performance Suggestions:
#   1. Move project to Linux filesystem:
#      cp -r /mnt/c/project ~/project
#   ...

# Migrate a project
./wsl-perf-monitor.sh migrate /mnt/c/Users/me/myproject
# Creates ~/myproject + Windows symlink
```

### 2. `wsl-perf-hook.sh` - Shell Warnings

Add to `.bashrc` or `.zshrc` for instant warnings when you `cd` into slow paths:

```bash
# Add to ~/.bashrc
source /path/to/wsl-perf-hook.sh

# Now when you cd /mnt/c/something:
# ⚠ Performance warning: You're on Windows filesystem (/mnt/c)
#   File operations are 10-100x slower than Linux FS (~)
#   Consider: cd ~ && cp -r "/mnt/c/something" .
```

### 3. `wsl-project-init.sh` - Fast Project Creation

Creates projects on Linux FS with Windows symlinks for convenience:

```bash
# Create bare project
./wsl-project-init.sh myapp

# Create with template
./wsl-project-init.sh myapp node      # package.json + index.js
./wsl-project-init.sh backend python  # venv + main.py
./wsl-project-init.sh cli rust        # Cargo.toml
./wsl-project-init.sh repo git        # .git + .gitignore

# Result:
# ✓ Project created!
#   Location: ~/projects/myapp
#   Windows:  \\wsl$\Ubuntu\home\user\projects\myapp
#   Symlink:  C:\Users\user\wsl-projects\myapp
```

## Installation

```bash
cd ~/
git clone <this-repo> wsl-tools
chmod +x wsl-tools/tools/strix-turbo/wsl-*.sh

# Add to PATH (optional)
echo 'export PATH="$PATH:~/wsl-tools/tools/strix-turbo"' >> ~/.bashrc

# Enable shell hook (optional but recommended)
echo 'source ~/wsl-tools/tools/strix-turbo/wsl-perf-hook.sh' >> ~/.bashrc
```

## Best Practices

### DO ✓

- Keep source code on Linux FS (`~/projects/`)
- Clone repos directly: `cd ~ && git clone <url>`
- Use VS Code Remote-WSL: `code --remote wsl+Ubuntu ~/project`
- Access from Windows via `\\wsl$\Ubuntu\home\...`

### DON'T ✗

- Don't develop in `/mnt/c/Users/.../`
- Don't run `npm install` on `/mnt/c`
- Don't compile code on Windows FS
- Don't use `/mnt/c` for git repos

## If You MUST Use /mnt/c

Use 64K block size for 2.2x faster reads:

```bash
# Copying files
dd if=/mnt/c/big.iso of=~/big.iso bs=64K

# rsync
rsync --block-size=65536 /mnt/c/src/ ~/src/
```

## How It Works

```
Windows (C:\)          WSL2 VM
     │                    │
     │   9p/VirtioFS      │
     │◄──────────────────►│ /mnt/c  (SLOW - network protocol)
     │                    │
     │                    │ ~/      (FAST - native ext4)
     │   \\wsl$\Ubuntu    │
     │◄──────────────────►│         (Windows accessing Linux - also slow)
```

The Linux filesystem inside WSL2 is a native ext4 — full speed. Anything crossing the VM boundary (`/mnt/c` or `\\wsl$`) goes through protocol translation.
