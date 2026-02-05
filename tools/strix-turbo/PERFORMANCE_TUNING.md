# WSL2 Strix-Turbo Performance Tuning Guide

**Last Updated**: 2026-02-05
**Target System**: AMD Ryzen AI MAX+ PRO 395

## Quick Start

### 🚀 Immediate Performance Boost

**Use 256K block size for all VirtioFS I/O operations**

```bash
# Instead of:
dd if=source of=/mnt/c/target bs=64K

# Use:
dd if=source of=/mnt/c/target bs=256K oflag=direct
```

**Result**: 71% faster writes, 99% faster reads

---

## Performance Summary

| Operation | Before | After | Improvement |
|-----------|--------|-------|-------------|
| VirtioFS Write | 382 MB/s | 654 MB/s | **+71%** |
| VirtioFS Read | ~400 MB/s | 796 MB/s | **+99%** |
| Local Write | 1.3 GB/s | 1.3 GB/s | (optimal) |
| Local Read | 9.3 GB/s | 9.3 GB/s | (optimal) |

---

## Optimization Techniques

### 1. Optimal Block Size (CRITICAL)

**Use 256K blocks** for all VirtioFS operations:

```bash
# File copy
dd if=/home/user/file.dat of=/mnt/c/backup/file.dat bs=256K oflag=direct

# Directory sync
rsync -avh --progress --block-size=256K /home/user/project /mnt/c/backup/

# Tar archive
tar --blocking-factor=500 -cf /mnt/c/backup/archive.tar /home/user/project

# Database dump
mysqldump database | dd bs=256K of=/mnt/c/backup/database.sql
```

### 2. I/O Flags

**Use oflag=direct or oflag=sync** for reliable writes:

```bash
# Direct I/O (bypass kernel cache)
dd if=source of=/mnt/c/target bs=256K oflag=direct

# Synchronized I/O (ensure data hits disk)
dd if=source of=/mnt/c/target bs=256K oflag=sync

# Buffered I/O (default, slightly slower but safe)
dd if=source of=/mnt/c/target bs=256K
```

### 3. Development Workflow Optimization

**Principle**: Keep active work in Linux filesystem, use VirtioFS for integration

```bash
# ✅ OPTIMAL: Work in Linux filesystem
cd ~/projects/myapp
git clone https://github.com/user/repo.git
code .  # VS Code with Remote-WSL

# ✅ GOOD: Share build artifacts to Windows
make build && cp -r build /mnt/c/workspace/myapp/

# ❌ AVOID: Active development in /mnt/c
cd /mnt/c/projects/myapp  # Slow due to VirtioFS overhead
```

### 4. Docker Performance

**Use Linux filesystem for Docker volumes**:

```yaml
# docker-compose.yml
services:
  app:
    volumes:
      # ✅ OPTIMAL: Linux filesystem
      - /home/user/data:/app/data

      # ⚠️ SLOWER: VirtioFS (but accessible from Windows)
      - /mnt/c/Users/user/data:/app/data
```

### 5. Git Operations

**Clone to Linux, push artifacts to Windows**:

```bash
# ✅ Fast: Clone to Linux
cd ~
git clone --depth 1 https://github.com/large/repo.git

# ✅ Share to Windows if needed
cp -r repo /mnt/c/workspace/

# Or use symlink in Windows
# (from PowerShell as admin)
# New-Item -ItemType SymbolicLink -Path "C:\workspace\repo" -Target "\\wsl.localhost\UbuntuD\home\user\repo"
```

---

## Benchmarking

### Quick Test

```bash
# Run the automated benchmark
bash /mnt/c/Users/fabia/Projects/wsl/WSL/tools/strix-turbo/virtiofs-benchmark.sh

# Or manual test
dd if=/dev/zero of=/mnt/c/temp/test.dat bs=256K count=1024 oflag=direct
```

### Expected Results (256MB test)

| Metric | Target Speed | Notes |
|--------|--------------|-------|
| Write (256K) | 650+ MB/s | Optimal block size |
| Read (256K) | 750+ MB/s | Optimal block size |
| Write (64K) | 400 MB/s | Suboptimal |
| Write (1M) | 200 MB/s | Too large |

---

## What NOT to Do

### ❌ Don't Use Parallel Writes

```bash
# ❌ SLOW: Parallel streams reduce per-stream speed
for i in {1..4}; do
    dd if=source$i of=/mnt/c/target$i bs=256K &
done
wait
# Result: ~100 MB/s per stream (400 MB/s total)

# ✅ FAST: Single stream
dd if=source of=/mnt/c/target bs=256K
# Result: 650 MB/s
```

### ❌ Don't Use Very Large Block Sizes

```bash
# ❌ SLOW: 1M or 4M blocks
dd if=source of=/mnt/c/target bs=1M    # ~200 MB/s
dd if=source of=/mnt/c/target bs=4M    # ~200 MB/s

# ✅ FAST: 256K blocks
dd if=source of=/mnt/c/target bs=256K  # ~650 MB/s
```

### ❌ Don't Use Parasitic Batching Library (Yet)

