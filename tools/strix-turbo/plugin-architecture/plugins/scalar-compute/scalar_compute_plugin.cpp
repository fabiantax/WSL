/*++

Module Name:

    scalar_compute_plugin.cpp

Abstract:

    Stock scalar compute plugin for WSL2.
    Provides baseline implementations that work on any CPU.
    This is the fallback when no SIMD acceleration is available.

    Tier: STOCK (built-in, always available)
    Requirements: None

--*/

#include "WslComputePlugin.h"
#include <cstring>
#include <cctype>

namespace wsl {
namespace plugins {

// ============================================================================
// Plugin Descriptor
// ============================================================================

static const WslPluginDescriptor g_descriptor = {
    .id = "com.microsoft.scalar-compute",
    .name = "Scalar Compute (Stock)",
    .version = "1.0.0",
    .author = "Microsoft",

    .category = WSL_CATEGORY_COMPUTE,
    .tier = WSL_TIER_STOCK,

    .required_caps = WSL_HW_CAP_NONE,  // Works on anything
    .optional_caps = WSL_HW_CAP_NONE,

    .min_wsl_version_major = 2,
    .min_wsl_version_minor = 0,
    .min_wsl_version_patch = 0,

    .priority = 0,  // Lowest priority - always fallback
    .replaces = nullptr,
    .conflicts = nullptr,

    .description = "Baseline scalar implementation of compute operations. "
                   "Works on any CPU but slower than SIMD alternatives.",
    .documentation_url = "https://learn.microsoft.com/wsl",
    .support_url = "https://github.com/microsoft/WSL/issues",
    .license = "MIT",
};

// ============================================================================
// Statistics
// ============================================================================

static struct ScalarStats {
    uint64_t operations_completed = 0;
    uint64_t bytes_processed = 0;
} g_stats;

// ============================================================================
// Lifecycle
// ============================================================================

static bool scalar_initialize(const WslPluginContext* ctx) {
    (void)ctx;
    g_stats = {};
    return true;  // Always succeeds
}

static void scalar_shutdown(void) {
    // Nothing to clean up
}

// ============================================================================
// Path Operations
// ============================================================================

static size_t scalar_find_separator(const char* str, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '/' || str[i] == '\\') {
            g_stats.operations_completed++;
            g_stats.bytes_processed += i + 1;
            return i;
        }
    }
    g_stats.operations_completed++;
    g_stats.bytes_processed += len;
    return static_cast<size_t>(-1);
}

static size_t scalar_find_last_separator(const char* str, size_t len) {
    size_t last = static_cast<size_t>(-1);
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '/' || str[i] == '\\') {
            last = i;
        }
    }
    g_stats.operations_completed++;
    g_stats.bytes_processed += len;
    return last;
}

static void scalar_normalize_separators(char* str, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        if (str[i] == '\\') {
            str[i] = '/';
        }
    }
    g_stats.operations_completed++;
    g_stats.bytes_processed += len;
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

    g_stats.operations_completed++;
    g_stats.bytes_processed += len;
    return count;
}

static const char* scalar_skip_leading_separators(const char* str, size_t len) {
    size_t i = 0;
    while (i < len && (str[i] == '/' || str[i] == '\\')) {
        i++;
    }
    return str + i;
}

static const char* scalar_next_component(
    const char* str,
    size_t remaining_len,
    size_t* out_len
) {
    // Skip leading separators
    size_t start = 0;
    while (start < remaining_len && (str[start] == '/' || str[start] == '\\')) {
        start++;
    }

    if (start >= remaining_len) {
        return nullptr;
    }

    // Find end of component
    size_t end = start;
    while (end < remaining_len && str[end] != '/' && str[end] != '\\') {
        end++;
    }

    if (out_len) {
        *out_len = end - start;
    }
    return str + start;
}

// ============================================================================
// String Operations
// ============================================================================

static int scalar_compare_paths_nocase(
    const char* a, size_t a_len,
    const char* b, size_t b_len
) {
    size_t min_len = a_len < b_len ? a_len : b_len;

    for (size_t i = 0; i < min_len; ++i) {
        int ca = std::tolower(static_cast<unsigned char>(a[i]));
        int cb = std::tolower(static_cast<unsigned char>(b[i]));

        // Treat / and \ as equivalent
        if (ca == '\\') ca = '/';
        if (cb == '\\') cb = '/';

        if (ca != cb) {
            return ca - cb;
        }
    }

    if (a_len < b_len) return -1;
    if (a_len > b_len) return 1;
    return 0;
}

