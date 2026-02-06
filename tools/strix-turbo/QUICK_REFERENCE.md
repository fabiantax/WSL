# WSL2 Strix-Turbo Quick Reference

## 🚀 Performance Boost (71-99% Faster)

### One-Liner: Use 256K Blocks

```bash
# Instead of default
dd if=source of=/mnt/c/target

# Use this (71% faster writes, 99% faster reads)
dd if=source of=/mnt/c/target bs=256K oflag=direct
```

---

## Common Commands

### File Copy
```bash
# Optimal performance
dd if=~/data.bin of=/mnt/c/backup/data.bin bs=256K oflag=direct

# With progress
dd if=~/data.bin of=/mnt/c/backup/data.bin bs=256K oflag=direct status=progress
```

### Directory Sync
```bash
# Rsync with optimal block size
rsync -avh --progress --block-size=256K ~/project /mnt/c/backup/

# Tar with optimal settings
tar --blocking-factor=500 -czf /mnt/c/backup/project.tar.gz ~/project
```

### Database Backup
```bash
# PostgreSQL
pg_dump mydb | dd bs=256K of=/mnt/c/backups/mydb.sql

# MySQL
mysqldump mydb | dd bs=256K of=/mnt/c/backups/mydb.sql
```

### Docker
```bash
# Build with files in /home (faster)
cd ~/myapp && docker build .

# Copy results to Windows
docker save myimage | dd bs=256K of=/mnt/c/images/myimage.tar
```

---

## Benchmark

```bash
# Quick test (256MB)
dd if=/dev/zero of=/mnt/c/temp/test.dat bs=256K count=1024 oflag=direct

# Full benchmark suite
bash /mnt/c/Users/fabia/Projects/wsl/WSL/tools/strix-turbo/virtiofs-benchmark.sh

# Expected: 650+ MB/s write, 750+ MB/s read
```

---

## Performance Matrix

| Block Size | Write Speed | Read Speed | Use Case |
|------------|-------------|------------|----------|
| 4K | ~200 MB/s | ~180 MB/s | ❌ Too small |
| 64K | 408 MB/s | 442 MB/s | ⚠️ Default (slow) |
| **256K** | **654 MB/s** | **796 MB/s** | ✅ **OPTIMAL** |
| 1M | 197 MB/s | 203 MB/s | ❌ Too large |

---

## Best Practices

### ✅ DO

- Use 256K block size for VirtioFS
- Use oflag=direct or oflag=sync
- Develop in /home, share to /mnt/c
- Single-threaded sequential I/O

### ❌ DON'T

- Use parallel writes to /mnt/c (slower)
- Use very large blocks (1M, 4M)
- Use parasitic batching library (has bugs)
- Develop directly in /mnt/c (use /home)

---

## Troubleshooting

### Slow Performance
```bash
# Check block size
# Should see bs=256K in command

# Check VirtioFS mount
mount | grep virtiofs

# Run benchmark
bash /mnt/c/Users/fabia/Projects/wsl/WSL/tools/strix-turbo/virtiofs-benchmark.sh
```

### System Check
```bash
# Kernel version (should be 6.18.8+)
uname -r

# Memory available
free -h

# VirtioFS enabled
cat "$USERPROFILE/.wslconfig" | grep virtiofs
```

---

## Real-World Examples

### Git Large Repository
```bash
# Clone to Linux (fast)
cd ~ && git clone https://github.com/large/repo.git

# Share to Windows (optimal)
cp -r repo /mnt/c/workspace/
# Or use 256K blocks
tar cf - repo | (cd /mnt/c/workspace && tar xf -)
```

### Build Artifacts
```bash
# Build in /home (fastest)
cd ~/myapp && make build

# Copy to Windows with optimal settings
dd if=myapp.bin of=/mnt/c/releases/myapp.bin bs=256K oflag=direct
```

### Large File Download
```bash
# Download to Linux
wget https://example.com/file.iso -O ~/downloads/file.iso

# Transfer to Windows (optimal)
dd if=~/downloads/file.iso of=/mnt/c/downloads/file.iso bs=256K oflag=direct status=progress
```

---

## Performance Expectations

| File Size | Write Time | Read Time |
|-----------|------------|-----------|
| 256MB | ~0.4s | ~0.3s |
| 1GB | ~1.6s | ~1.3s |
| 2GB | ~3.3s | ~2.7s |
| 10GB | ~16s | ~13s |

All with 256K block size on AMD Ryzen AI MAX+ PRO 395.

---

## Resources

- **Full Guide**: [PERFORMANCE_TUNING.md](PERFORMANCE_TUNING.md)
- **Detailed Report**: [PERFORMANCE_FINAL.md](../../docs/PERFORMANCE_FINAL.md)
- **Optimization Cycles**: [OPTIMIZATION_CYCLES.md](../../docs/OPTIMIZATION_CYCLES.md)
- **Summary**: [OPTIMIZATION_SUMMARY.md](../../docs/OPTIMIZATION_SUMMARY.md)

---

## TL;DR

**Use `bs=256K oflag=direct` for all VirtioFS operations. 71% faster writes, 99% faster reads.**

```bash
dd if=source of=/mnt/c/target bs=256K oflag=direct
```
