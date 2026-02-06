/*++

Copyright (c) Microsoft. All rights reserved.

Module Name:

    WslPluginCapabilities.h

Abstract:

    Core capability definitions for WSL2 plugin system.
    This header defines hardware capabilities, stability tiers,
    and plugin descriptors used for capability negotiation.

    UPSTREAM CANDIDATE: This header is designed to be safe for
    inclusion in the main WSL2 codebase.

--*/

#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef _WIN32
#include <windows.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Version Information
// ============================================================================

#define WSL_PLUGIN_API_VERSION_MAJOR 2
#define WSL_PLUGIN_API_VERSION_MINOR 0
#define WSL_PLUGIN_API_VERSION_PATCH 0

// ============================================================================
// Hardware Capability Flags
// ============================================================================

typedef uint64_t WslHardwareCaps;

// CPU SIMD Features (bits 0-15)
#define WSL_HW_CAP_NONE             ((WslHardwareCaps)0)
#define WSL_HW_CAP_SSE42            ((WslHardwareCaps)(1ULL << 0))
#define WSL_HW_CAP_AVX              ((WslHardwareCaps)(1ULL << 1))
#define WSL_HW_CAP_AVX2             ((WslHardwareCaps)(1ULL << 2))
#define WSL_HW_CAP_FMA              ((WslHardwareCaps)(1ULL << 3))
#define WSL_HW_CAP_AVX512F          ((WslHardwareCaps)(1ULL << 4))
#define WSL_HW_CAP_AVX512BW         ((WslHardwareCaps)(1ULL << 5))
#define WSL_HW_CAP_AVX512VL         ((WslHardwareCaps)(1ULL << 6))
#define WSL_HW_CAP_AVX512VNNI       ((WslHardwareCaps)(1ULL << 7))
#define WSL_HW_CAP_AMX_TILE         ((WslHardwareCaps)(1ULL << 8))
#define WSL_HW_CAP_AMX_INT8         ((WslHardwareCaps)(1ULL << 9))
#define WSL_HW_CAP_AMX_BF16         ((WslHardwareCaps)(1ULL << 10))

// Storage Features (bits 16-23)
#define WSL_HW_CAP_NVME             ((WslHardwareCaps)(1ULL << 16))
#define WSL_HW_CAP_NVME_SPDK        ((WslHardwareCaps)(1ULL << 17))  // SPDK-bound NVMe
#define WSL_HW_CAP_PMEM             ((WslHardwareCaps)(1ULL << 18))  // Persistent Memory
#define WSL_HW_CAP_VIRTIO_FS        ((WslHardwareCaps)(1ULL << 19))
#define WSL_HW_CAP_VIRTIO_FS_DAX    ((WslHardwareCaps)(1ULL << 20))

// Accelerators (bits 24-31)
#define WSL_HW_CAP_NPU_AMD          ((WslHardwareCaps)(1ULL << 24))  // AMD XDNA
#define WSL_HW_CAP_NPU_INTEL        ((WslHardwareCaps)(1ULL << 25))  // Intel NPU
#define WSL_HW_CAP_NPU_QUALCOMM     ((WslHardwareCaps)(1ULL << 26))  // Qualcomm NPU
#define WSL_HW_CAP_GPU_CUDA         ((WslHardwareCaps)(1ULL << 27))
#define WSL_HW_CAP_GPU_ROCM         ((WslHardwareCaps)(1ULL << 28))
#define WSL_HW_CAP_GPU_OPENCL       ((WslHardwareCaps)(1ULL << 29))

// Memory Features (bits 32-39)
#define WSL_HW_CAP_HUGEPAGE_2MB     ((WslHardwareCaps)(1ULL << 32))
#define WSL_HW_CAP_HUGEPAGE_1GB     ((WslHardwareCaps)(1ULL << 33))
#define WSL_HW_CAP_NUMA             ((WslHardwareCaps)(1ULL << 34))

// Hyper-V Features (bits 40-47)
#define WSL_HW_CAP_HYPERV_SHM       ((WslHardwareCaps)(1ULL << 40))  // Shared memory
#define WSL_HW_CAP_HYPERV_DMA       ((WslHardwareCaps)(1ULL << 41))  // DMA remapping
#define WSL_HW_CAP_HYPERV_NESTED    ((WslHardwareCaps)(1ULL << 42))  // Nested virt

// Convenience macros
#define WSL_HW_CAP_AVX512_FULL      (WSL_HW_CAP_AVX512F | WSL_HW_CAP_AVX512BW | WSL_HW_CAP_AVX512VL)
#define WSL_HW_CAP_NPU_ANY          (WSL_HW_CAP_NPU_AMD | WSL_HW_CAP_NPU_INTEL | WSL_HW_CAP_NPU_QUALCOMM)
#define WSL_HW_CAP_GPU_ANY          (WSL_HW_CAP_GPU_CUDA | WSL_HW_CAP_GPU_ROCM | WSL_HW_CAP_GPU_OPENCL)