static int scalar_compare_paths(
    const char* a, size_t a_len,
    const char* b, size_t b_len
) {
    size_t min_len = a_len < b_len ? a_len : b_len;
    int result = std::memcmp(a, b, min_len);

    if (result != 0) return result;
    if (a_len < b_len) return -1;
    if (a_len > b_len) return 1;
    return 0;
}

static bool scalar_path_starts_with(
    const char* path, size_t path_len,
    const char* prefix, size_t prefix_len
) {
    if (path_len < prefix_len) {
        return false;
    }
    return std::memcmp(path, prefix, prefix_len) == 0;
}

// FNV-1a hash
static uint64_t scalar_hash_path(const char* path, size_t len) {
    constexpr uint64_t FNV_OFFSET = 0xcbf29ce484222325ULL;
    constexpr uint64_t FNV_PRIME = 0x100000001b3ULL;

    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < len; ++i) {
        hash ^= static_cast<uint8_t>(path[i]);
        hash *= FNV_PRIME;
    }

    g_stats.operations_completed++;
    g_stats.bytes_processed += len;
    return hash;
}

// ============================================================================
// Memory Operations
// ============================================================================

static void* scalar_memcpy_fast(void* dst, const void* src, size_t len) {
    g_stats.bytes_processed += len;
    return std::memcpy(dst, src, len);
}

static void* scalar_memset_fast(void* dst, int val, size_t len) {
    g_stats.bytes_processed += len;
    return std::memset(dst, val, len);
}

static int scalar_memcmp_fast(const void* a, const void* b, size_t len) {
    g_stats.bytes_processed += len;
    return std::memcmp(a, b, len);
}

static void* scalar_memchr_fast(const void* ptr, int val, size_t len) {
    g_stats.bytes_processed += len;
    return std::memchr(ptr, val, len);
}

// ============================================================================
// Bulk Operations
// ============================================================================

static void scalar_hash_paths_batch(
    const char** paths,
    const size_t* lengths,
    size_t count,
    uint64_t* out_hashes
) {
    for (size_t i = 0; i < count; ++i) {
        out_hashes[i] = scalar_hash_path(paths[i], lengths[i]);
    }
}

static void scalar_normalize_batch(
    char** strings,
    const size_t* lengths,
    size_t count
) {
    for (size_t i = 0; i < count; ++i) {
        scalar_normalize_separators(strings[i], lengths[i]);
    }
}

// ============================================================================
// Statistics
// ============================================================================

static void scalar_get_stats(WslComputePluginV1::WslComputeStats* out_stats) {
    if (out_stats) {
        out_stats->operations_completed = g_stats.operations_completed;
        out_stats->bytes_processed = g_stats.bytes_processed;
        out_stats->simd_operations = 0;           // No SIMD in scalar plugin
        out_stats->scalar_fallbacks = g_stats.operations_completed;
        out_stats->total_cycles = 0;              // Not tracked
    }
}

static void scalar_reset_stats(void) {
    g_stats = {};
}

// ============================================================================
// Plugin Export
// ============================================================================

static const WslComputePluginV1 g_plugin = {
    .descriptor = g_descriptor,

    .initialize = scalar_initialize,
    .shutdown = scalar_shutdown,

    .find_separator = scalar_find_separator,
    .find_last_separator = scalar_find_last_separator,
    .normalize_separators = scalar_normalize_separators,
    .count_components = scalar_count_components,
    .skip_leading_separators = scalar_skip_leading_separators,
    .next_component = scalar_next_component,

    .compare_paths_nocase = scalar_compare_paths_nocase,
    .compare_paths = scalar_compare_paths,
    .path_starts_with = scalar_path_starts_with,
    .hash_path = scalar_hash_path,

    .memcpy_fast = scalar_memcpy_fast,
    .memset_fast = scalar_memset_fast,
    .memcmp_fast = scalar_memcmp_fast,
    .memchr_fast = scalar_memchr_fast,

    .hash_paths_batch = scalar_hash_paths_batch,
    .normalize_batch = scalar_normalize_batch,

    .get_stats = scalar_get_stats,
    .reset_stats = scalar_reset_stats,
};

} // namespace plugins
} // namespace wsl

// Built-in plugin - exported directly, not as DLL
const WslComputePluginV1* WslGetScalarComputePlugin(void) {
    return &wsl::plugins::g_plugin;
}

// Also provide DLL export for consistency
extern "C" __declspec(dllexport)
const WslComputePluginV1* WslGetComputePluginV1(void) {
    return &wsl::plugins::g_plugin;
}
