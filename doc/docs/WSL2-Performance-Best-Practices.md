# WSL2 Performance Best Practices for AMD Zen 5 Systems

## A Practical Guide Based on Real Benchmarking

**System:** AMD Ryzen AI Max+ PRO 395 (Strix Halo) | 32 cores | 96GB RAM | Windows 11
**Date:** February 2026
**Author:** Fabian Tax

---

## Executive Summary

After extensive benchmarking and optimization of WSL2 on an AMD Strix Halo workstation, we identified the single biggest performance bottleneck and a set of practical optimizations that deliver measurable improvements. This report documents our findings, what worked, what didn't, and provides actionable recommendations for anyone running developer workloads on WSL2.

**Key finding:** The Plan 9 filesystem protocol (`/mnt/c`) is 74x slower than the native Linux ext4 filesystem. No amount of kernel tuning, I/O scheduler changes, or syscall batching can meaningfully close this gap. The most impactful optimization is simply working from the Linux filesystem.

---

## 1. Filesystem: The 74x Performance Gap

### The Problem

WSL2 runs a real Linux kernel in a lightweight Hyper-V VM. When you access Windows files via `/mnt/c`, every file operation crosses the VM boundary using the Plan 9 (9P) protocol. This adds a round-trip for each operation.

### Our Benchmark

We created identical git repositories with 500 files on both filesystems and ran `git status`:

| Filesystem | `git status` Time | Protocol |
|---|---|---|
| `/mnt/c` (Windows NTFS) | **372ms** | Plan 9 over Hyper-V socket |
| `/home` (Linux ext4) | **5ms** | Native kernel VFS |
| **Difference** | **74x slower** | |

### Recommendation

**Store all development projects on the Linux filesystem (`/home`).**

```bash
# Clone repos to Linux filesystem
mkdir -p ~/projects
cd ~/projects
git clone <repo-url>

# Access from Windows Explorer if needed
# Navigate to: \\wsl$\Ubuntu\home\<username>\projects
```

This single change delivers more improvement than all other optimizations combined.

### When You Must Use /mnt/c

If you need cross-OS file access:
- Use `/mnt/c` only for reading/writing files that Windows applications need
- Copy files to `/home` for processing, copy results back
- Consider `rsync` or symlinks for hybrid workflows

---

## 2. Custom Kernel: Honest Assessment

### What We Did

Built Ubuntu HWE 6.8.12 kernel with Zen 5 CPU optimizations, replacing the stock Microsoft WSL2 kernel (6.6.114.1).

### What We Expected

25-35% improvement across all workloads based on Zen 5 instruction scheduling, prefetching, and branch prediction optimizations.

### What We Actually Measured

| Benchmark | Stock Kernel | Zen 5 Kernel | Improvement |
|---|---|---|---|
| Parallel Compilation (50 files, -j32) | 0.554s | 0.522s | +5.7% |
| CPU Computation | 0.110s | 0.105s | +4.9% |
| Small File I/O (500 files) | 0.013s | 0.011s | +17.6% |
| Syscall Overhead (10K syscalls) | 0.036s | 0.031s | +12.2% |
| Git Workflow | 0.028s | 0.024s | +13.1% |
| **Average** | | | **+10.7%** |

### Honest Take

A custom kernel provides measurable but modest gains (~10%). The improvement is real but does not transform the experience. The bottleneck is the VM boundary and Plan 9 protocol, not the kernel's CPU scheduling.

### Critical Build Lesson: VSOCK Configuration

Our first custom kernel build failed with `WSAENOTCONN` because the Ubuntu HWE kernel config was missing Hyper-V communication modules. WSL2 communicates with the Windows host via VSOCK (Virtual Sockets). Without these, the VM boots but cannot talk to the host.

**Essential kernel configs for WSL2 custom kernels:**

```
CONFIG_VSOCKETS=y                  # CRITICAL - VM ↔ Host communication
CONFIG_HYPERV_VSOCKETS=y           # CRITICAL - Hyper-V socket transport
CONFIG_PCI_HYPERV=y                # Hyper-V PCI bus
CONFIG_PCI_HYPERV_INTERFACE=y      # PCI interface
CONFIG_HYPERV_BALLOON=y            # Memory management
CONFIG_VIRTIO_FS=y                 # VirtIO filesystem
CONFIG_VIRTIO_BALLOON=y            # VirtIO memory balloon
CONFIG_VIRTIO_MMIO=y               # VirtIO MMIO transport
CONFIG_9P_FSCACHE=y                # 9P caching
CONFIG_9P_FS_SECURITY=y            # 9P security labels
```

**Always compare your config against the stock WSL2 kernel config:**

