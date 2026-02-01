# WSL2 Performance Plugin Architecture

## Design Document v1.0

### Executive Summary

This document describes a plugin architecture for WSL2 that enables SOTA performance optimizations (SPDK, AVX-512, NPU prefetching) while maintaining compatibility with conservative enterprise environments and legacy hardware.

**Key Principles:**
1. **Progressive Enhancement**: Stock WSL2 works unchanged; plugins add capabilities
2. **Graceful Degradation**: Missing hardware features trigger automatic fallback
3. **Safe by Default**: Experimental features require explicit opt-in
4. **Upstream-First**: Core abstractions designed for Microsoft acceptance

---

## Architecture Overview

```
                                    ┌─────────────────────────────────────────────┐
                                    │           WSL2 Core (Upstream)              │
                                    │  ┌─────────────────────────────────────────┐│
                                    │  │         Plugin Host (WslPluginHost)     ││
                                    │  │  • Plugin discovery & loading           ││
                                    │  │  • Capability negotiation               ││
                                    │  │  • Lifecycle management                 ││
                                    │  │  • Fallback orchestration               ││
                                    │  └─────────────────────────────────────────┘│
                                    │                      │                       │
                                    │    ┌─────────────────┼─────────────────┐    │
                                    │    ▼                 ▼                 ▼    │
                                    │  ┌─────┐         ┌─────┐           ┌─────┐ │
                                    │  │Store│         │ IPC │           │Comp-│ │
                                    │  │ API │         │ API │           │ute  │ │
                                    │  │     │         │     │           │ API │ │
                                    │  └──┬──┘         └──┬──┘           └──┬──┘ │
                                    └─────┼───────────────┼─────────────────┼────┘
                                          │               │                 │
          ┌───────────────────────────────┼───────────────┼─────────────────┼───────────────────────────────┐
          │                               │               │                 │                               │
          │  PLUGIN LAYER                 ▼               ▼                 ▼                               │
          │  ┌────────────────────────────────────────────────────────────────────────────────────────────┐│
          │  │                              Plugin Registry                                                ││
          │  │   ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐       ││
          │  │   │  Storage Plugins│  │   IPC Plugins   │  │ Compute Plugins │  │Prediction Plugins│       ││
          │  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       ││
          │  │   │  │SPDK NVMe  │  │  │  │SharedMem  │  │  │  │AVX-512    │  │  │  │NPU LSTM   │  │       ││
          │  │   │  │Passthrough│  │  │  │Zero-Copy  │  │  │  │SIMD Paths │  │  │  │Prefetch   │  │       ││
          │  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       ││
          │  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       ││
          │  │   │  │VirtIO-FS  │  │  │  │VirtIO-    │  │  │  │AVX2       │  │  │  │GPU ML     │  │       ││
          │  │   │  │DAX        │  │  │  │VSock      │  │  │  │Fallback   │  │  │  │Prefetch   │  │       ││
          │  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       ││
          │  │   │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │  │  ┌───────────┐  │       ││
          │  │   │  │VHDX       │  │  │  │9p         │  │  │  │Scalar     │  │  │  │LRU Cache  │  │       ││
          │  │   │  │(Stock)    │  │  │  │(Stock)    │  │  │  │(Stock)    │  │  │  │(Stock)    │  │       ││
          │  │   │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │  │  └───────────┘  │       ││
          │  │   └─────────────────┘  └─────────────────┘  └─────────────────┘  └─────────────────┘       ││
          │  └────────────────────────────────────────────────────────────────────────────────────────────┘│
          └───────────────────────────────────────────────────────────────────────────────────────────────┘

SELECTION LOGIC:
  1. User preference (.wslconfig)
  2. Hardware capability detection (CPUID, device enumeration)
  3. Stability tier (stable > beta > experimental)
  4. Performance benchmarks (A/B testing results)
```

---

## Core Interfaces

### 1. Plugin Capability System