The current parasitic batching library has bugs:
- File descriptor errors
- Breaks I/O operations
- No performance benefit

**Status**: Under development, not recommended for production use

---

## Application-Specific Tips

### Node.js / npm

```bash
# Install in Linux filesystem
cd ~/projects/myapp
npm install

# Use Windows Node.js with Linux files
# (from Windows PowerShell)
# node.exe \\wsl.localhost\UbuntuD\home\user\projects\myapp\index.js
```

### Python / pip

```bash
# Virtual environment in Linux
cd ~/projects/myapp
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Database Backups

```bash
# PostgreSQL dump with optimal block size
pg_dump mydb | dd bs=256K of=/mnt/c/backups/mydb_$(date +%Y%m%d).sql

# MySQL dump
mysqldump --single-transaction mydb | dd bs=256K of=/mnt/c/backups/mydb.sql
```

### Large File Transfers

```bash
# Download to Linux, copy to Windows with optimal settings
wget https://example.com/largefile.zip -O ~/downloads/largefile.zip
dd if=~/downloads/largefile.zip of=/mnt/c/downloads/largefile.zip bs=256K oflag=direct
```

---

## System Configuration

### Current Optimal Settings (No Changes Needed)

The following settings are already optimal in current `.wslconfig`:

```ini
[wsl2]
memory=96GB              # ✅ Good: Plenty of memory for caching
processors=32            # ✅ Good: All cores available
virtiofs=true           # ✅ Required: Enables VirtioFS
kernelCommandLine=numad=on amdgpu.precisegpu=1 no-mitigations
                        # ✅ Good: NUMA optimization, no mitigations
```

**VM Parameters** (inside WSL, already optimal):
```bash
vm.swappiness = 10                    # ✅ Minimize swapping
vm.vfs_cache_pressure = 50            # ✅ Balanced cache
vm.dirty_ratio = 15                   # ✅ Good write buffering
vm.dirty_background_ratio = 5         # ✅ Aggressive background writes
```

**No changes recommended** - system is well-tuned.

---

## Monitoring Performance

### Real-Time I/O Monitoring

```bash
# Watch I/O statistics
iostat -x 1

# Monitor specific device
iostat -x 1 sda

# Watch VirtioFS mounts
watch -n 1 'mount | grep virtiofs'
```

### Performance Profiling

```bash
# Profile a command
time dd if=/dev/zero of=/mnt/c/temp/test.dat bs=256K count=1024 oflag=direct

# Detailed timing
/usr/bin/time -v dd if=/dev/zero of=/mnt/c/temp/test.dat bs=256K count=1024 oflag=direct
```

---

## Troubleshooting

### Slow Performance

1. **Check block size**: Ensure using 256K blocks
2. **Check mount**: Verify VirtioFS is mounted
   ```bash
   mount | grep virtiofs
   ```
3. **Check Windows disk**: Ensure target drive is not busy
4. **Check available memory**:
   ```bash
   free -h
   ```

### Inconsistent Performance

1. **Disable Windows Defender real-time scanning** for WSL directories
2. **Check for background processes**:
   ```bash
   top
   htop
   ```
3. **Verify kernel version**:
   ```bash
   uname -r  # Should be 6.18.8 or newer
   ```

### File Permission Issues

```bash
# Set proper permissions on /mnt/c
sudo mount -o remount,metadata /mnt/c

# Or add to /etc/wsl.conf
[automount]
options = "metadata"
```

---

## Future Optimizations

### High Priority

1. **Shared Memory IPC** - Bypass VirtioFS entirely for hot paths
   - Potential: 5-10x improvement
   - Status: Under development

2. **io_uring Integration** - Reduce syscall overhead
   - Potential: 20-30% improvement
   - Status: Research phase

3. **Fix Parasitic Batching** - Batch I/O operations
   - Potential: 10-20% improvement
   - Status: Has bugs, needs fixes

### Medium Priority

4. **VirtioFS Driver Tuning** - Adjust queue depths
   - Potential: 10-15% improvement
   - Status: Requires driver expertise

5. **NUMA-Aware I/O** - Pin I/O to specific NUMA nodes
   - Potential: 5-10% improvement
   - Status: Experimental

---

## Additional Resources

- **Full Optimization Report**: `/docs/PERFORMANCE_FINAL.md`
- **Optimization Cycles**: `/docs/OPTIMIZATION_CYCLES.md`
- **Benchmark Script**: `/tools/strix-turbo/virtiofs-benchmark.sh`
- **WSL Documentation**: https://docs.microsoft.com/en-us/windows/wsl/

---

## Summary

**Key Takeaway**: Use 256K block size for 71% faster writes and 99% faster reads.

**Quick Commands**:
```bash
# Optimal file copy
dd if=source of=/mnt/c/target bs=256K oflag=direct

# Optimal rsync
rsync -avh --block-size=256K source /mnt/c/target

# Run benchmark
bash /mnt/c/Users/fabia/Projects/wsl/WSL/tools/strix-turbo/virtiofs-benchmark.sh
```

**Result**: Maximum VirtioFS performance without system changes.