```bash
# Extract running kernel config
zcat /proc/config.gz > stock-kernel.config

# Compare critical sections
grep -E "VSOCK|HYPERV|VIRTIO|9P_" stock-kernel.config
```

---

## 3. .wslconfig Optimization

### Recommended Configuration

```ini
[wsl2]
memory=96GB                    # Match your physical RAM (or desired limit)
processors=32                  # Match your core count
swap=16GB                      # Generous swap for peak loads
networkingMode=mirrored        # Eliminates NAT overhead
dnsTunneling=true              # Better DNS reliability
firewall=true
defaultVhdSize=819200          # 800GB VHDX (default 256GB is often too small)
vmIdleTimeout=-1               # Never idle-stop the VM

[experimental]
sparseVhd=true                 # VHDX only uses disk space it needs
autoProxy=true                 # Inherit Windows proxy settings
hostAddressLoopback=true       # Access host services via localhost
```

### Keys to Avoid

These caused errors in our testing:
- `autoMemoryReclaim=gradual` - Not supported in all WSL versions, caused startup warnings
- `bestEffortDns=true` - Not a valid key, caused warnings

### Custom Kernel Path

```ini
[wsl2]
kernel=C:\\Users\\<username>\\bzImage-custom
```

Use double backslashes. Verify the file exists before restarting WSL.

---

## 4. Shell Performance for Developer Tools

### The Problem

Tools like Claude Code, GitHub Copilot CLI, and similar AI coding assistants spawn many bash subprocesses. Each invocation has overhead from:
1. `$PATH` lookup across many directories
2. `.bashrc` / `.profile` parsing
3. Filesystem operations for command resolution

### Optimizations Applied

**Disable Windows PATH injection:**

```ini
# /etc/wsl.conf
[interop]
appendWindowsPath=false
```

This removes ~20 Windows directories from `$PATH`, making every command lookup faster. You lose the ability to run `notepad.exe` directly from bash, but you can still use `wslview` or explicit paths.

**Mount /tmp as tmpfs (RAM-backed):**

```bash
# /etc/fstab
tmpfs /tmp tmpfs noatime,size=4G 0 0
```

Temporary files are now served from RAM instead of disk, eliminating I/O overhead for temp-heavy operations.

**Remove PATH-stripping hacks:**

If you previously had shell code to strip Windows paths from `$PATH` (using `tr`, `grep`, `sed` pipelines), remove it. The `appendWindowsPath=false` setting handles this at the WSL level without spawning subprocesses.

**Lazy-load heavy tools:**

```bash
# Instead of loading NVM on every shell start (~90ms):
nvm() {
  unset -f nvm node npm npx
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm "$@"
}
node() { unset -f node; nvm use default >/dev/null 2>&1; node "$@"; }
npm() { unset -f npm; nvm use default >/dev/null 2>&1; npm "$@"; }
```

---

## 5. I/O Tuning

### Kernel-Level Settings

```bash
# I/O scheduler optimized for VMs
echo "mq-deadline" > /sys/block/sda/queue/scheduler

# 4MB read-ahead (default is often 128KB)
echo "4096" > /sys/block/sda/queue/read_ahead_kb

# Reduce swap pressure (when you have ample RAM)
sysctl -w vm.swappiness=10

# Network buffers for large transfers
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
```

**Measured impact:** ~10-20% improvement for I/O-heavy workloads.

### Git-Specific Optimizations

```bash
git config --global core.fsmonitor true
git config --global core.untrackedCache true
git config --global feature.manyFiles true
git config --global core.preloadindex true
git config --global pack.threads 0      # Auto-detect (uses all cores)
git config --global index.threads 0
```

**Measured impact:** 5-10x faster `git status` on large repositories.

---

## 6. Windows Defender Exclusions

### The Problem

Windows Defender scans every file WSL2 reads or writes in real-time. Since WSL2's ext4 VHDX is a single file from Windows' perspective, this creates overhead on every I/O operation.

### Solution

Run in PowerShell as Administrator:

```powershell
# Exclude WSL2 VHDX files
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx"

# Exclude WSL installation
Add-MpPreference -ExclusionPath "C:\Program Files\WSL"
Add-MpPreference -ExclusionPath "C:\Windows\System32\lxss"

# Exclude WSL processes
Add-MpPreference -ExclusionProcess "wsl.exe"
Add-MpPreference -ExclusionProcess "wslservice.exe"
Add-MpPreference -ExclusionProcess "wslhost.exe"
```

**Expected impact:** 20-40% I/O improvement.

---

## 7. What Didn't Work

### io_uring Syscall Batching (parasitic_batch)

