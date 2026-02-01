# WSL2 Performance Plugin Architecture

## Overview

This directory contains the design and implementation of a plugin architecture for WSL2 that enables state-of-the-art performance optimizations while maintaining compatibility with conservative enterprise environments and legacy hardware.

## The Challenge

We have SOTA optimizations that provide 10x speedup on modern hardware:
- **SPDK NVMe passthrough** - Direct NVMe access, ~1M IOPS
- **AVX-512 SIMD** - 64-byte vector processing
- **NPU prefetching** - ML-based I/O prediction
- **Shared memory IPC** - Zero-copy Windows/Linux communication

But upstream WSL2 must support:
- 10-year-old CPUs without AVX-512
- Systems without dedicated NVMe for passthrough
- Systems without NPU
- Conservative enterprise environments

## Solution: Capability-Based Plugin Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     WSL2 Core (Upstream)                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    Plugin Host                         │  │
│  │  - Hardware capability detection (CPUID, devices)      │  │
│  │  - Plugin discovery and loading                        │  │
│  │  - Fallback chains with health monitoring              │  │
│  │  - A/B testing infrastructure                          │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │   Storage   │     │   Compute   │     │ Prediction  │
   │   Plugins   │     │   Plugins   │     │   Plugins   │
   ├─────────────┤     ├─────────────┤     ├─────────────┤
   │ SPDK NVMe   │     │ AVX-512     │     │ NPU LSTM    │
   │ VirtIO-FS   │     │ AVX2        │     │ GPU ML      │
   │ VHDX (stock)│     │ Scalar      │     │ LRU (stock) │
   └─────────────┘     └─────────────┘     └─────────────┘
```

## Directory Structure

```
plugin-architecture/
├── README.md                       # This file
├── PLUGIN_ARCHITECTURE_DESIGN.md   # Detailed design document
├── CMakeLists.txt                  # Build configuration
│
├── include/                        # Public headers
│   ├── WslPluginCapabilities.h     # Hardware caps, tiers, descriptors
│   ├── WslStoragePlugin.h          # Storage plugin interface
│   ├── WslComputePlugin.h          # Compute plugin interface
│   └── WslPluginHost.h             # Plugin host API
│
├── plugins/                        # Plugin implementations
│   ├── scalar-compute/             # Stock scalar (always available)
│   ├── avx512-compute/             # AVX-512 optimized
│   ├── spdk-storage/               # SPDK NVMe passthrough
│   ├── shared-memory-ipc/          # Shared memory IPC
│   └── npu-prefetch/               # NPU-based prefetching
│
└── src/                            # Core implementation
    ├── capability_detection.cpp
    ├── plugin_host.cpp
    ├── fallback_chain.cpp
    └── health_monitor.cpp
```

## Key Concepts

### 1. Hardware Capability Flags

Plugins declare what hardware they require:

```cpp
.required_caps = WSL_HW_CAP_AVX512F | WSL_HW_CAP_AVX512BW,
.optional_caps = WSL_HW_CAP_AVX512VL,
```

The plugin host detects available capabilities at startup and only loads compatible plugins.

### 2. Stability Tiers

```
STOCK         Built-in, always available, cannot be disabled
STABLE        Safe for production, enabled by default if HW matches
BETA          Opt-in via .wslconfig
EXPERIMENTAL  Opt-in + acknowledgment required
DANGEROUS     Expert only, known issues
```

Users control risk via `.wslconfig`:
```ini
[experimental]
maxPluginTier = beta
```

### 3. Automatic Fallback

Each plugin category has a fallback chain:

```
SPDK (priority 500) ─┐
                     │ If crash/error
VirtIO-FS (200) ◄────┘─┐
                       │ If unavailable
VHDX (stock, 0) ◄──────┘
```

The plugin host monitors health (latency, error rate) and automatically falls back if a plugin is failing.

### 4. A/B Testing

```ini
[abtest]
enabled = true
storage.A = com.strix.shared-memory-ipc
storage.B = com.microsoft.9p
storage.splitPercentage = 50
```

The host tracks statistics for both plugins, enabling data-driven decisions about which optimizations to enable by default.

## Plugin Interface Example

Storage plugin interface (simplified):

```cpp
typedef struct WslStoragePluginV1 {
    WslPluginDescriptor descriptor;

    // Lifecycle
    WslStorageResult (*initialize)(const WslPluginContext* ctx);
    void (*shutdown)(void);

    // Capability query
    bool (*supports_path)(const char* path);
    WslStorageFeatures (*get_features)(void);

    // Operations
    WslStorageResult (*open)(const char* path, uint32_t flags, ...);
    WslStorageResult (*read)(WslStorageHandlePtr handle, void* buf, ...);
    WslStorageResult (*write)(WslStorageHandlePtr handle, const void* buf, ...);

    // Async operations (optional)
    WslStorageResult (*read_async)(... , WslStorageCallback cb, ...);

    // Statistics (for A/B testing)
    void (*get_stats)(WslStorageStats* out);

} WslStoragePluginV1;
```

## Upstream Acceptance Strategy

### Phase 1: Core Abstractions (Safe for upstream)
- `WslPluginCapabilities.h` - Hardware detection, tier system
- Plugin host infrastructure
- Stock plugins wrapped in plugin interface

### Phase 2: Stable Enhancements (Low risk)
- AVX2 compute plugin (broad hardware support)
- Enhanced metadata caching
- A/B testing framework

### Phase 3: Aggressive Optimizations (Out-of-tree initially)
- SPDK storage (requires dedicated NVMe)
- Shared memory IPC (security review needed)
- NPU prediction (niche hardware)
- AVX-512 compute (limited hardware)

## Configuration

`.wslconfig` extensions:

```ini
[plugins]
enabled = com.strix.avx512-compute
disabled = com.strix.spdk-storage

[plugins.com.strix.spdk-storage]
nvmeDevice = 0000:01:00.0
queueDepth = 256
hugepagesMB = 2048
```

## Building

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DENABLE_AVX512=ON \
         -DENABLE_SPDK=ON
cmake --build .
```

## Testing

```bash
# Run all tests
ctest --output-on-failure

# Benchmark plugins
./benchmark_plugins --iterations 10000
```

## Security

- Plugins are DLL signature-verified before loading
- Enterprise policy can restrict to Microsoft-signed only
- Capability detection is sandboxed (no kernel access needed)
- Telemetry is opt-in and anonymized

## Contributing

1. New plugins should use the existing interfaces
2. Experimental plugins must be clearly labeled
3. All plugins must have fallback paths
4. Performance claims must be backed by benchmarks

## License

MIT License. See LICENSE file for details.