```cpp
// WslPluginCapabilities.h - Core capability definitions (upstream candidate)

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Capability Flags
// ============================================================================

// Hardware capabilities (detected at runtime)
typedef enum WslHardwareCapability {
    WSL_HW_CAP_NONE             = 0,

    // CPU Features
    WSL_HW_CAP_AVX2             = (1 << 0),
    WSL_HW_CAP_AVX512F          = (1 << 1),
    WSL_HW_CAP_AVX512BW         = (1 << 2),
    WSL_HW_CAP_AVX512VL         = (1 << 3),
    WSL_HW_CAP_AMX              = (1 << 4),   // Intel Advanced Matrix Extensions

    // Storage Capabilities
    WSL_HW_CAP_NVME             = (1 << 8),
    WSL_HW_CAP_NVME_PASSTHROUGH = (1 << 9),   // SPDK-capable NVMe
    WSL_HW_CAP_PMEM             = (1 << 10),  // Persistent Memory

    // Accelerators
    WSL_HW_CAP_NPU              = (1 << 16),  // AMD XDNA / Intel NPU
    WSL_HW_CAP_GPU_COMPUTE      = (1 << 17),  // CUDA / ROCm capable
    WSL_HW_CAP_FPGA             = (1 << 18),

    // Memory
    WSL_HW_CAP_HUGEPAGES_2MB    = (1 << 24),
    WSL_HW_CAP_HUGEPAGES_1GB    = (1 << 25),

} WslHardwareCapability;

// Plugin stability tier
typedef enum WslPluginTier {
    WSL_TIER_STOCK        = 0,   // Built-in, always available
    WSL_TIER_STABLE       = 1,   // Thoroughly tested, safe for production
    WSL_TIER_BETA         = 2,   // Feature complete, needs more testing
    WSL_TIER_EXPERIMENTAL = 3,   // Bleeding edge, may cause issues
    WSL_TIER_DANGEROUS    = 4,   // Known issues, expert only
} WslPluginTier;

// Plugin categories
typedef enum WslPluginCategory {
    WSL_CATEGORY_STORAGE    = 0,
    WSL_CATEGORY_IPC        = 1,
    WSL_CATEGORY_COMPUTE    = 2,
    WSL_CATEGORY_PREDICTION = 3,
    WSL_CATEGORY_NETWORK    = 4,
    WSL_CATEGORY_KERNEL     = 5,
} WslPluginCategory;

// ============================================================================
// Plugin Descriptor
// ============================================================================

typedef struct WslPluginDescriptor {
    // Identity
    const char* id;              // Unique ID: "com.strix.spdk-storage"
    const char* name;            // Human-readable: "SPDK NVMe Passthrough"
    const char* version;         // Semver: "1.2.3"
    const char* author;          // "Microsoft" or "Community"

    // Classification
    WslPluginCategory category;
    WslPluginTier tier;

    // Requirements
    uint64_t required_hw_caps;   // Must have these hardware caps
    uint64_t optional_hw_caps;   // Can use these if available
    const char* min_wsl_version; // Minimum WSL version

    // Capabilities provided
    uint32_t priority;           // Higher = preferred when multiple match
    const char* replaces;        // Plugin ID this can replace (or NULL)

    // Metadata
    const char* documentation_url;
    const char* support_url;

} WslPluginDescriptor;

// ============================================================================
// Runtime Context
// ============================================================================

typedef struct WslPluginContext {
    // Detected hardware
    uint64_t available_hw_caps;

    // User preferences (from .wslconfig)
    WslPluginTier max_allowed_tier;
    const char* const* explicitly_enabled;   // NULL-terminated list
    const char* const* explicitly_disabled;  // NULL-terminated list

    // Session info
    uint32_t session_id;
    const wchar_t* distribution_name;

    // Telemetry (opt-in)
    bool telemetry_enabled;

} WslPluginContext;

// ============================================================================
// Capability Detection API
// ============================================================================

// Detect hardware capabilities (called once at startup)
typedef uint64_t (*WslDetectHardwareCapabilities)(void);

// Check if specific capability is available
static inline bool wsl_has_capability(uint64_t caps, WslHardwareCapability cap) {
    return (caps & cap) != 0;
}

// Get human-readable capability name
const char* WslGetCapabilityName(WslHardwareCapability cap);

#ifdef __cplusplus
}
#endif
```

### 2. Storage Plugin Interface

