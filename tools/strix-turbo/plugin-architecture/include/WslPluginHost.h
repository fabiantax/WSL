/*++

Copyright (c) Microsoft. All rights reserved.

Module Name:

    WslPluginHost.h

Abstract:

    Plugin host for WSL2.
    Manages plugin discovery, loading, capability negotiation,
    fallback chains, and health monitoring.

--*/

#pragma once

#include "WslPluginCapabilities.h"
#include "WslStoragePlugin.h"
#include "WslComputePlugin.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Plugin Host Handle
// ============================================================================

typedef struct WslPluginHost* WslPluginHostPtr;

// ============================================================================
// Plugin Host Lifecycle
// ============================================================================

// Create plugin host with the given context
WslPluginHostPtr WslPluginHostCreate(const WslPluginContext* ctx);

// Destroy plugin host and unload all plugins
void WslPluginHostDestroy(WslPluginHostPtr host);

// ============================================================================
// Plugin Discovery and Loading
// ============================================================================

// Scan a directory for plugins (.dll files with proper exports)
// Returns number of plugins found
int WslPluginHostScanDirectory(
    WslPluginHostPtr host,
    const wchar_t* directory_path
);

// Load a specific plugin
typedef enum WslPluginLoadResult {
    WSL_PLUGIN_LOAD_OK = 0,
    WSL_PLUGIN_LOAD_NOT_FOUND,
    WSL_PLUGIN_LOAD_INVALID,
    WSL_PLUGIN_LOAD_VERSION_MISMATCH,
    WSL_PLUGIN_LOAD_HW_NOT_SUPPORTED,
    WSL_PLUGIN_LOAD_TIER_TOO_HIGH,
    WSL_PLUGIN_LOAD_DISABLED,
    WSL_PLUGIN_LOAD_INIT_FAILED,
    WSL_PLUGIN_LOAD_SIGNATURE_INVALID,
} WslPluginLoadResult;

WslPluginLoadResult WslPluginHostLoadPlugin(
    WslPluginHostPtr host,
    const wchar_t* plugin_path,
    const char** out_error_message
);

// Unload a specific plugin
bool WslPluginHostUnloadPlugin(
    WslPluginHostPtr host,
    const char* plugin_id
);

// ============================================================================
// Active Plugin Access
// ============================================================================

// Get the active storage plugin for a given path
// Returns NULL if no plugin available (should never happen - stock is fallback)
const WslStoragePluginV1* WslPluginHostGetStoragePlugin(
    WslPluginHostPtr host,
    const char* path
);

// Get the active compute plugin
const WslComputePluginV1* WslPluginHostGetComputePlugin(
    WslPluginHostPtr host
);

// ============================================================================
// Plugin Enumeration
// ============================================================================

typedef struct WslPluginInfo {
    const WslPluginDescriptor* descriptor;
    bool is_loaded;
    bool is_active;
    bool hw_requirements_met;
    const wchar_t* dll_path;
} WslPluginInfo;

typedef void (*WslPluginEnumerator)(
    const WslPluginInfo* info,
    void* user_data
);

// Enumerate all discovered plugins
void WslPluginHostEnumerate(
    WslPluginHostPtr host,
    WslPluginCategory category,
    WslPluginEnumerator callback,
    void* user_data
);

// Get info for a specific plugin
bool WslPluginHostGetPluginInfo(
    WslPluginHostPtr host,
    const char* plugin_id,
    WslPluginInfo* out_info
);

// ============================================================================
// Fallback Management
// ============================================================================

// Manually set the active plugin for a category
// Returns false if plugin not loaded or not compatible
bool WslPluginHostSetActivePlugin(
    WslPluginHostPtr host,
    WslPluginCategory category,
    const char* plugin_id
);

// Trigger fallback to next available plugin
// Returns the ID of the new active plugin, or NULL if no fallback available
const char* WslPluginHostTriggerFallback(
    WslPluginHostPtr host,
    WslPluginCategory category,
    const char* reason
);

