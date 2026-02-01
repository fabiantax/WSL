# Strix-Turbo Parasitic Batch Library

LD_PRELOAD library that transparently batches syscalls via io_uring for massive WSL2 performance gains.

## The Problem

Every syscall in WSL2 causes a VM exit, which costs ~1000 CPU cycles. Traditional programs make thousands of individual syscalls for I/O operations, resulting in massive overhead.

## The Solution

This library intercepts libc I/O functions (read, write, open, close, etc.) and batches them using Linux's io_uring interface. Instead of 1000 syscalls = 1000 VM exits, we get 1000 syscalls = ~20 VM exits (50x reduction).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Application                               │
│                                                              │
│    read()    write()    open()    close()    fsync()        │
│      │         │          │         │          │            │
│      └─────────┴──────────┴─────────┴──────────┘            │
│                          │                                   │
│                          ▼                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │            libparasitic_batch.so (LD_PRELOAD)         │  │
│  │                                                        │  │
│  │    ┌─────────────┐      ┌─────────────────────────┐   │  │
│  │    │  Intercept  │ ───▶ │  Thread-Local Batch     │   │  │
│  │    │  Functions  │      │  Queue (batch_queue)    │   │  │
│  │    └─────────────┘      └───────────┬─────────────┘   │  │
│  │                                     │                  │  │
│  │                                     ▼                  │  │
│  │                         ┌─────────────────────────┐   │  │
│  │                         │   io_uring Backend      │   │  │
│  │                         │   (uring_backend)       │   │  │
│  │                         └───────────┬─────────────┘   │  │
│  └─────────────────────────────────────┼─────────────────┘  │
│                                        │                     │
└────────────────────────────────────────┼─────────────────────┘
                                         │
                                         ▼
                    ┌─────────────────────────────────────┐
                    │              Linux Kernel            │
                    │            (io_uring SQ/CQ)          │
                    └─────────────────────────────────────┘
```

## Building

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt install liburing-dev

# Build the library
make

# Build with debug output
make DEBUG=1
```

## Usage

```bash
# Basic usage
LD_PRELOAD=/path/to/libparasitic_batch.so your_program

# With debug logging
STRIX_BATCH_DEBUG=1 LD_PRELOAD=./libparasitic_batch.so git status

# Disable for specific programs
STRIX_BATCH_BLOCKLIST=python:node LD_PRELOAD=./libparasitic_batch.so ./mixed_workload.sh
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STRIX_BATCH_ENABLE` | `1` | Enable/disable batching |
| `STRIX_BATCH_SIZE` | `64` | Max operations per batch |
| `STRIX_BATCH_TIMEOUT` | `1000` | Flush timeout in microseconds |
| `STRIX_BATCH_DEBUG` | `0` | Enable debug logging |
| `STRIX_BATCH_SQPOLL` | `0` | Use io_uring SQPOLL mode |
| `STRIX_BATCH_BLOCKLIST` | `` | Colon-separated programs to skip |
| `STRIX_RING_ENTRIES` | `256` | io_uring queue size |

## Intercepted Functions

| Function | Batched | Notes |
|----------|---------|-------|
| `read()` | ✅ | Skips stdin/stdout/stderr |
| `write()` | ✅ | Skips stdin/stdout/stderr |
| `pread()` | ✅ | Positioned read |
| `pwrite()` | ✅ | Positioned write |
| `open()` | ✅ | Skips /proc, /sys, /dev |
| `openat()` | ✅ | Delegates to open() |
| `close()` | ✅ | |
| `fsync()` | ✅ | |
| `fdatasync()` | ✅ | |
| `stat()` | ❌ | Uses sync fallback |
| `fstat()` | ❌ | Uses sync fallback |
| `lstat()` | ❌ | Uses sync fallback |

## Testing

```bash
# Run unit tests
make test

# Run benchmarks
make bench
```

## Expected Performance

| Workload | Without Batching | With Batching | Improvement |
|----------|------------------|---------------|-------------|
| Many small files | 1x | 5-10x | ~500-1000% |
| git status (large repo) | 30s | 5s | ~500% |
| npm install | 120s | 40s | ~200% |
| Sequential I/O | 1x | 1.5-2x | ~50-100% |

## Known Limitations

1. **stat/fstat/lstat** use synchronous fallback (io_uring statx requires struct conversion)
2. **Pipes and sockets** are passed through (not batched)
3. **/proc, /sys, /dev** are passed through
4. **Small batches** may have overhead; tune BATCH_SIZE for your workload

## Troubleshooting

### Library not loading
```bash
# Check if library is being loaded
STRIX_BATCH_DEBUG=1 LD_PRELOAD=./libparasitic_batch.so echo test
```

### io_uring not available
```bash
# Check kernel support
cat /proc/config.gz | gunzip | grep IO_URING
# Should show: CONFIG_IO_URING=y

# Check liburing
ldconfig -p | grep uring
```

### Program crashes
```bash
# Add program to blocklist
STRIX_BATCH_BLOCKLIST=problematic_program LD_PRELOAD=./libparasitic_batch.so ./script.sh
```

## Files

| File | Purpose |
|------|---------|
| `libparasitic_batch.c` | Main LD_PRELOAD library |
| `batch_queue.c/h` | Thread-local batch management |
| `uring_backend.c/h` | io_uring interface |
| `config.c/h` | Environment variable config |
| `test_parasitic.c` | Unit tests |
| `bench_parasitic.c` | Benchmarks |

## License

MIT License - Strix-Turbo Project 2026