```cpp
// WslStoragePlugin.h - Storage abstraction layer

#pragma once
#include "WslPluginCapabilities.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Storage Operations
// ============================================================================

typedef enum WslStorageOpResult {
    WSL_STORAGE_OK = 0,
    WSL_STORAGE_ERROR_IO,
    WSL_STORAGE_ERROR_NOT_FOUND,
    WSL_STORAGE_ERROR_PERMISSION,
    WSL_STORAGE_ERROR_NO_SPACE,
    WSL_STORAGE_ERROR_NOT_SUPPORTED,
    WSL_STORAGE_ERROR_BUSY,
    WSL_STORAGE_ERROR_TIMEOUT,
} WslStorageOpResult;

// File handle (opaque to core)
typedef struct WslStorageHandle* WslStorageHandlePtr;

// Async completion callback
typedef void (*WslStorageCallback)(
    WslStorageOpResult result,
    size_t bytes_transferred,
    void* user_data
);

// ============================================================================
// Storage Plugin Interface v1
// ============================================================================

typedef struct WslStoragePluginV1 {
    // Plugin identity
    WslPluginDescriptor descriptor;

    // Lifecycle
    WslStorageOpResult (*initialize)(const WslPluginContext* ctx);
    void (*shutdown)(void);

    // Capability query
    bool (*supports_path)(const char* path);  // Can this plugin handle this path?
    uint64_t (*get_features)(void);           // DAX, async, etc.

    // Synchronous operations
    WslStorageOpResult (*open)(
        const char* path,
        uint32_t flags,
        uint32_t mode,
        WslStorageHandlePtr* out_handle
    );

    WslStorageOpResult (*close)(WslStorageHandlePtr handle);

    WslStorageOpResult (*read)(
        WslStorageHandlePtr handle,
        void* buffer,
        size_t size,
        uint64_t offset,
        size_t* bytes_read
    );

    WslStorageOpResult (*write)(
        WslStorageHandlePtr handle,
        const void* buffer,
        size_t size,
        uint64_t offset,
        size_t* bytes_written
    );

    WslStorageOpResult (*stat)(
        const char* path,
        struct WslFileStat* out_stat
    );

    WslStorageOpResult (*readdir)(
        const char* path,
        WslDirEntry* entries,
        size_t max_entries,
        size_t* out_count
    );

    // Asynchronous operations (optional, check get_features)
    WslStorageOpResult (*read_async)(
        WslStorageHandlePtr handle,
        void* buffer,
        size_t size,
        uint64_t offset,
        WslStorageCallback callback,
        void* user_data
    );

    WslStorageOpResult (*write_async)(
        WslStorageHandlePtr handle,
        const void* buffer,
        size_t size,
        uint64_t offset,
        WslStorageCallback callback,
        void* user_data
    );

    // Batched operations (optional, for io_uring-style efficiency)
    WslStorageOpResult (*submit_batch)(
        struct WslStorageOp* ops,
        size_t count,
        WslStorageCallback callback,
        void* user_data
    );

    // Direct memory access (optional, for DAX)
    WslStorageOpResult (*mmap)(
        WslStorageHandlePtr handle,
        uint64_t offset,
        size_t size,
        uint32_t prot,
        void** out_addr
    );

    void (*munmap)(void* addr, size_t size);

    // Statistics (for A/B testing)
    void (*get_statistics)(struct WslStorageStats* out_stats);

} WslStoragePluginV1;

// Feature flags for get_features()
#define WSL_STORAGE_FEATURE_ASYNC       (1 << 0)
#define WSL_STORAGE_FEATURE_BATCH       (1 << 1)
#define WSL_STORAGE_FEATURE_DAX         (1 << 2)
#define WSL_STORAGE_FEATURE_ZERO_COPY   (1 << 3)
#define WSL_STORAGE_FEATURE_PREFETCH    (1 << 4)

// ============================================================================
// Statistics for A/B Testing
// ============================================================================

typedef struct WslStorageStats {
    uint64_t reads_completed;
    uint64_t writes_completed;
    uint64_t bytes_read;
    uint64_t bytes_written;
    uint64_t cache_hits;
    uint64_t cache_misses;
    uint64_t avg_read_latency_ns;
    uint64_t avg_write_latency_ns;
    uint64_t p99_read_latency_ns;
    uint64_t p99_write_latency_ns;
    uint64_t errors;
} WslStorageStats;

#ifdef __cplusplus
}
#endif
```

### 3. Compute Plugin Interface

```cpp
// WslComputePlugin.h - SIMD/accelerator abstraction

#pragma once
#include "WslPluginCapabilities.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Compute Operations for Path Processing
// ============================================================================

typedef struct WslComputePluginV1 {
    WslPluginDescriptor descriptor;

    // Lifecycle
    bool (*initialize)(const WslPluginContext* ctx);
    void (*shutdown)(void);

    // Path operations (hot path - must be fast)
    size_t (*find_separator)(const char* str, size_t len);
    size_t (*find_last_separator)(const char* str, size_t len);
    void (*normalize_separators)(char* str, size_t len);
    size_t (*count_components)(const char* str, size_t len);

    // String operations
    int (*compare_paths)(const char* a, size_t a_len, const char* b, size_t b_len);
    uint64_t (*hash_path)(const char* path, size_t len);

    // Memory operations
    void (*memcpy_fast)(void* dst, const void* src, size_t len);
    void (*memset_fast)(void* dst, int val, size_t len);
    int (*memcmp_fast)(const void* a, const void* b, size_t len);

    // Bulk operations (for batch processing)
    void (*process_path_batch)(
        const char** paths,
        size_t* lengths,
        size_t count,
        uint64_t* out_hashes
    );

} WslComputePluginV1;

#ifdef __cplusplus
}
#endif
```

### 4. Prediction Plugin Interface

