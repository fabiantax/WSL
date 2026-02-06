# User Stories Index

**Project:** WSL2 Performance Optimization for AMD Strix Halo
**Branch:** `claude/optimize-wsl2-performance-IZSfc`
**Date:** 2026-02-06

## Story Documents

| Document | Epics | Stories | Points |
|----------|-------|---------|--------|
| [All Components](all-components.md) | 6 (VirtioFS, Benchmarks, Parasitic Batch, Incidents, Monitoring, Fixes) | 57 | 257 |
| [Shared Memory IPC](shared-memory-ipc.md) | 1 (Shared Memory IPC) | 10 | 63 |
| [WSL Perf Monitor v2](wsl-perf-monitor-v2.md) | 1 (C# Monitor Enhancements) | 4 | N/A |
| [ROCm, Plugin, IPC Infrastructure](rocm-plugin-ipc-infra.md) | 4 (ROCm, Plugin Architecture, IPC Ring Buffer, Kernel/SIMD) | 22 | 120 |
| [Strix-Turbo Core](../../tools/strix-turbo/USER-STORIES.md) | 1 (Core Suite) | 6 | N/A |
| **Total** | **13** | **99** | **440+** |

## Priority Summary (All Stories)

| Priority | Count |
|----------|-------|
| Critical | 20 |
| High | 35 |
| Medium | 32 |
| Low | 12 |

## Epics Overview

1. **VirtioFS Performance Investigation** - Root cause analysis and optimization of VirtioFS without DAX
2. **Benchmarking Suite** - Comprehensive benchmark scripts, validation, and guides
3. **Parasitic Batch Queue** - io_uring syscall batching via LD_PRELOAD
4. **Incident Response** - WSL2 service death spiral detection, response, and prevention
5. **Monitoring and Dashboard** - PowerShell GUI dashboard, tray monitors, error detection
6. **Docker/Service Fixes** - iptables fixes, systemd circuit breakers, research
7. **Shared Memory IPC** - Lock-free transport bypassing 9p protocol
8. **C# Windows Monitor** - Dark mode, zombie kill, I/O throughput, row grouping
9. **ROCm 7.2 Integration** - GPU compute for AI workloads on gfx1151
10. **Plugin Architecture** - Capability-based plugin system for upstream compatibility
11. **IPC Ring Buffer** - Lock-free SPSC ring buffer with C11 atomics
12. **Kernel and SIMD** - Zen 5 kernel builder, SIMD path utilities, decoupled architecture
13. **Strix-Turbo Core** - VirtioFS, mainline kernel, NPU bridge, quick-win scripts