// Check if we're running on a fallback plugin
bool WslPluginHostIsDegraded(
    WslPluginHostPtr host,
    WslPluginCategory category
);

// Get the ID of the preferred plugin (highest priority that we fell back from)
const char* WslPluginHostGetPreferredPlugin(
    WslPluginHostPtr host,
    WslPluginCategory category
);

// ============================================================================
// Health Monitoring
// ============================================================================

typedef enum WslPluginHealth {
    WSL_PLUGIN_HEALTH_UNKNOWN = 0,
    WSL_PLUGIN_HEALTH_OK,
    WSL_PLUGIN_HEALTH_DEGRADED,
    WSL_PLUGIN_HEALTH_FAILING,
    WSL_PLUGIN_HEALTH_CRASHED,
} WslPluginHealth;

WslPluginHealth WslPluginHostGetHealth(
    WslPluginHostPtr host,
    const char* plugin_id
);

// Report an error for a plugin (may trigger automatic fallback)
void WslPluginHostReportError(
    WslPluginHostPtr host,
    const char* plugin_id,
    int error_code,
    const char* message
);

// Report latency observation (for performance monitoring)
void WslPluginHostReportLatency(
    WslPluginHostPtr host,
    const char* plugin_id,
    uint64_t latency_ns
);

// Set thresholds for automatic fallback
void WslPluginHostSetHealthThresholds(
    WslPluginHostPtr host,
    WslPluginCategory category,
    uint64_t max_p99_latency_ns,
    double max_error_rate,
    int max_crashes_before_disable
);

// ============================================================================
// A/B Testing
// ============================================================================

// Enable A/B testing between two plugins
bool WslPluginHostEnableABTest(
    WslPluginHostPtr host,
    WslPluginCategory category,
    const char* plugin_a_id,
    const char* plugin_b_id,
    float plugin_a_percentage  // 0.0 - 1.0
);

// Disable A/B testing
void WslPluginHostDisableABTest(
    WslPluginHostPtr host,
    WslPluginCategory category
);

// Get A/B test results
typedef struct WslABTestResults {
    const char* plugin_a_id;
    const char* plugin_b_id;
    float plugin_a_percentage;

    // Plugin A stats
    WslStorageStats plugin_a_stats;

    // Plugin B stats
    WslStorageStats plugin_b_stats;

    // Comparison metrics
    double latency_improvement_percent;  // Positive = A is faster
    double throughput_improvement_percent;
    double error_rate_difference;

    // Sample counts
    uint64_t plugin_a_samples;
    uint64_t plugin_b_samples;

} WslABTestResults;

bool WslPluginHostGetABTestResults(
    WslPluginHostPtr host,
    WslPluginCategory category,
    WslABTestResults* out_results
);

// ============================================================================
// Telemetry
// ============================================================================

// Export plugin performance data for telemetry
typedef struct WslPluginTelemetry {
    const char* plugin_id;
    const char* plugin_version;
    WslPluginHealth health;

    // Uptime
    uint64_t uptime_seconds;
    uint64_t fallback_count;

    // Performance summary
    uint64_t operations_completed;
    double avg_latency_us;
    double p99_latency_us;
    double error_rate;

} WslPluginTelemetry;

int WslPluginHostExportTelemetry(
    WslPluginHostPtr host,
    WslPluginTelemetry* out_data,
    int max_count
);

// ============================================================================
// Configuration Hot Reload
// ============================================================================

// Reload configuration from .wslconfig
// May change active plugins, but won't unload currently-in-use plugins
void WslPluginHostReloadConfig(WslPluginHostPtr host);

// Get current configuration value
const char* WslPluginHostGetConfig(
    WslPluginHostPtr host,
    const char* plugin_id,
    const char* key
);

#ifdef __cplusplus
}
#endif