```cpp
// WslPredictionPlugin.h - Prefetch/caching prediction

#pragma once
#include "WslPluginCapabilities.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// I/O Prediction Interface
// ============================================================================

typedef struct WslFileAccessEvent {
    uint64_t timestamp_ns;
    uint64_t path_hash;
    const char* path;
    uint64_t offset;
    size_t size;
    uint8_t operation;  // 0=read, 1=write, 2=open, 3=stat
} WslFileAccessEvent;

typedef struct WslPrediction {
    uint64_t path_hash;
    const char* path;         // May be NULL if only hash known
    float confidence;         // 0.0 - 1.0
    uint64_t predicted_offset;
    size_t predicted_size;
} WslPrediction;

typedef struct WslPredictionPluginV1 {
    WslPluginDescriptor descriptor;

    // Lifecycle
    bool (*initialize)(const WslPluginContext* ctx);
    void (*shutdown)(void);

    // Event ingestion
    void (*record_access)(const WslFileAccessEvent* event);

    // Prediction
    size_t (*predict_next)(
        size_t max_predictions,
        WslPrediction* out_predictions
    );

    // Feedback (for model improvement)
    void (*report_hit)(uint64_t path_hash);
    void (*report_miss)(uint64_t path_hash);

    // Model management
    bool (*load_model)(const char* path);
    bool (*save_model)(const char* path);
    void (*train_incremental)(void);  // Online learning

    // Statistics
    float (*get_hit_rate)(void);
    uint64_t (*get_predictions_made)(void);

} WslPredictionPluginV1;

#ifdef __cplusplus
}
#endif
```

---

## Plugin Registration and Discovery

### 5. Plugin Host Implementation

```cpp
// WslPluginHost.h - Central plugin management

#pragma once
#include "WslPluginCapabilities.h"
#include "WslStoragePlugin.h"
#include "WslComputePlugin.h"
#include "WslPredictionPlugin.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Plugin Host API
// ============================================================================

typedef struct WslPluginHost* WslPluginHostPtr;

// Create and initialize the plugin host
WslPluginHostPtr WslPluginHostCreate(const WslPluginContext* ctx);
void WslPluginHostDestroy(WslPluginHostPtr host);

// Plugin discovery
int WslPluginHostScanDirectory(WslPluginHostPtr host, const wchar_t* path);
int WslPluginHostLoadPlugin(WslPluginHostPtr host, const wchar_t* dll_path);

// Get active plugins by category
const WslStoragePluginV1* WslPluginHostGetStoragePlugin(
    WslPluginHostPtr host,
    const char* path  // Path being accessed (for routing)
);

const WslComputePluginV1* WslPluginHostGetComputePlugin(WslPluginHostPtr host);

const WslPredictionPluginV1* WslPluginHostGetPredictionPlugin(WslPluginHostPtr host);

// Plugin enumeration
typedef void (*WslPluginEnumerator)(
    const WslPluginDescriptor* descriptor,
    bool is_active,
    void* user_data
);

void WslPluginHostEnumerate(
    WslPluginHostPtr host,
    WslPluginCategory category,
    WslPluginEnumerator callback,
    void* user_data
);

// A/B testing
void WslPluginHostEnableABTest(
    WslPluginHostPtr host,
    const char* plugin_a_id,
    const char* plugin_b_id,
    float a_percentage  // 0.0 - 1.0
);

void WslPluginHostGetABTestResults(
    WslPluginHostPtr host,
    const char* plugin_a_id,
    const char* plugin_b_id,
    WslStorageStats* out_a_stats,
    WslStorageStats* out_b_stats
);

// Rollback support
bool WslPluginHostSetFallback(
    WslPluginHostPtr host,
    WslPluginCategory category,
    const char* plugin_id
);

void WslPluginHostTriggerFallback(
    WslPluginHostPtr host,
    WslPluginCategory category,
    const char* reason
);

// Health monitoring
typedef enum WslPluginHealth {
    WSL_PLUGIN_HEALTH_OK,
    WSL_PLUGIN_HEALTH_DEGRADED,
    WSL_PLUGIN_HEALTH_FAILING,
    WSL_PLUGIN_HEALTH_CRASHED,
} WslPluginHealth;

WslPluginHealth WslPluginHostGetHealth(
    WslPluginHostPtr host,
    const char* plugin_id
);

#ifdef __cplusplus
}
#endif
```

---

## Configuration System

### 6. .wslconfig Extensions

```ini
# .wslconfig - Plugin configuration section

[wsl2]
# ... existing options ...

[experimental]
# Enable experimental plugins (default: false)
enableExperimentalPlugins = true

# Maximum stability tier to allow
# Options: stock, stable, beta, experimental
maxPluginTier = beta

[plugins]
# Explicitly enable specific plugins (overrides tier restriction)
enabled = com.strix.avx512-compute, com.strix.shared-memory-ipc

# Explicitly disable plugins
disabled = com.strix.spdk-storage

# Plugin-specific configuration
[plugins.com.strix.spdk-storage]
nvmeDevice = 0000:01:00.0
queueDepth = 256
hugepagesMB = 2048

[plugins.com.strix.npu-prefetch]
modelPath = %USERPROFILE%\.wsl\models\prefetch.onnx
minConfidence = 0.4
cacheSize = 512

[plugins.com.strix.shared-memory-ipc]
regionSize = 2147483648  # 2GB
useHugepages = true

[abtest]
# A/B testing configuration
enabled = true
storage.A = com.strix.shared-memory-ipc
storage.B = com.microsoft.9p
storage.splitPercentage = 50

[telemetry]
# Opt-in performance telemetry for plugin improvement
pluginMetrics = true
anonymousUsage = true
```

