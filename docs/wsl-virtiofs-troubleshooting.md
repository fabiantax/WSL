# WSL VirtioFS Troubleshooting Guide

## Overview

This guide covers common issues with VirtioFS configuration in WSL2, particularly for performance-focused setups on AMD Strix Halo systems.

## Common Issue: "Processing /etc/fstab with mount -a failed"

### Symptoms

```
wsl: Processing /etc/fstab with mount -a failed.
wsl: Failed to translate 'C:\Users\...'
sh: 1: /scripts/wslServer.sh: not found
```

VS Code and other applications fail to connect to WSL.

### Root Cause

Incorrect virtiofs device names in `/etc/fstab`. Common mistakes:
- Using `drvfsaC0` instead of `drvfsC0` (extra 'a')
- Using `C:` instead of the actual virtiofs tag
- Assuming device names without checking kernel messages

### Diagnostic Steps

#### 1. Verify VirtioFS is Enabled

Check `C:\Users\<Username>\.wslconfig`:

```ini
[wsl2]
virtiofs=true  # Should be true
```

#### 2. Discover Actual Device Names

Boot WSL with debug info:

```bash
wsl --cd / -d <distro> --user root sh -c 'dmesg | grep "virtiofs.*tag:"'
```

Expected output:
```
[    0.469485] virtiofs virtio1: discovered new tag: drvfsC0
[    0.489361] virtiofs virtio2: discovered new tag: drvfsD1
```

The actual device tags are `drvfsC0` and `drvfsD1`, **not** `C:` or `drvfsaC0`.

#### 3. Check Current /etc/fstab

```bash
wsl --cd / -d <distro> sh -c 'cat /etc/fstab'
```

### Solution

#### Step 1: Fix /etc/fstab

Update with correct device names:

```bash
wsl --cd / -d <distro> --user root sh -c 'cat > /etc/fstab << "EOF"
# UNCONFIGURED FSTAB FOR BASE SYSTEM
tmpfs /tmp tmpfs noatime,size=4G 0 0

# VirtioFS mounts for Windows drives
# Device names from: dmesg | grep "virtiofs.*tag:"
drvfsC0 /mnt/c virtiofs rw,relatime,nofail 0 0
drvfsD1 /mnt/d virtiofs rw,relatime,nofail 0 0
EOF
'
```

**Important**:
- Use actual tags from `dmesg` output
- Include `nofail` option to prevent boot failures
- No 'a' in device names: `drvfsC0` not `drvfsaC0`

#### Step 2: Configure Automount

Ensure `/etc/wsl.conf` has proper automount settings:

```bash
wsl --cd / -d <distro> --user root sh -c 'cat > /etc/wsl.conf << "EOF"
[boot]
systemd=true

[user]
default=<your-username>

[interop]
appendWindowsPath=false

[automount]
enabled=true
root=/mnt/
options=metadata
mountFsTab=true
EOF
'
```

#### Step 3: Restart WSL

```powershell
wsl --shutdown
```

Wait 5 seconds, then start WSL normally.

#### Step 4: Verify

```bash
# Check mounts
mount | grep virtiofs

# Should show:
# drvfsC0 on /mnt/c type virtiofs (rw,relatime)
# drvfsD1 on /mnt/d type virtiofs (rw,relatime)

# Test access
ls /mnt/c/Windows/System32 | head -5
```

## Alternative: Auto-Mount Without fstab

If you want WSL to auto-mount drives without manual fstab entries:

### Option 1: Remove fstab Entries

```bash
# Minimal fstab
cat > /etc/fstab << 'EOF'
# UNCONFIGURED FSTAB FOR BASE SYSTEM
tmpfs /tmp tmpfs noatime,size=4G 0 0
EOF
```

WSL will auto-mount drives using the backend specified in `.wslconfig`:
- With `virtiofs=true`: Uses virtiofs backend
- With `virtiofs=false` or unset: Uses 9p/drvfs backend

### Option 2: WSL Auto-Mount (Recommended for Most Users)

Just enable in `.wslconfig`:

```ini
[wsl2]
virtiofs=true
```

And ensure automount is enabled in `/etc/wsl.conf`:

```ini
[automount]
enabled=true
root=/mnt/
```

WSL handles the rest automatically.

## Device Name Reference

### How VirtioFS Tags Work

Microsoft's WSL2 implementation creates virtiofs devices with specific tags:
- `drvfsC0` - C: drive
- `drvfsD1` - D: drive
- `drvfsE2` - E: drive
- Pattern: `drvfs<DRIVE><INDEX>`

**Common mistakes**:
- ❌ `C:` - Not a valid virtiofs tag
- ❌ `drvfsaC0` - Extra 'a' is incorrect
- ❌ `/dev/sdc` - Wrong device type
- ✅ `drvfsC0` - Correct format

### Finding Available Drives

