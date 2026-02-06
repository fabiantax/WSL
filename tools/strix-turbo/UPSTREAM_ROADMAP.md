# Upstream Contribution Roadmap
## Native AMD Strix Halo Support in WSL2 and ROCm

### Executive Summary

This document outlines our strategy for contributing upstream to make WSL2 and ROCm natively support AMD Strix Halo (Ryzen AI Max+ 395) without workarounds.

**Reality Check:**

| Component | Can We Contribute? | Owner | Timeline |
|-----------|-------------------|-------|----------|
| WSL2 userspace | ✅ Yes | Microsoft (open source) | 1-3 months |
| ROCm libraries | ✅ Yes | AMD (open source) | 3-6 months |
| Linux kernel (Zen 5) | ✅ Yes | Linux Foundation | 6-12 months |
| GPU-PV protocol | ❌ No | Microsoft (closed) | N/A |
| NPU in WSL2 | ❌ No | Architecture limitation | N/A |
| AMD drivers | ❌ No | AMD (proprietary) | N/A |

---

## Phase 1: WSL2 Contributions (Months 1-3)

### 1.1 Plugin Architecture PR

**Target:** microsoft/WSL

Our plugin architecture enables SOTA optimizations without breaking compatibility.

```
PR #1: Core Capability Detection
├── WslPluginCapabilities.h (CPUID detection, tier system)
├── Safe addition, no behavior change
└── Enables future plugin PRs

PR #2: Plugin Host Infrastructure
├── Plugin discovery, loading, fallback chains
├── Health monitoring
└── Foundation for all other plugins

PR #3: Stock Plugins as Reference
├── Wrap existing code in plugin interface
├── Refactoring only, no new features
└── Proves plugin system works
```

**Files to submit:**
- `tools/strix-turbo/plugin-architecture/include/WslPluginCapabilities.h`
- `tools/strix-turbo/plugin-architecture/include/WslPluginHost.h`
- Related implementation files

**Prerequisites:**
1. Sign Microsoft CLA
2. File issue explaining plugin architecture benefits
3. Build WSL locally and test
4. Ensure no regression in existing functionality

### 1.2 Performance Improvements

**Target:** microsoft/WSL

```
PR #4: Metadata Caching Enhancement
├── Improve file attribute caching in Plan9 client
├── Reduces round-trips to Windows
└── Benefits all users, not just AMD

PR #5: io_uring Integration
├── Batch syscalls in init daemon
├── Significant performance improvement
└── Already used in modern Linux distros

PR #6: AVX2 Path Parsing (Broad Compatibility)
├── SIMD-optimized path operations
├── AVX2 available on 10-year-old CPUs
└── Safe default, no fallback needed
```

### 1.3 WSL Issues to File/Track

| Issue | Description | Priority |
|-------|-------------|----------|
| New | Request: Plugin architecture for performance extensions | High |
| New | Request: io_uring in init daemon | High |
| #13460 | WSLg fails on AMD Radeon (dxgkrnl) | Track |
| #13370 | WSL 2.5.10 broke GPU acceleration | Track |

---

## Phase 2: ROCm Contributions (Months 3-6)

### 2.1 gfx1151 (Strix Halo) Support

**Target:** Multiple ROCm repositories

```
ROCm/rocBLAS:
├── Add gfx1151 to supported architectures
├── Add tuning parameters for Strix Halo
└── Test with existing test suite

ROCm/hipBLASLt:
├── Issue #5643 - Currently unsupported
├── Add gfx1151 kernels
└── Port from similar RDNA 3.5 architectures

ROCm/ROCR-Runtime:
├── Fix memory access faults (#5824)
├── Improve WSL2 detection
└── Version compatibility checks
```

### 2.2 TheRock Build System

**Target:** ROCm/TheRock (new unified build)

```
Contributions:
├── WSL2 build configuration
├── Cross-compilation improvements
├── gfx1151 build targets
└── Documentation for Strix Halo
```

AMD is actively welcoming contributors to TheRock. This is the easiest entry point.

### 2.3 ROCm Issues to File/Track

| Issue | Description | Action |
|-------|-------------|--------|
| #4952 | WSL2 support for Ryzen AI Max+ 395 | Comment with our findings |
| #5824 | Memory access faults on gfx1151 | Provide repro steps |
| #5534 | ROCm crashes on Strix Halo (fixed in 7.2) | Verify fix |
| #5643 | hipBLASLt unsupported on gfx1151 | Offer to contribute |
| #5750 | Stuck at low power/idle clocks | Track |
| New | TheRock WSL2 build support | File and contribute |

---

## Phase 3: Linux Kernel Contributions (Months 6-12)

### 3.1 Zen 5 Scheduler Tuning

**Target:** Linux kernel (LKML)

```
Patches:
├── Zen 5 topology detection improvements
├── CCD/CCX awareness for scheduler
├── Power management hints
└── AVX-512 workload balancing
```

**Process:**
1. Subscribe to linux-kernel mailing list
2. Study existing AMD scheduler patches
3. Test on Strix Halo hardware
4. Submit to LKML with performance data
5. Address maintainer feedback
6. Wait for merge into mainline
7. Eventually WSL2 kernel picks up changes

### 3.2 AMDXDNA Driver Improvements

**Target:** amd/xdna-driver → mainline Linux

