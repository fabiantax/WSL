# Strix Turbo - Quick Start Guide

Build a high-performance Zen 5 optimized WSL2 kernel in 5 minutes!

## Prerequisites Check

```bash
# Check if all dependencies are installed
./check-dependencies.sh

# Auto-install missing dependencies (requires sudo)
sudo ./check-dependencies.sh --install
```

## Build the Kernel

### Option 1: Default Build (Recommended)
```bash
./build-zen5-kernel.sh
```

### Option 2: With Clang for Better Optimization
```bash
./build-zen5-kernel.sh --clang
```

### Option 3: Specify Kernel Version
```bash
./build-zen5-kernel.sh --version linux-msft-wsl-5.15.146.1
```

### Option 4: Full Custom Configuration
```bash
./build-zen5-kernel.sh \
  --version linux-msft-wsl-5.15.146.1 \
  --clang \
  --jobs 8 \
  --output /mnt/c/Users/YourUsername/WSL-Kernels
```

## After Build Completes

The script will display instructions including:
1. **Kernel Location** - Where the bzImage was saved
2. **Config File** - A .wslconfig snippet you'll need to copy

### Manual Installation Steps

#### 1. Edit Windows .wslconfig
Open `C:\Users\<YourUsername>\.wslconfig` in Notepad

Add this under the `[wsl2]` section:
```ini
[wsl2]
kernel=C:\Users\YourUsername\WSL-Kernels\bzImage-latest
```

#### 2. Shutdown WSL2
From PowerShell:
```powershell
wsl --shutdown
```

#### 3. Restart WSL2
Open your WSL terminal - it will automatically load the new kernel

#### 4. Verify Installation
```bash
uname -r
# Should show the new kernel version
```

## Apply Performance Tuning (Optional)

After the kernel is running:

```bash
# Verify kernel is running and apply tuning
./post-build-tuning.sh --tune

# Run performance benchmarks
./post-build-tuning.sh --bench
```

## Build Times

Typical times with parallel compilation:
| Cores | Time |
|-------|------|
| 2 | ~2.5 min |
| 4 | ~1.5 min |
| 8 | ~45 sec |
| 16 | ~30 sec |

## Common Issues

### Build Fails with "command not found"
```bash
# Install missing dependencies
./check-dependencies.sh --install
```

### WSL Won't Start After Kernel Install
1. Check .wslconfig path is correct (Windows format)
2. Verify kernel file exists and is readable
3. Reset: `wsl --update`

### Need to Rebuild
```bash
cd /home/user/WSL/tools/strix-turbo/linux-kernel
make clean
cd ..
./build-zen5-kernel.sh
```

## What Gets Optimized

- **CPU Scheduling** - Zen scheduler for responsiveness
- **Networking** - BBRv3 TCP for faster throughput
- **Disk I/O** - BFQ scheduler for better performance
- **Memory** - Transparent Huge Pages enabled
- **Power** - Efficient CPU frequency scaling
- **Latency** - Full preemption for low latency

## File Structure

```
/home/user/WSL/tools/strix-turbo/
├── build-zen5-kernel.sh          # Main build script
├── check-dependencies.sh          # Dependency checker
├── post-build-tuning.sh           # Performance tuning
├── README.md                       # Comprehensive documentation
├── QUICK_START.md                 # This file
├── linux-kernel/                  # Kernel source (created on first run)
├── output/                        # Built kernels (created on first run)
└── logs/                          # Build logs (created on first run)
```

## Advanced Options

### Monitor Build Progress
```bash
tail -f /home/user/WSL/tools/strix-turbo/logs/build-*.log
```

### Use Specific Kernel Version
Get available versions:
```bash
cd /home/user/WSL/tools/strix-turbo/linux-kernel
git tag | grep "linux-msft-wsl" | tail -10
```

Then build:
```bash
./build-zen5-kernel.sh --version linux-msft-wsl-5.15.146.1
```

### Custom Output Location
```bash
./build-zen5-kernel.sh --output /path/to/kernels
```

## Performance Tips

After kernel installation, optimize runtime:

```bash
# Enable faster network (add to /etc/sysctl.conf)
echo "net.ipv4.tcp_tw_reuse=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_fast_open=3" | sudo tee -a /etc/sysctl.conf

# Apply changes
sudo sysctl -p
```

## Monitoring Performance

```bash
# CPU usage
htop

# Network throughput
iftop

# Disk I/O
iotop

# System stats
vmstat 1

# Performance stats
perf stat [command]
```

## Fallback to Default Kernel

If you need to switch back:

1. Edit `.wslconfig` and remove or comment out the kernel line
2. Run `wsl --shutdown`
3. Restart WSL - it will use Microsoft's default kernel

## Support

For detailed information, see `README.md`

For quick troubleshooting:
1. Check build logs: `cat /home/user/WSL/tools/strix-turbo/logs/build-*.log`
2. Verify dependencies: `./check-dependencies.sh`
3. Review README.md troubleshooting section

## Next Steps

1. **Build kernel** - Run `./build-zen5-kernel.sh`
2. **Configure** - Follow the generated instructions
3. **Restart WSL2** - New kernel loads automatically
4. **Tune** - Run `./post-build-tuning.sh --tune`
5. **Monitor** - Use tools to verify performance improvements

---

**Estimated Total Time**: 5-15 minutes (depending on hardware)

Good luck with your Zen 5 kernel! 🚀