```bash
# List all virtiofs tags
dmesg | grep "virtiofs.*tag:" | grep -v wslg

# Output format:
# [timestamp] virtiofs virtioN: discovered new tag: drvfsX#
```

## Performance Comparison

### 9p/drvfs (Default)
```
Sequential read:  ~200 MB/s
Random IOPS:      ~5,000
Latency:          High (multiple VM exits per operation)
```

### VirtioFS
```
Sequential read:  ~2,000 MB/s (10x improvement)
Random IOPS:      ~50,000 (10x improvement)
Latency:          Low (optimized FUSE)
```

## Troubleshooting Common Errors

### Error: "mount: wrong fs type, bad option, bad superblock"

**Cause**: Device name doesn't exist or kernel doesn't support virtiofs.

**Solution**:
1. Verify device exists: `dmesg | grep virtiofs`
2. Check kernel has virtiofs: `grep VIRTIO_FS /proc/config.gz`
3. Use correct device name from dmesg output

### Error: "Transport endpoint is not connected"

**Cause**: VirtioFS service not available on Windows side.

**Solution**:
1. Ensure `virtiofs=true` in `.wslconfig`
2. Restart WSL: `wsl --shutdown`
3. Update WSL: `wsl --update`

### Error: WSL Boots but /mnt/c is Empty

**Cause**: Mount happened but failed silently.

**Solution**:
```bash
# Check mount status
mount | grep /mnt/c

# If not mounted, check dmesg for errors
dmesg | tail -50 | grep -i "virtiofs\|mount\|error"

# Try manual mount
sudo mount -t virtiofs drvfsC0 /mnt/c
```

### Error: Performance Not Improved

**Verification**:
```bash
# Confirm virtiofs is being used
mount | grep /mnt/c
# Should say "type virtiofs" not "type 9p"

# Benchmark
time dd if=/mnt/c/Windows/System32/kernel32.dll of=/dev/null bs=1M

# Compare with 9p (disable virtiofs in .wslconfig first)
```

## Advanced Configuration

### Custom VirtioFS Options

```bash
# In /etc/fstab, add options:
drvfsC0 /mnt/c virtiofs rw,relatime,nofail,cache=always 0 0
```

**Available options**:
- `cache=always` - Maximum caching (default)
- `cache=none` - No caching (for testing)
- `nofail` - Continue boot if mount fails
- `relatime` - Reduce access time updates

### Multiple Drive Setup

```bash
# /etc/fstab for C:, D:, E: drives
drvfsC0 /mnt/c virtiofs rw,relatime,nofail 0 0
drvfsD1 /mnt/d virtiofs rw,relatime,nofail 0 0
drvfsE2 /mnt/e virtiofs rw,relatime,nofail 0 0
```

Verify tags first with `dmesg | grep virtiofs`.

### Kernel Requirements

VirtioFS requires:
- `CONFIG_VIRTIO_FS=y` in kernel config
- `CONFIG_FUSE_FS=y` or `=m`
- Kernel 5.4+ (5.10+ recommended)

Check your kernel:
```bash
uname -r
zcat /proc/config.gz | grep -E "VIRTIO_FS|FUSE_FS"
```

## Best Practices

1. **Always use `nofail`** in fstab entries to prevent boot failures
2. **Check device names** with dmesg before configuring
3. **Test with `--cd /`** to avoid path translation issues
4. **Keep backups** of working `.wslconfig` and `/etc/fstab`
5. **Use WSL auto-mount** if you don't need custom mount options
6. **Monitor performance** with benchmarks to verify improvements

## Recovery Procedure

If WSL won't boot due to fstab issues:

### Method 1: Debug Shell (Requires Admin)
```powershell
wsl --debug-shell
# Fix /etc/fstab from debug shell
```

### Method 2: Disable VirtioFS Temporarily
```powershell
# Edit C:\Users\<Username>\.wslconfig
# Change: virtiofs=true to virtiofs=false
wsl --shutdown

# WSL will boot with 9p, then fix fstab
wsl -d <distro> --user root
# Fix /etc/fstab

# Re-enable virtiofs in .wslconfig
wsl --shutdown
```

### Method 3: Backup Distro
```powershell
# Export current state
wsl --export <distro> C:\backup.tar

# If needed, import clean version
wsl --unregister <distro>
wsl --import <distro> <location> C:\backup.tar
```

## Additional Resources

- [WSL Configuration](https://learn.microsoft.com/windows/wsl/wsl-config)
- [VirtioFS Documentation](https://virtio-fs.gitlab.io/)
- [Strix-Turbo Performance Guide](../tools/strix-turbo/README.md)
- [WSL Architecture](../doc/docs/technical-documentation/index.md)

## Contributing

Found a solution not covered here? Please contribute:
1. Test your solution thoroughly
2. Document steps clearly
3. Include error messages and outputs
4. Submit a PR with updates to this guide

---

**Last Updated**: February 5, 2026
**Status**: Verified on WSL 2.x with custom Zen 5 kernel