### 7. Runtime Configuration API

```cpp
// WslPluginConfig.h - Configuration management

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WslPluginConfig* WslPluginConfigPtr;

// Load configuration from .wslconfig
WslPluginConfigPtr WslPluginConfigLoad(void);
void WslPluginConfigFree(WslPluginConfigPtr config);

// Query configuration
bool WslPluginConfigIsEnabled(WslPluginConfigPtr config, const char* plugin_id);
bool WslPluginConfigIsDisabled(WslPluginConfigPtr config, const char* plugin_id);
WslPluginTier WslPluginConfigGetMaxTier(WslPluginConfigPtr config);

// Plugin-specific settings
const char* WslPluginConfigGetString(
    WslPluginConfigPtr config,
    const char* plugin_id,
    const char* key,
    const char* default_value
);

int64_t WslPluginConfigGetInt(
    WslPluginConfigPtr config,
    const char* plugin_id,
    const char* key,
    int64_t default_value
);

bool WslPluginConfigGetBool(
    WslPluginConfigPtr config,
    const char* plugin_id,
    const char* key,
    bool default_value
);

// A/B test configuration
bool WslPluginConfigGetABTest(
    WslPluginConfigPtr config,
    WslPluginCategory category,
    const char** out_plugin_a,
    const char** out_plugin_b,
    float* out_split
);

#ifdef __cplusplus
}
#endif
```

---

## Graceful Degradation

### 8. Fallback Chain Implementation

```cpp
// WslFallbackChain.h - Automatic fallback on failure

#pragma once
#include "WslStoragePlugin.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Fallback Chain
//
// Each category has a chain of plugins ordered by priority.
// If the active plugin fails, we automatically fall back.
// ============================================================================

typedef struct WslFallbackChain* WslFallbackChainPtr;

// Create a fallback chain for a category
WslFallbackChainPtr WslFallbackChainCreate(WslPluginCategory category);
void WslFallbackChainDestroy(WslFallbackChainPtr chain);

// Add plugins to chain (higher priority first)
void WslFallbackChainAdd(
    WslFallbackChainPtr chain,
    const WslPluginDescriptor* descriptor,
    void* plugin_interface
);

// Get current active plugin
void* WslFallbackChainGetActive(WslFallbackChainPtr chain);

// Report failure (triggers fallback)
typedef enum WslFailureType {
    WSL_FAILURE_CRASH,      // Plugin crashed
    WSL_FAILURE_TIMEOUT,    // Operation timed out
    WSL_FAILURE_ERROR_RATE, // Too many errors
    WSL_FAILURE_PERF,       // Performance degradation
} WslFailureType;

bool WslFallbackChainReportFailure(
    WslFallbackChainPtr chain,
    WslFailureType type,
    const char* details
);

// Check if we've fallen back from the preferred plugin
bool WslFallbackChainIsDegraded(WslFallbackChainPtr chain);
const char* WslFallbackChainGetActiveId(WslFallbackChainPtr chain);

// ============================================================================
// Automatic Health Monitoring
// ============================================================================

typedef struct WslHealthMonitor* WslHealthMonitorPtr;

WslHealthMonitorPtr WslHealthMonitorCreate(WslFallbackChainPtr chain);
void WslHealthMonitorDestroy(WslHealthMonitorPtr monitor);

// Call these on every operation
void WslHealthMonitorRecordLatency(WslHealthMonitorPtr monitor, uint64_t latency_ns);
void WslHealthMonitorRecordError(WslHealthMonitorPtr monitor, int error_code);
void WslHealthMonitorRecordSuccess(WslHealthMonitorPtr monitor);

// Configuration
void WslHealthMonitorSetThresholds(
    WslHealthMonitorPtr monitor,
    uint64_t max_p99_latency_ns,
    float max_error_rate,
    uint32_t crash_threshold
);

#ifdef __cplusplus
}
#endif
```

---

## Example Plugin Implementations

### 9. Stock Scalar Compute Plugin (Built-in Fallback)