// ============================================================================
// Plugin Stability Tiers
// ============================================================================

typedef enum WslPluginTier {
    // Stock: Built-in to WSL, always available, cannot be disabled
    WSL_TIER_STOCK = 0,

    // Stable: Thoroughly tested, safe for production
    // Enabled by default if hardware requirements met
    WSL_TIER_STABLE = 1,

    // Beta: Feature complete, needs broader testing
    // Requires explicit opt-in via .wslconfig
    WSL_TIER_BETA = 2,

    // Experimental: May have bugs or cause instability
    // Requires explicit opt-in + acknowledgment
    WSL_TIER_EXPERIMENTAL = 3,

    // Dangerous: Known issues, expert users only
    // Requires explicit opt-in + danger acknowledgment
    WSL_TIER_DANGEROUS = 4,

} WslPluginTier;

// ============================================================================
// Plugin Categories
// ============================================================================

typedef enum WslPluginCategory {
    // Storage: File I/O, block devices, filesystems
    WSL_CATEGORY_STORAGE = 0,

    // IPC: Inter-process communication (9p replacement, shared memory)
    WSL_CATEGORY_IPC = 1,

    // Compute: CPU-bound operations (SIMD, path parsing)
    WSL_CATEGORY_COMPUTE = 2,

    // Prediction: Prefetching, caching hints
    WSL_CATEGORY_PREDICTION = 3,

    // Network: Networking stack optimizations
    WSL_CATEGORY_NETWORK = 4,

    // Kernel: Linux kernel customizations
    WSL_CATEGORY_KERNEL = 5,

    // Diagnostic: Monitoring, profiling
    WSL_CATEGORY_DIAGNOSTIC = 6,

    WSL_CATEGORY_COUNT

} WslPluginCategory;

// ============================================================================
// Plugin Descriptor
// ============================================================================

typedef struct WslPluginDescriptor {
    // Identity (required)
    const char* id;              // Unique ID, reverse-DNS style: "com.vendor.plugin-name"
    const char* name;            // Human-readable name
    const char* version;         // Semantic version: "1.2.3"
    const char* author;          // Author/vendor name

    // Classification (required)
    WslPluginCategory category;
    WslPluginTier tier;

    // Hardware requirements (required)
    WslHardwareCaps required_caps;  // Must have ALL of these
    WslHardwareCaps optional_caps;  // Can use if available

    // Version requirements (required)
    uint32_t min_wsl_version_major;
    uint32_t min_wsl_version_minor;
    uint32_t min_wsl_version_patch;

    // Priority and relationships (optional)
    uint32_t priority;           // Higher = preferred (0-1000)
    const char* replaces;        // Plugin ID this can replace (NULL if none)
    const char* const* conflicts; // NULL-terminated list of conflicting plugin IDs

    // Metadata (optional)
    const char* description;
    const char* documentation_url;
    const char* support_url;
    const char* license;         // SPDX identifier

} WslPluginDescriptor;

// ============================================================================
// Plugin Context (passed to plugins at initialization)
// ============================================================================

typedef struct WslPluginContext {
    // API version
    uint32_t api_version_major;
    uint32_t api_version_minor;
    uint32_t api_version_patch;

    // WSL version
    uint32_t wsl_version_major;
    uint32_t wsl_version_minor;
    uint32_t wsl_version_patch;

    // Hardware capabilities (detected at startup)
    WslHardwareCaps available_caps;

    // User preferences (from .wslconfig)
    WslPluginTier max_allowed_tier;
    bool telemetry_enabled;

    // Session information
    uint32_t session_id;
#ifdef _WIN32
    HANDLE user_token;
    PSID user_sid;
#endif

    // Logging callback
    void (*log)(int level, const char* format, ...);

    // Configuration accessor
    const char* (*get_config)(const char* plugin_id, const char* key);
    int64_t (*get_config_int)(const char* plugin_id, const char* key, int64_t default_val);
    bool (*get_config_bool)(const char* plugin_id, const char* key, bool default_val);

} WslPluginContext;

// Log levels
#define WSL_LOG_TRACE   0
#define WSL_LOG_DEBUG   1
#define WSL_LOG_INFO    2
#define WSL_LOG_WARN    3
#define WSL_LOG_ERROR   4
#define WSL_LOG_FATAL   5

// ============================================================================
// Capability Detection Functions
// ============================================================================

// Detect all hardware capabilities (call once at startup)
WslHardwareCaps WslDetectHardwareCapabilities(void);

