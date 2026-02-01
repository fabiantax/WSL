# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the **Windows Subsystem for Linux (WSL)** repository - the core Windows components that enable running Linux binaries natively on Windows. The current branch (`claude/optimize-wsl2-performance-IZSfc`) implements performance optimizations targeting AMD Strix Halo systems.

## Critical Build Constraints

**Full builds ONLY work on Windows** with Visual Studio and Windows SDK 26100. Do not attempt to build main WSL components on Linux.

### Windows Build (20-45 minutes, never cancel)
```powershell
cmake .
cmake --build . -- -m

# ARM64 build
cmake . -A arm64
cmake --build . -- -m
```

### Deploy and Test
```powershell
bin\<platform>\<target>\wsl.msi          # Install MSI
powershell tools\deploy\deploy-to-host.ps1  # Or use script
```

### Run Tests (30-60 minutes for full suite)
```powershell
# Always do full build first - partial builds cause test failures
cmake --build . -- -m

# Then run tests (requires admin)
bin\x64\debug\test.bat                    # All tests
bin\x64\debug\test.bat /name:*UnitTest*   # Subset
bin\x64\debug\test.bat /name:UnitTests::UnitTests::ModernInstall  # Single test

# Fast mode after first run
wsl --set-default test_distro
bin\x64\debug\test.bat /name:*UnitTest* -f
```

## Cross-Platform Tasks (Work on Linux)

### Documentation
```bash
pip install mkdocs-mermaid2-plugin mkdocs
mkdocs build -f doc/mkdocs.yml
```

### Code Formatting
```bash
clang-format --dry-run --style=file <files>   # Check
clang-format -i --style=file <files>          # Apply
```

### Validation
```bash
python3 tools/devops/validate-copyright-headers.py  # Ignore _deps/ warnings
python3 distributions/validate.py distributions/DistributionInfo.json
```

### Pre-commit Checklist
1. `clang-format --dry-run --style=file` on changed C++ files
2. `python3 tools/devops/validate-copyright-headers.py` (ignore _deps/)
3. `mkdocs build -f doc/mkdocs.yml` if documentation changed

## Architecture

### Process Model
```
Windows Host                          WSL2 VM (Linux)
├── wsl.exe (CLI)                    ├── mini_init (boot)
├── wslservice.exe (core service)    ├── init (distro init)
├── wslhost.exe (process host)       ├── gns (networking)
├── wslrelay.exe (relay)             ├── plan9 (filesystem client)
└── wslg.exe (GUI)                   └── User processes
         ↕ HvSocket ↕
```

### Key Source Directories
- `src/windows/service/` - WSL service (wslservice.exe)
- `src/windows/wsl/` - wsl.exe CLI
- `src/linux/init/` - Linux init system, GNS, Plan9 client
- `src/linux/plan9/` - Plan 9 filesystem (current /mnt/c implementation)
- `src/shared/` - Cross-platform code

### Performance Bottleneck
The Plan 9 protocol (`src/linux/plan9/`) for `/mnt/c` access is the primary performance bottleneck (~100x slower than native). The Strix-Turbo optimizations target this.

## Strix-Turbo Performance Suite

Located in `tools/strix-turbo/`:

| Component | Purpose |
|-----------|---------|
| `rocm/` | ROCm 7.2 setup for gfx1151 (llama.cpp, vLLM) |
| `parasitic_batch/` | LD_PRELOAD library for syscall batching via io_uring |
| `npu_client/` | Python/C client for AMD XDNA NPU access from WSL2 |
| `uring_batch.h/cpp` | io_uring batching framework (1000 syscalls → 1 VM exit) |
| `shared_memory_ipc.h/cpp` | Shared memory IPC to bypass 9p protocol |
| `npu_bridge_windows.py` | Windows-side NPU bridge service |
| `install-strix-turbo.ps1` | All-in-one Windows installer |
| `build-zen5-kernel.sh` | Custom WSL2 kernel with Zen 5 optimizations |

### Build Strix-Turbo Components (Linux)
```bash
# ROCm 7.2 setup for Strix Halo
./tools/strix-turbo/rocm/setup-rocm72.sh
./tools/strix-turbo/rocm/setup-llamacpp.sh
./tools/strix-turbo/rocm/setup-vllm.sh

# Parasitic batching library
cd tools/strix-turbo/parasitic_batch
make
make test

# NPU client
cd tools/strix-turbo/npu_client/python
pip install .
```

### Known Limitations
- WSL2 GPU passthrough for gfx1151 requires Windows Adrenalin driver with WSL2 support
- Microsoft's WSL2 kernel is behind mainline; `build-zen5-kernel.sh` provides Zen 5 CPU optimizations but GPU support depends on driver updates
- ROCm official gfx1151 support expected first half of 2026

## IPC Architecture

`src/ipc/` contains lock-free primitives:
- `spsc_ring_buffer.c/h` - Single-Producer/Single-Consumer ring buffer
- Cache-line aligned (64 bytes) to prevent false sharing
- C11 atomics with acquire/release semantics

## Debugging

```powershell
# ETL tracing
wpr -start diagnostics\wsl.wprp -filemode
# [reproduce issue]
wpr -stop logs.ETL

# Debug shell
wsl --debug-shell

# Collect logs
powershell diagnostics\collect-wsl-logs.ps1
```

Add to `%USERPROFILE%\.wslconfig` for debug console:
```ini
[wsl2]
debugConsole=true
```

## Key Documentation

- `doc/docs/dev-loop.md` - Build instructions
- `doc/docs/technical-documentation/plan9.md` - Plan 9 filesystem (perf bottleneck)
- `doc/docs/technical-documentation/networking.md` - Network architecture
- `tools/strix-turbo/PRIORITIZATION.md` - Performance work prioritization
- `tools/strix-turbo/ARCHITECTURE_10X.md` - 10x performance architecture
- `tools/strix-turbo/rocm/README.md` - ROCm 7.2 integration for AI workloads

## Timing Guidelines

Never cancel these operations:
- Full Windows build: 20-45 min (timeout: 60+ min)
- Full test suite: 30-60 min (timeout: 90+ min)
- Test subset: 5-15 min (timeout: 30+ min)