```cpp
// stock_scalar_compute.cpp - Always-available fallback

#include "WslComputePlugin.h"
#include <cstring>

static const WslPluginDescriptor g_descriptor = {
    .id = "com.microsoft.scalar-compute",
    .name = "Scalar Compute (Stock)",
    .version = "1.0.0",
    .author = "Microsoft",
    .category = WSL_CATEGORY_COMPUTE,
    .tier = WSL_TIER_STOCK,
    .required_hw_caps = WSL_HW_CAP_NONE,  // Works on anything
    .optional_hw_caps = WSL_HW_CAP_NONE,
    .min_wsl_version = "2.0.0",
    .priority = 0,  // Lowest priority
    .replaces = NULL,
    .documentation_url = "https://learn.microsoft.com/wsl",
    .support_url = "https://github.com/microsoft/WSL/issues",
};

static bool scalar_initialize(const WslPluginContext* ctx) {
    (void)ctx;
    return true;  // Always succeeds
}

static void scalar_shutdown(void) {
    // Nothing to clean up
}

static size_t scalar_find_separator(const char* str, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '/' || str[i] == '\\') {
            return i;
        }
    }
    return (size_t)-1;
}

static size_t scalar_find_last_separator(const char* str, size_t len) {
    size_t last = (size_t)-1;
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '/' || str[i] == '\\') {
            last = i;
        }
    }
    return last;
}

static void scalar_normalize_separators(char* str, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '\\') {
            str[i] = '/';
        }
    }
}

static size_t scalar_count_components(const char* str, size_t len) {
    if (len == 0) return 0;

    size_t count = 0;
    bool in_component = false;

    for (size_t i = 0; i < len; ++i) {
        bool is_sep = (str[i] == '/' || str[i] == '\\');
        if (!is_sep && !in_component) {
            count++;
            in_component = true;
        } else if (is_sep) {
            in_component = false;
        }
    }

    return count;
}

// ... other scalar implementations ...

const WslComputePluginV1 g_scalar_compute_plugin = {
    .descriptor = g_descriptor,
    .initialize = scalar_initialize,
    .shutdown = scalar_shutdown,
    .find_separator = scalar_find_separator,
    .find_last_separator = scalar_find_last_separator,
    .normalize_separators = scalar_normalize_separators,
    .count_components = scalar_count_components,
    // ... etc ...
};
```

### 10. AVX-512 Compute Plugin (Optional Enhancement)

```cpp
// avx512_compute.cpp - High-performance optional plugin

#include "WslComputePlugin.h"
#include <immintrin.h>

static const WslPluginDescriptor g_descriptor = {
    .id = "com.strix.avx512-compute",
    .name = "AVX-512 SIMD Compute",
    .version = "1.0.0",
    .author = "Community",
    .category = WSL_CATEGORY_COMPUTE,
    .tier = WSL_TIER_STABLE,
    .required_hw_caps = WSL_HW_CAP_AVX512F | WSL_HW_CAP_AVX512BW,
    .optional_hw_caps = WSL_HW_CAP_AVX512VL,
    .min_wsl_version = "2.0.0",
    .priority = 100,  // Higher than scalar
    .replaces = "com.microsoft.scalar-compute",
    .documentation_url = "https://github.com/strix-turbo/docs",
    .support_url = "https://github.com/strix-turbo/issues",
};

static bool avx512_initialize(const WslPluginContext* ctx) {
    // Verify AVX-512 is actually available at runtime
    if (!(ctx->available_hw_caps & WSL_HW_CAP_AVX512F)) {
        return false;
    }
    if (!(ctx->available_hw_caps & WSL_HW_CAP_AVX512BW)) {
        return false;
    }
    return true;
}

static size_t avx512_find_separator(const char* str, size_t len) {
    const __m512i slash = _mm512_set1_epi8('/');
    const __m512i backslash = _mm512_set1_epi8('\\');

    size_t i = 0;
    for (; i + 64 <= len; i += 64) {
        __m512i chunk = _mm512_loadu_si512(str + i);
        __mmask64 mask = _mm512_cmpeq_epi8_mask(chunk, slash) |
                         _mm512_cmpeq_epi8_mask(chunk, backslash);
        if (mask) {
            return i + __builtin_ctzll(mask);
        }
    }

    // Scalar fallback for remainder
    for (; i < len; ++i) {
        if (str[i] == '/' || str[i] == '\\') {
            return i;
        }
    }

    return (size_t)-1;
}

// ... other AVX-512 implementations ...

// DLL export
extern "C" __declspec(dllexport)
const WslComputePluginV1* WslGetComputePlugin(void) {
    static const WslComputePluginV1 plugin = {
        .descriptor = g_descriptor,
        .initialize = avx512_initialize,
        .shutdown = avx512_shutdown,
        .find_separator = avx512_find_separator,
        // ... etc ...
    };
    return &plugin;
}
```

---

## Upstream Acceptance Strategy

### 11. Phased PR Plan