```
Contributions:
├── Strix Halo NPU fixes
├── Performance optimizations
├── Documentation improvements
└── Test coverage
```

**Note:** These improvements help native Linux. They do NOT help WSL2 because NPU cannot be virtualized.

---

## Phase 4: Advocacy & Community (Ongoing)

### 4.1 Microsoft Feature Requests

File issues requesting architectural changes:

| Request | Rationale |
|---------|-----------|
| NPU paravirtualization (like GPU-PV) | Enable NPU access in WSL2 |
| GPU-PV performance improvements | Current overhead is 2x |
| VirtIO-FS with DAX | Zero-copy file access |
| dxgkrnl AMD improvements | Better AMD GPU support |

### 4.2 AMD Feature Requests

| Request | Rationale |
|---------|-----------|
| ROCm WSL2 version synchronization | Current mismatch breaks updates |
| gfx1151 official support | Strix Halo is enterprise-class |
| DirectML NPU support | Alternative to native drivers |

### 4.3 Community Building

```
Actions:
├── Blog posts about Strix-Turbo optimizations
├── Conference talks (WSLConf, AMD events)
├── GitHub discussions engagement
├── Help others with similar hardware
└── Document workarounds until upstream fixes land
```

---

## What We Cannot Fix Upstream

These require AMD/Microsoft internal work:

### GPU-PV Performance (Microsoft + AMD)

```
Problem: GPU virtualization overhead is ~2x
Cause: Translation between WDDM and Linux DRM
Fix: Would require rewriting closed-source components
Status: Only Microsoft/AMD can address this
```

### NPU in WSL2 (Microsoft + AMD)

```
Problem: No NPU access in WSL2
Cause: No paravirtualization protocol for NPUs
Fix: Would need new GPU-PV-like protocol
Status: No indication either company is working on this
Our Workaround: Windows-side NPU bridge (npu_bridge_windows.py)
```

### ROCm/Adrenalin Version Mismatch (AMD)

```
Problem: ROCm version must match Windows Adrenalin driver
Cause: Shared GPU firmware/microcode
Fix: AMD must synchronize releases
Status: Ongoing issue, no resolution announced
```

---

## Contribution Checklist

### Before Starting

- [ ] Join relevant mailing lists (LKML, ROCm Discord)
- [ ] Sign Microsoft CLA
- [ ] Read CONTRIBUTING.md for each project
- [ ] Set up local build environments
- [ ] Identify mentors in each community

### For Each PR

- [ ] File issue first, discuss approach
- [ ] Follow coding style (clang-format, checkpatch.pl)
- [ ] Include tests
- [ ] Provide performance data
- [ ] Document changes
- [ ] Address review feedback promptly

### Tracking Progress

Create GitHub project board with columns:
- Backlog
- Ready to Submit
- In Review
- Needs Changes
- Merged
- Blocked (external dependency)

---

## Timeline

```
Month 1:
├── Sign CLAs, set up environments
├── File plugin architecture issue in microsoft/WSL
├── Comment on existing ROCm issues with Strix Halo data

Month 2-3:
├── Submit plugin architecture PR #1 (capability detection)
├── Submit TheRock WSL2 build PR
├── Track review feedback

Month 4-6:
├── Submit plugin PRs #2-3
├── Submit rocBLAS gfx1151 support
├── Engage with ROCm maintainers

Month 6-12:
├── Linux kernel scheduler patches
├── Continue plugin architecture PRs
├── Advocacy for NPU virtualization

Ongoing:
├── Maintain out-of-tree optimizations (Strix-Turbo)
├── Update as upstream changes land
├── Help community members
```

---

## Success Metrics

| Metric | Target | Timeline |
|--------|--------|----------|
| Plugin architecture accepted | PR merged | 6 months |
| gfx1151 in ROCm supported list | Official support | 12 months |
| WSL2 io_uring integration | PR merged | 12 months |
| Community adoption of Strix-Turbo | 100+ GitHub stars | 6 months |
| NPU virtualization announced | Microsoft/AMD roadmap | Unknown |

---

## Files in This Repository

| File | Purpose | Upstream Target |
|------|---------|-----------------|
| `plugin-architecture/` | Plugin system design | microsoft/WSL |
| `simd_path_utils.h` | AVX-512 path parsing | microsoft/WSL |
| `uring_batch.h` | io_uring framework | microsoft/WSL |
| `kconfig-zen5.fragment` | Kernel config | Linux/WSL2-Kernel |
| `npu_prefetcher.py` | ML prefetching | Out-of-tree |
| `spdk_integration.h` | User-space NVMe | Out-of-tree |

---

## Conclusion

**Realistic expectations:**

1. **WSL2 userspace improvements:** High chance of acceptance (1-6 months)
2. **ROCm gfx1151 support:** Medium chance, depends on AMD prioritization
3. **Kernel improvements:** Long path but achievable (6-12 months)
4. **GPU-PV/NPU virtualization:** Cannot contribute, must advocate

**Our strategy:**
- Contribute what we can upstream
- Maintain out-of-tree optimizations for bleeding-edge features
- Use plugin architecture to bridge the gap
- Advocate loudly for architectural improvements

The plugin architecture we designed is specifically built to enable this dual approach: upstream-safe defaults with opt-in aggressive optimizations.

---

*Last updated: 2026-02-01*
*Branch: claude/optimize-wsl2-performance-IZSfc*