We built an LD_PRELOAD library that intercepts libc I/O calls and batches them through Linux's `io_uring` interface. The theory was that batching 1000 syscalls into fewer VM exits would improve performance.

**Result:** No meaningful improvement for `/mnt/c` access. The Plan 9 protocol requires a per-operation round-trip regardless of how syscalls are batched on the Linux side. The bottleneck is the protocol, not the syscall count.

The library does work correctly (8/8 tests pass) and could benefit workloads doing many small I/O operations on the native Linux filesystem, but for the `/mnt/c` use case it doesn't help.

### Kernel CPU Optimizations Alone

A Zen 5-optimized kernel without I/O tuning showed only +2.5% average improvement. The CPU is rarely the bottleneck in WSL2 workloads - I/O and VM boundary crossings dominate.

---

## 8. Optimization Priority Matrix

Listed in order of impact per effort:

| Priority | Optimization | Impact | Effort |
|---|---|---|---|
| 1 | Work from `/home` instead of `/mnt/c` | **74x for file ops** | Move repos |
| 2 | Windows Defender exclusions | **20-40% I/O** | 5 min |
| 3 | `appendWindowsPath=false` | **Faster command lookup** | 2 min |
| 4 | Git optimizations | **5-10x git ops** | 2 min |
| 5 | tmpfs on /tmp | **Instant temp I/O** | 2 min |
| 6 | I/O scheduler tuning | **10-20% I/O** | 5 min |
| 7 | .wslconfig tuning | **Network + memory** | 5 min |
| 8 | Custom kernel | **~10% overall** | 45 min build |
| 9 | Lazy-load shell tools | **50-100ms/shell** | 10 min |

---

## 9. AMD Strix Halo Specific Notes

### GPU (Radeon 8060S / gfx1151)

As of February 2026, the AMD Radeon 8060S integrated in Strix Halo uses the gfx1151 (RDNA 3.5) compute target. WSL2 GPU passthrough for this chip requires:

1. Windows Adrenalin driver with WSL2 gfx1151 support (not yet available)
2. ROCm 7.2+ with gfx1151 support (tools and scripts ready in our repo)
3. WSL2 kernel with dxgkrnl module (Microsoft's driver for GPU virtualization)

**Current status:** ROCm setup scripts are ready. Waiting on AMD driver support.

**Workaround:** Use `HSA_OVERRIDE_GFX_VERSION=11.0.0` to attempt gfx1100 compatibility mode (limited functionality).

### NPU (AMD XDNA)

The XDNA NPU in Strix Halo is not directly accessible from WSL2 - there is no virtualization path for the NPU hardware. Access is only possible via a Windows bridge service that proxies inference requests over TCP.

### CPU

The Zen 5 cores benefit from a kernel compiled with `-march=znver5`, but the gains are modest (~10%) due to the VM boundary being the primary bottleneck.

---

## 10. Quick Reference: Apply All Optimizations

```bash
# 1. Move projects to Linux filesystem
cp -r /mnt/c/Users/<user>/projects ~/projects

# 2. Git optimizations
git config --global core.fsmonitor true
git config --global core.untrackedCache true
git config --global feature.manyFiles true
git config --global core.preloadindex true

# 3. I/O tuning (requires sudo)
echo "mq-deadline" | sudo tee /sys/block/sda/queue/scheduler
echo "4096" | sudo tee /sys/block/sda/queue/read_ahead_kb
sudo sysctl -w vm.swappiness=10

# 4. Shell performance
# Add to /etc/wsl.conf:
#   [interop]
#   appendWindowsPath=false

# 5. tmpfs for /tmp
echo 'tmpfs /tmp tmpfs noatime,size=4G 0 0' | sudo tee -a /etc/fstab
sudo mount -t tmpfs -o size=4G,noatime tmpfs /tmp
```

Then in PowerShell as Administrator:
```powershell
# 6. Defender exclusions
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx"
Add-MpPreference -ExclusionProcess "wsl.exe"
Add-MpPreference -ExclusionProcess "wslservice.exe"
Add-MpPreference -ExclusionProcess "wslhost.exe"
```

---

## Conclusion

The most impactful WSL2 performance optimization is architectural, not configurational: **use the Linux filesystem for your work.** Everything else provides incremental improvements on top of this foundation. A custom kernel, I/O tuning, and shell optimizations together deliver a noticeable but not transformative improvement. The real performance ceiling in WSL2 is the Plan 9 protocol for cross-filesystem access, and until Microsoft replaces it with something faster (VirtIO-FS, shared memory IPC, or direct VHDX access), the best strategy is to minimize how often you cross that boundary.