```
Phase 1: Core Abstractions (Weeks 1-2)
├── PR #1: WslPluginCapabilities.h
│   • Hardware capability detection
│   • Tier system
│   • Configuration schema
│   └── Status: Safe addition, no behavior change
│
├── PR #2: Plugin host infrastructure
│   • Plugin loading/unloading
│   • Fallback chain
│   • Health monitoring
│   └── Status: Foundational, well-tested
│
└── PR #3: Stock plugins as reference
    • Scalar compute plugin
    • Standard 9p IPC (wrapped in plugin interface)
    • VHDX storage (wrapped in plugin interface)
    └── Status: No behavior change, just refactoring

Phase 2: Stable Enhancements (Weeks 3-4)
├── PR #4: AVX2 compute plugin
│   • Lower risk than AVX-512
│   • Broader hardware support
│   └── Status: Opt-in performance improvement
│
├── PR #5: Enhanced metadata caching
│   • Works with existing 9p
│   • Measurable improvement
│   └── Status: Low risk, high value
│
└── PR #6: A/B testing framework
    • Telemetry infrastructure
    • Performance comparison tools
    └── Status: Enables data-driven decisions

Phase 3: Aggressive Optimizations (Out-of-tree initially)
├── Shared memory IPC plugin
│   • Replaces 9p for /mnt/c
│   • Requires extensive testing
│   └── Status: Community plugin, maybe upstream later
│
├── SPDK storage plugin
│   • Dedicated NVMe passthrough
│   • Enterprise feature
│   └── Status: Likely remains out-of-tree
│
├── NPU prediction plugin
│   • Requires ROCm/Intel OpenVINO
│   • Niche hardware
│   └── Status: Community plugin
│
└── AVX-512 compute plugin
    • Limited hardware support
    • Significant speedup where available
    └── Status: Community plugin, maybe upstream later
```

### 12. Out-of-Tree Plugin Maintenance

```
strix-turbo-plugins/
├── README.md                    # Installation and safety warnings
├── COMPATIBILITY.md            # Hardware/software requirements
├── plugins/
│   ├── spdk-storage/
│   │   ├── spdk_storage_plugin.cpp
│   │   ├── CMakeLists.txt
│   │   └── README.md
│   ├── shared-memory-ipc/
│   │   ├── shm_ipc_plugin.cpp
│   │   └── ...
│   ├── avx512-compute/
│   │   └── ...
│   └── npu-prefetch/
│       └── ...
├── installer/
│   ├── install.ps1             # Safe installation with checks
│   ├── uninstall.ps1           # Clean removal
│   └── verify.ps1              # Hardware compatibility check
└── tests/
    ├── integration/            # Full stack tests
    ├── benchmarks/             # Performance validation
    └── safety/                 # Crash/recovery tests
```

---

## Plugin Lifecycle Example

### 13. Complete Startup Sequence

```cpp
// Example: Plugin host startup sequence

void WslPluginHostStartup() {
    // 1. Detect hardware capabilities
    uint64_t hw_caps = DetectHardwareCapabilities();

    LogInfo("Detected hardware capabilities:");
    if (hw_caps & WSL_HW_CAP_AVX512F) LogInfo("  - AVX-512F");
    if (hw_caps & WSL_HW_CAP_AVX512BW) LogInfo("  - AVX-512BW");
    if (hw_caps & WSL_HW_CAP_NPU) LogInfo("  - NPU");
    if (hw_caps & WSL_HW_CAP_NVME_PASSTHROUGH) LogInfo("  - NVMe Passthrough");

    // 2. Load configuration
    auto config = WslPluginConfigLoad();
    WslPluginTier maxTier = WslPluginConfigGetMaxTier(config);
    LogInfo("Max allowed tier: %s", TierToString(maxTier));

    // 3. Build plugin context
    WslPluginContext ctx = {
        .available_hw_caps = hw_caps,
        .max_allowed_tier = maxTier,
        .explicitly_enabled = WslPluginConfigGetEnabled(config),
        .explicitly_disabled = WslPluginConfigGetDisabled(config),
    };

    // 4. Scan for plugins
    std::vector<PluginInfo> all_plugins;
    ScanPluginDirectory(L"%PROGRAMFILES%\\WSL\\Plugins", &all_plugins);
    ScanPluginDirectory(L"%USERPROFILE%\\.wsl\\plugins", &all_plugins);

    // 5. Filter by hardware and configuration
    std::vector<PluginInfo> eligible_plugins;
    for (auto& p : all_plugins) {
        // Check hardware requirements
        if ((p.descriptor.required_hw_caps & hw_caps) != p.descriptor.required_hw_caps) {
            LogInfo("Skipping %s: missing required hardware", p.descriptor.id);
            continue;
        }

        // Check tier restriction
        if (p.descriptor.tier > maxTier) {
            LogInfo("Skipping %s: tier %d > max %d",
                    p.descriptor.id, p.descriptor.tier, maxTier);
            continue;
        }

        // Check explicit disable
        if (IsExplicitlyDisabled(config, p.descriptor.id)) {
            LogInfo("Skipping %s: explicitly disabled", p.descriptor.id);
            continue;
        }

        eligible_plugins.push_back(p);
    }

    // 6. Sort by priority (highest first)
    std::sort(eligible_plugins.begin(), eligible_plugins.end(),
              [](auto& a, auto& b) { return a.descriptor.priority > b.descriptor.priority; });

    // 7. Initialize plugins and build fallback chains
    for (auto category : {WSL_CATEGORY_STORAGE, WSL_CATEGORY_COMPUTE,
                          WSL_CATEGORY_IPC, WSL_CATEGORY_PREDICTION}) {

        auto chain = WslFallbackChainCreate(category);

        for (auto& p : eligible_plugins) {
            if (p.descriptor.category != category) continue;

            bool success = p.interface->initialize(&ctx);
            if (success) {
                WslFallbackChainAdd(chain, &p.descriptor, p.interface);
                LogInfo("Activated %s (priority %d)", p.descriptor.id, p.descriptor.priority);
            } else {
                LogWarn("Failed to initialize %s", p.descriptor.id);
            }
        }

        // Verify at least one plugin active
        if (!WslFallbackChainGetActive(chain)) {
            LogError("No %s plugin available! Using built-in fallback.",
                     CategoryToString(category));
            // Activate stock plugin
            ActivateStockPlugin(chain, category);
        }

        g_fallback_chains[category] = chain;
    }

    // 8. Set up health monitoring
    for (auto& [cat, chain] : g_fallback_chains) {
        auto monitor = WslHealthMonitorCreate(chain);
        WslHealthMonitorSetThresholds(monitor,
            100 * 1000 * 1000,  // 100ms max p99 latency
            0.01,               // 1% max error rate
            3                   // 3 crashes trigger fallback
        );
        g_health_monitors[cat] = monitor;
    }

    // 9. Configure A/B testing if enabled
    if (WslPluginConfigGetABTest(config, WSL_CATEGORY_STORAGE,
                                  &plugin_a, &plugin_b, &split)) {
        WslPluginHostEnableABTest(g_host, plugin_a, plugin_b, split);
        LogInfo("A/B test: %s vs %s (%.0f%%/%.0f%%)",
                plugin_a, plugin_b, split * 100, (1 - split) * 100);
    }

    LogInfo("Plugin host startup complete. %zu plugins active.",
            CountActivePlugins());
}
```

