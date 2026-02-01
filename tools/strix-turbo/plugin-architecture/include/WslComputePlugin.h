/*++

Copyright (c) Microsoft. All rights reserved.

Module Name:

    WslComputePlugin.h

Abstract:

    Compute plugin interface for WSL2.
    Plugins implementing this interface provide optimized
    implementations of CPU-bound operations (SIMD path parsing, etc.)

--*/

#pragma once

#include "WslPluginCapabilities.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Compute Plugin Interface v1
// ============================================================================

#define WSL_COMPUTE_PLUGIN_VERSION 1

typedef struct WslComputePluginV1 {
    // ========================================================================
    // Identity
    // ========================================================================
    WslPluginDescriptor descriptor;

    // ========================================================================
    // Lifecycle
    // ========================================================================

    // Initialize the plugin. Returns true on success.
    bool (*initialize)(const WslPluginContext* ctx);

    // Shutdown the plugin.
    void (*shutdown)(void);

    // ========================================================================
    // Path Operations (Hot Path - Performance Critical)
    // ========================================================================

    // Find first occurrence of '/' or '\' in string.
    // Returns index of separator, or (size_t)-1 if not found.
    size_t (*find_separator)(const char* str, size_t len);

    // Find last occurrence of '/' or '\' in string.
    // Returns index of separator, or (size_t)-1 if not found.
    size_t (*find_last_separator)(const char* str, size_t len);

    // Normalize path separators: replace all '\' with '/'.
    // Modifies string in-place.
    void (*normalize_separators)(char* str, size_t len);

    // Count path components (segments separated by / or \).
    // Example: "/usr/local/bin" has 3 components.
    size_t (*count_components)(const char* str, size_t len);

    // Skip leading separators and return pointer to first component.
    const char* (*skip_leading_separators)(const char* str, size_t len);

    // Get next path component.
    // Returns pointer to component start, sets *out_len to component length.
    // Returns NULL when no more components.
    const char* (*next_component)(
        const char* str,
        size_t remaining_len,
        size_t* out_len
    );

    // ========================================================================
    // String Operations
    // ========================================================================

    // Case-insensitive path comparison (for Windows paths).
    // Returns <0 if a<b, 0 if equal, >0 if a>b.
    int (*compare_paths_nocase)(
        const char* a, size_t a_len,
        const char* b, size_t b_len
    );

    // Case-sensitive path comparison (for Linux paths).
    int (*compare_paths)(
        const char* a, size_t a_len,
        const char* b, size_t b_len
    );

    // Check if path starts with prefix.
    bool (*path_starts_with)(
        const char* path, size_t path_len,
        const char* prefix, size_t prefix_len
    );

    // Hash path for cache lookup (FNV-1a recommended).
    uint64_t (*hash_path)(const char* path, size_t len);

    // ========================================================================
    // Memory Operations
    // ========================================================================

    // Optimized memory copy.
    void* (*memcpy_fast)(void* dst, const void* src, size_t len);

    // Optimized memory set.
    void* (*memset_fast)(void* dst, int val, size_t len);

    // Optimized memory compare.
    int (*memcmp_fast)(const void* a, const void* b, size_t len);

    // Find byte in memory (like memchr).
    void* (*memchr_fast)(const void* ptr, int val, size_t len);

    // ========================================================================
    // Bulk Operations (for batch processing)
    // ========================================================================

    // Hash multiple paths in one call.
    void (*hash_paths_batch)(
        const char** paths,
        const size_t* lengths,
        size_t count,
        uint64_t* out_hashes
    );

    // Normalize separators in multiple strings.
    void (*normalize_batch)(
        char** strings,
        const size_t* lengths,
        size_t count
    );

    // ========================================================================
    // Statistics
    // ========================================================================

    typedef struct WslComputeStats {
        uint64_t operations_completed;
        uint64_t bytes_processed;
        uint64_t simd_operations;       // Operations using SIMD
        uint64_t scalar_fallbacks;      // Operations using scalar fallback
        uint64_t total_cycles;          // CPU cycles (if available)
    } WslComputeStats;

    void (*get_stats)(WslComputeStats* out_stats);
    void (*reset_stats)(void);

} WslComputePluginV1;

// ============================================================================
// Plugin Export
// ============================================================================

#define WSL_COMPUTE_PLUGIN_EXPORT "WslGetComputePluginV1"
typedef const WslComputePluginV1* (*WslGetComputePluginFunc)(void);

#ifdef __cplusplus
}
#endif