// Check specific capabilities
static inline bool WslHasCapability(WslHardwareCaps caps, WslHardwareCaps required) {
    return (caps & required) == required;
}

static inline bool WslHasAnyCapability(WslHardwareCaps caps, WslHardwareCaps any_of) {
    return (caps & any_of) != 0;
}

// Get human-readable capability name
const char* WslGetCapabilityName(WslHardwareCaps cap);

// Get tier name
const char* WslGetTierName(WslPluginTier tier);

// Get category name
const char* WslGetCategoryName(WslPluginCategory category);

// ============================================================================
// CPU Feature Detection (x86_64)
// ============================================================================

#if defined(__x86_64__) || defined(_M_X64)

#include <immintrin.h>

#if defined(__GNUC__) || defined(__clang__)
#include <cpuid.h>

static inline WslHardwareCaps WslDetectCpuCapabilities(void) {
    WslHardwareCaps caps = WSL_HW_CAP_NONE;

    // Check SSE4.2
    if (__builtin_cpu_supports("sse4.2")) {
        caps |= WSL_HW_CAP_SSE42;
    }

    // Check AVX
    if (__builtin_cpu_supports("avx")) {
        caps |= WSL_HW_CAP_AVX;
    }

    // Check AVX2
    if (__builtin_cpu_supports("avx2")) {
        caps |= WSL_HW_CAP_AVX2;
    }

    // Check FMA
    if (__builtin_cpu_supports("fma")) {
        caps |= WSL_HW_CAP_FMA;
    }

    // Check AVX-512
    if (__builtin_cpu_supports("avx512f")) {
        caps |= WSL_HW_CAP_AVX512F;
    }
    if (__builtin_cpu_supports("avx512bw")) {
        caps |= WSL_HW_CAP_AVX512BW;
    }
    if (__builtin_cpu_supports("avx512vl")) {
        caps |= WSL_HW_CAP_AVX512VL;
    }

    // For AVX-512, also verify OS support for ZMM registers
    if (caps & WSL_HW_CAP_AVX512F) {
        unsigned int eax, ebx, ecx, edx;
        __cpuid_count(7, 0, eax, ebx, ecx, edx);

        // Check XCR0 for AVX-512 state support
        unsigned long long xcr0 = _xgetbv(0);
        if ((xcr0 & 0xE6) != 0xE6) {
            // OS doesn't support AVX-512, disable
            caps &= ~(WSL_HW_CAP_AVX512F | WSL_HW_CAP_AVX512BW | WSL_HW_CAP_AVX512VL);
        }
    }

    return caps;
}

#elif defined(_MSC_VER)

#include <intrin.h>

static inline WslHardwareCaps WslDetectCpuCapabilities(void) {
    WslHardwareCaps caps = WSL_HW_CAP_NONE;
    int cpuInfo[4];

    // Get max supported function
    __cpuid(cpuInfo, 0);
    int maxFunc = cpuInfo[0];

    if (maxFunc >= 1) {
        __cpuid(cpuInfo, 1);

        // SSE4.2 (ECX bit 20)
        if (cpuInfo[2] & (1 << 20)) caps |= WSL_HW_CAP_SSE42;

        // AVX (ECX bit 28)
        if (cpuInfo[2] & (1 << 28)) caps |= WSL_HW_CAP_AVX;

        // FMA (ECX bit 12)
        if (cpuInfo[2] & (1 << 12)) caps |= WSL_HW_CAP_FMA;
    }

    if (maxFunc >= 7) {
        __cpuidex(cpuInfo, 7, 0);

        // AVX2 (EBX bit 5)
        if (cpuInfo[1] & (1 << 5)) caps |= WSL_HW_CAP_AVX2;

        // AVX-512F (EBX bit 16)
        if (cpuInfo[1] & (1 << 16)) caps |= WSL_HW_CAP_AVX512F;

        // AVX-512BW (EBX bit 30)
        if (cpuInfo[1] & (1 << 30)) caps |= WSL_HW_CAP_AVX512BW;

        // AVX-512VL (EBX bit 31)
        if (cpuInfo[1] & (1 << 31)) caps |= WSL_HW_CAP_AVX512VL;

        // Verify OS support for AVX-512
        if (caps & WSL_HW_CAP_AVX512F) {
            unsigned __int64 xcr0 = _xgetbv(0);
            if ((xcr0 & 0xE6) != 0xE6) {
                caps &= ~(WSL_HW_CAP_AVX512F | WSL_HW_CAP_AVX512BW | WSL_HW_CAP_AVX512VL);
            }
        }
    }

    return caps;
}

#endif // compiler check

#else // not x86_64

static inline WslHardwareCaps WslDetectCpuCapabilities(void) {
    return WSL_HW_CAP_NONE;
}

#endif // architecture check

#ifdef __cplusplus
}
#endif