### 14. Crash Recovery Example

```cpp
// Example: Automatic recovery when a plugin crashes

void OnPluginCrash(WslPluginCategory category, const char* plugin_id,
                   const char* crash_info) {
    LogError("Plugin %s crashed: %s", plugin_id, crash_info);

    // Report to health monitor
    auto monitor = g_health_monitors[category];
    WslHealthMonitorRecordCrash(monitor);

    // Check if we should fall back
    auto chain = g_fallback_chains[category];
    if (WslFallbackChainReportFailure(chain, WSL_FAILURE_CRASH, crash_info)) {
        const char* new_active = WslFallbackChainGetActiveId(chain);
        LogWarn("Fell back to %s", new_active);

        // Notify user (non-blocking)
        ShowNotification(L"WSL Plugin Fallback",
            L"Plugin %s encountered an error. Using %s instead.",
            plugin_id, new_active);

        // Log for telemetry
        if (g_telemetry_enabled) {
            TelemetryLog("plugin_fallback", {
                {"crashed_plugin", plugin_id},
                {"fallback_plugin", new_active},
                {"crash_info", crash_info},
            });
        }
    }

    // If no fallback available, we're in trouble
    if (!WslFallbackChainGetActive(chain)) {
        LogFatal("No fallback available for %s!", CategoryToString(category));
        // Last resort: disable plugin system entirely
        DisablePluginSystem(category);
    }
}
```

---

## Security Considerations

### 15. Plugin Signing and Trust

```cpp
// WslPluginSecurity.h

#pragma once

// Plugin trust levels
typedef enum WslPluginTrust {
    WSL_TRUST_MICROSOFT,    // Signed by Microsoft, full trust
    WSL_TRUST_PARTNER,      // Signed by approved partner
    WSL_TRUST_COMMUNITY,    // Community plugin, unsigned
    WSL_TRUST_BLOCKED,      // Known malicious, blocked
} WslPluginTrust;

// Verify plugin signature
WslPluginTrust WslVerifyPluginSignature(const wchar_t* dll_path);

// Check if plugin is allowed by policy
bool WslIsPluginAllowedByPolicy(const wchar_t* dll_path, WslPluginTrust trust);

// Enterprise policy: only allow Microsoft-signed plugins
// Set via Group Policy: HKLM\Software\Policies\Microsoft\WSL\PluginPolicy
// Values: "MicrosoftOnly", "PartnerAllowed", "CommunityAllowed"
```

---

## Summary

This plugin architecture provides:

1. **Progressive Enhancement**: Stock WSL2 is unaffected; plugins add optional capabilities
2. **Hardware Abstraction**: Plugins declare requirements; host ensures compatibility
3. **Graceful Degradation**: Automatic fallback chains prevent failures from breaking WSL
4. **Configuration Control**: Users control risk via `.wslconfig` tier settings
5. **A/B Testing**: Data-driven decisions about which plugins to promote
6. **Upstream Path**: Core abstractions are safe for Microsoft to accept
7. **Community Extensibility**: Out-of-tree plugins can experiment freely

The architecture balances innovation (SPDK, NPU, AVX-512) with stability (fallbacks, health monitoring, signing) to make aggressive optimizations safe for production use.
