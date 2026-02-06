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

### VirtioFS Performance Optimization

**CRITICAL**: Always use **64K block size** for optimal VirtioFS performance:

```bash
# WRONG: 1M blocks = 194 MB/s
dd if=/mnt/c/file of=/dev/null bs=1M

# CORRECT: 64K blocks = 429 MB/s (2.2x faster)
dd if=/mnt/c/file of=/dev/null bs=64K
rsync --block-size=65536 /mnt/c/src /home/user/
```

**Root Cause**: VirtioFS lacks DAX (Direct Access) capability in Windows WSL2, causing FUSE protocol overhead. Block size 64K minimizes round-trips while avoiding IOPS bottleneck.

**Performance Summary**:
- Sequential read (64K): 429 MB/s
- Sequential read (1M): 194 MB/s (55% slower)
- Sequential read (4K): 31.8 MB/s (IOPS-limited)
- Native Linux tmpfs: 6.6 GB/s (15x faster than VirtioFS)

See `docs/VIRTIOFS_READ_INVESTIGATION.md` for detailed analysis.

### Known Limitations
- WSL2 GPU passthrough for gfx1151 requires Windows Adrenalin driver with WSL2 support
- Microsoft's WSL2 kernel is behind mainline; `build-zen5-kernel.sh` provides Zen 5 CPU optimizations but GPU support depends on driver updates
- ROCm official gfx1151 support expected first half of 2026
- **VirtioFS DAX disabled**: Windows host doesn't expose DAX capability, limiting performance to ~400 MB/s vs 2+ GB/s with DAX

### Fixing Kernel GPU Support (Advanced)
To get full gfx1151 AMDGPU support before Microsoft updates their kernel:
```bash
# Build mainline kernel with dxgkrnl patches + gfx1151 AMDGPU
./tools/strix-turbo/build-mainline-wsl2-kernel.sh

# This builds Linux 6.12+ with:
# - Microsoft's dxgkrnl for GPU passthrough
# - Full AMDGPU driver with gfx1151 support
# - Zen 5 CPU optimizations
```
Note: Still requires Windows Adrenalin driver with WSL2 gfx1151 passthrough support.

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

---

# Claude Code Configuration - Claude Flow V3

## Behavioral Rules (Always Enforced - Claude Flow)

- Do what has been asked; nothing more, nothing less
- NEVER create files unless they're absolutely necessary for achieving your goal
- ALWAYS prefer editing an existing file to creating a new one
- NEVER proactively create documentation files (*.md) or README files unless explicitly requested
- NEVER save working files, text/mds, or tests to the root folder
- Never continuously check status after spawning a swarm — wait for results
- ALWAYS read a file before editing it
- NEVER commit secrets, credentials, or .env files

## File Organization (Claude Flow)

- NEVER save to root folder — use the directories below
- Use `/src` for source code files
- Use `/tests` for test files
- Use `/docs` for documentation and markdown files
- Use `/config` for configuration files
- Use `/scripts` for utility scripts
- Use `/examples` for example code

## Project Architecture (Claude Flow)

- Follow Domain-Driven Design with bounded contexts
- Keep files under 500 lines
- Use typed interfaces for all public APIs
- Prefer TDD London School (mock-first) for new code
- Use event sourcing for state changes
- Ensure input validation at system boundaries

### Project Config

- **Topology**: hierarchical-mesh
- **Max Agents**: 15
- **Memory**: hybrid
- **HNSW**: Enabled
- **Neural**: Enabled

## Security Rules (Claude Flow)

- NEVER hardcode API keys, secrets, or credentials in source files
- NEVER commit .env files or any file containing secrets
- Always validate user input at system boundaries
- Always sanitize file paths to prevent directory traversal
- Run `npx @claude-flow/cli@latest security scan` after security-related changes

## Concurrency: 1 MESSAGE = ALL RELATED OPERATIONS

- All operations MUST be concurrent/parallel in a single message
- Use Claude Code's Task tool for spawning agents, not just MCP
- ALWAYS batch ALL todos in ONE TodoWrite call (5-10+ minimum)
- ALWAYS spawn ALL agents in ONE message with full instructions via Task tool
- ALWAYS batch ALL file reads/writes/edits in ONE message
- ALWAYS batch ALL Bash commands in ONE message

## Swarm Orchestration

- MUST initialize the swarm using CLI tools when starting complex tasks
- MUST spawn concurrent agents using Claude Code's Task tool
- Never use CLI tools alone for execution — Task tool agents do the actual work
- MUST call CLI tools AND Task tool in ONE message for complex work

### 3-Tier Model Routing (ADR-026)

| Tier | Handler | Latency | Cost | Use Cases |
|------|---------|---------|------|-----------|
| **1** | Agent Booster (WASM) | <1ms | $0 | Simple transforms (var→const, add types) — Skip LLM |
| **2** | Haiku | ~500ms | $0.0002 | Simple tasks, low complexity (<30%) |
| **3** | Sonnet/Opus | 2-5s | $0.003-0.015 | Complex reasoning, architecture, security (>30%) |

- Always check for `[AGENT_BOOSTER_AVAILABLE]` or `[TASK_MODEL_RECOMMENDATION]` before spawning agents
- Use Edit tool directly when `[AGENT_BOOSTER_AVAILABLE]`

## Swarm Configuration & Anti-Drift

- ALWAYS use hierarchical topology for coding swarms
- Keep maxAgents at 6-8 for tight coordination
- Use specialized strategy for clear role boundaries
- Use `raft` consensus for hive-mind (leader maintains authoritative state)
- Run frequent checkpoints via `post-task` hooks
- Keep shared memory namespace for all agents

- Claude Code's Task tool handles ALL execution: agents, file ops, code generation, git
- CLI tools handle coordination via Bash: swarm init, memory, hooks, routing
- NEVER use CLI tools as a substitute for Task tool agents

## Support

- Claude Flow Documentation: https://github.com/ruvnet/claude-flow
- Claude Flow Issues: https://github.com/ruvnet/claude-flow/issues
