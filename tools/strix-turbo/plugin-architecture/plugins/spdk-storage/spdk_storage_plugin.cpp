/*++

Module Name:

    spdk_storage_plugin.cpp

Abstract:

    SPDK-based storage plugin for WSL2.
    Provides direct NVMe access bypassing the kernel storage stack
    for maximum performance on dedicated NVMe drives.

    Tier: EXPERIMENTAL
    Requirements: WSL_HW_CAP_NVME_SPDK

--*/

#include "WslStoragePlugin.h"
#include "spdk_integration.h"  // From strix-turbo

#include <mutex>
#include <unordered_map>
#include <string>
#include <memory>
#include <atomic>
#include <chrono>

namespace strix {
namespace plugins {

// ============================================================================
// Plugin Configuration
// ============================================================================

static struct SPDKConfig {
    std::string nvme_pci_address;
    uint32_t queue_depth = 256;
    uint32_t num_queues = 16;
    size_t hugepages_mb = 2048;
    bool use_polling = true;

    // Path prefix this plugin handles
    std::string path_prefix = "/mnt/spdk";

} g_config;

// ============================================================================
// Plugin State
// ============================================================================

static struct SPDKState {
    bool initialized = false;
    std::unique_ptr<strix::spdk::NVMeController> controller;
    std::unique_ptr<strix::spdk::NVMeController::BufferPool> buffer_pool;

    // Statistics
    WslStorageStats stats = {};
    std::atomic<uint64_t> operations_in_flight{0};

    // Handle management
    std::mutex handles_mutex;
    std::unordered_map<uint64_t, std::shared_ptr<strix::spdk::NVMeFile>> handles;
    std::atomic<uint64_t> next_handle_id{1};

    // Timing
    std::chrono::steady_clock::time_point start_time;

} g_state;

// ============================================================================
// Plugin Descriptor
// ============================================================================

static const WslPluginDescriptor g_descriptor = {
    .id = "com.strix.spdk-storage",
    .name = "SPDK NVMe Passthrough",
    .version = "1.0.0",
    .author = "Strix Community",

    .category = WSL_CATEGORY_STORAGE,
    .tier = WSL_TIER_EXPERIMENTAL,

    .required_caps = WSL_HW_CAP_NVME_SPDK,
    .optional_caps = WSL_HW_CAP_HUGEPAGE_2MB | WSL_HW_CAP_HUGEPAGE_1GB,

    .min_wsl_version_major = 2,
    .min_wsl_version_minor = 3,
    .min_wsl_version_patch = 0,

    .priority = 500,  // Higher than VirtIO-FS, lower than future PMEM
    .replaces = "com.microsoft.vhdx-storage",
    .conflicts = nullptr,

    .description = "Direct NVMe access via SPDK for maximum I/O performance. "
                   "Requires a dedicated NVMe drive bound to SPDK.",
    .documentation_url = "https://github.com/strix-turbo/spdk-plugin/docs",
    .support_url = "https://github.com/strix-turbo/spdk-plugin/issues",
    .license = "MIT",
};

// ============================================================================
// Helper Functions
// ============================================================================

static void UpdateLatencyHistogram(uint64_t* histogram, uint64_t latency_ns) {
    if (latency_ns < 1000) {
        histogram[0]++;          // < 1us
    } else if (latency_ns < 10000) {
        histogram[1]++;          // 1-10us
    } else if (latency_ns < 100000) {
        histogram[2]++;          // 10-100us
    } else if (latency_ns < 1000000) {
        histogram[3]++;          // 100us-1ms
    } else if (latency_ns < 10000000) {
        histogram[4]++;          // 1-10ms
    } else {
        histogram[5]++;          // > 10ms
    }
}

static inline uint64_t GetNanoseconds() {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
}

// ============================================================================
// Lifecycle Implementation
// ============================================================================

static WslStorageResult spdk_initialize(const WslPluginContext* ctx) {
    if (g_state.initialized) {
        return WSL_STORAGE_OK;
    }

    // Load configuration
    if (auto val = ctx->get_config(g_descriptor.id, "nvmeDevice")) {
        g_config.nvme_pci_address = val;
    }
    g_config.queue_depth = static_cast<uint32_t>(
        ctx->get_config_int(g_descriptor.id, "queueDepth", 256));
    g_config.hugepages_mb = static_cast<size_t>(
        ctx->get_config_int(g_descriptor.id, "hugepagesMB", 2048));
    g_config.path_prefix = ctx->get_config(g_descriptor.id, "pathPrefix") ?: "/mnt/spdk";

    ctx->log(WSL_LOG_INFO, "SPDK plugin initializing with device=%s, queues=%u, hugepages=%zuMB",
             g_config.nvme_pci_address.c_str(),
             g_config.queue_depth,
             g_config.hugepages_mb);

    // Check for SPDK availability
    if (!strix::spdk::is_spdk_available()) {
        ctx->log(WSL_LOG_ERROR, "SPDK environment not available");
        return WSL_STORAGE_ERROR;
    }

    // Configure and initialize controller
    strix::spdk::NVMeConfig nvme_config = {
        .pci_address = g_config.nvme_pci_address.empty() ? nullptr : g_config.nvme_pci_address.c_str(),
        .queue_depth = g_config.queue_depth,
        .num_queues = g_config.num_queues,
        .hugepage_mem_mb = g_config.hugepages_mb,
        .use_polling = g_config.use_polling,
    };

    g_state.controller = std::make_unique<strix::spdk::NVMeController>();

    if (!g_state.controller->initialize(nvme_config)) {
        ctx->log(WSL_LOG_ERROR, "Failed to initialize SPDK controller: %s",
                 g_state.controller->last_error());
        g_state.controller.reset();
        return WSL_STORAGE_ERROR;
    }

    // Create buffer pool for zero-allocation I/O
    g_state.buffer_pool = std::make_unique<strix::spdk::NVMeController::BufferPool>(
        *g_state.controller,
        64 * 1024,  // 64KB buffers
        1024        // 1024 buffers
    );

    // Log device info
    const auto& info = g_state.controller->device_info();
    ctx->log(WSL_LOG_INFO, "SPDK initialized: %s %s, capacity=%llu GB",
             info.model, info.serial,
             g_state.controller->total_bytes() / (1024ULL * 1024 * 1024));

    g_state.start_time = std::chrono::steady_clock::now();
    g_state.initialized = true;

    return WSL_STORAGE_OK;
}

static void spdk_shutdown(void) {
    if (!g_state.initialized) {
        return;
    }

    // Wait for in-flight operations
    while (g_state.operations_in_flight > 0) {
        g_state.controller->poll_all_queues(32);
    }

    // Close all open handles
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        g_state.handles.clear();
    }

    // Cleanup
    g_state.buffer_pool.reset();
    if (g_state.controller) {
        g_state.controller->shutdown();
        g_state.controller.reset();
    }

    g_state.initialized = false;
}

// ============================================================================
// Capability Query
// ============================================================================

static bool spdk_supports_path(const char* path) {
    // Only handle paths under our configured prefix
    return strncmp(path, g_config.path_prefix.c_str(), g_config.path_prefix.size()) == 0;
}

static WslStorageFeatures spdk_get_features(void) {
    return WSL_STORAGE_FEAT_ASYNC |
           WSL_STORAGE_FEAT_BATCH |
           WSL_STORAGE_FEAT_ZERO_COPY |
           WSL_STORAGE_FEAT_PREFETCH;
}

// ============================================================================
// File Operations
// ============================================================================

static WslStorageResult spdk_open(
    const char* path,
    uint32_t flags,
    uint32_t mode,
    WslStorageHandlePtr* out_handle
) {
    if (!g_state.initialized || !out_handle) {
        return WSL_STORAGE_ERROR;
    }

    // In a real implementation, we'd translate path to LBA ranges
    // For now, this is a simplified demonstration

    // Allocate handle
    uint64_t handle_id = g_state.next_handle_id.fetch_add(1);

    // Create NVMe file object (maps path to LBA region)
    // This is simplified - real implementation would manage an on-disk filesystem
    auto file = std::make_shared<strix::spdk::NVMeFile>(
        *g_state.controller,
        0,                              // start_lba - would be looked up
        1024 * 1024 / 512               // size_blocks - would be from metadata
    );

    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        g_state.handles[handle_id] = file;
    }

    *out_handle = reinterpret_cast<WslStorageHandlePtr>(handle_id);
    return WSL_STORAGE_OK;
}

static WslStorageResult spdk_close(WslStorageHandlePtr handle) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);

    std::lock_guard<std::mutex> lock(g_state.handles_mutex);
    auto it = g_state.handles.find(handle_id);
    if (it == g_state.handles.end()) {
        return WSL_STORAGE_ERROR_NOT_FOUND;
    }

    g_state.handles.erase(it);
    return WSL_STORAGE_OK;
}

static WslStorageResult spdk_read(
    WslStorageHandlePtr handle,
    void* buffer,
    size_t size,
    uint64_t offset,
    size_t* out_bytes_read
) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);
    uint64_t start_ns = GetNanoseconds();

    std::shared_ptr<strix::spdk::NVMeFile> file;
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        auto it = g_state.handles.find(handle_id);
        if (it == g_state.handles.end()) {
            return WSL_STORAGE_ERROR_NOT_FOUND;
        }
        file = it->second;
    }

    // Perform read
    ssize_t result = file->read(buffer, size, offset);

    uint64_t latency_ns = GetNanoseconds() - start_ns;

    if (result < 0) {
        g_state.stats.errors++;
        return WSL_STORAGE_ERROR_IO;
    }

    // Update stats
    g_state.stats.reads_completed++;
    g_state.stats.bytes_read += result;
    g_state.stats.total_read_latency_ns += latency_ns;
    UpdateLatencyHistogram(g_state.stats.read_latency_histogram, latency_ns);

    if (out_bytes_read) {
        *out_bytes_read = static_cast<size_t>(result);
    }

    return WSL_STORAGE_OK;
}

static WslStorageResult spdk_write(
    WslStorageHandlePtr handle,
    const void* buffer,
    size_t size,
    uint64_t offset,
    size_t* out_bytes_written
) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);
    uint64_t start_ns = GetNanoseconds();

    std::shared_ptr<strix::spdk::NVMeFile> file;
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        auto it = g_state.handles.find(handle_id);
        if (it == g_state.handles.end()) {
            return WSL_STORAGE_ERROR_NOT_FOUND;
        }
        file = it->second;
    }

    // Perform write
    ssize_t result = file->write(buffer, size, offset);

    uint64_t latency_ns = GetNanoseconds() - start_ns;

    if (result < 0) {
        g_state.stats.errors++;
        return WSL_STORAGE_ERROR_IO;
    }

    // Update stats
    g_state.stats.writes_completed++;
    g_state.stats.bytes_written += result;
    g_state.stats.total_write_latency_ns += latency_ns;
    UpdateLatencyHistogram(g_state.stats.write_latency_histogram, latency_ns);

    if (out_bytes_written) {
        *out_bytes_written = static_cast<size_t>(result);
    }

    return WSL_STORAGE_OK;
}

static WslStorageResult spdk_fsync(WslStorageHandlePtr handle) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);

    std::shared_ptr<strix::spdk::NVMeFile> file;
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        auto it = g_state.handles.find(handle_id);
        if (it == g_state.handles.end()) {
            return WSL_STORAGE_ERROR_NOT_FOUND;
        }
        file = it->second;
    }

    int result = file->fsync();
    return result == 0 ? WSL_STORAGE_OK : WSL_STORAGE_ERROR_IO;
}

// ============================================================================
// Async Operations
// ============================================================================

struct AsyncContext {
    WslStorageCallback callback;
    void* user_data;
    uint64_t start_ns;
    bool is_write;
};

static void spdk_async_completion(strix::spdk::IOResult result, void* user_data) {
    auto* ctx = static_cast<AsyncContext*>(user_data);
    uint64_t latency_ns = GetNanoseconds() - ctx->start_ns;

    WslStorageResult wsl_result = (result == strix::spdk::IOResult::Success)
        ? WSL_STORAGE_OK
        : WSL_STORAGE_ERROR_IO;

    // Update stats
    if (ctx->is_write) {
        g_state.stats.writes_completed++;
        g_state.stats.total_write_latency_ns += latency_ns;
        UpdateLatencyHistogram(g_state.stats.write_latency_histogram, latency_ns);
    } else {
        g_state.stats.reads_completed++;
        g_state.stats.total_read_latency_ns += latency_ns;
        UpdateLatencyHistogram(g_state.stats.read_latency_histogram, latency_ns);
    }

    g_state.operations_in_flight--;

    if (ctx->callback) {
        ctx->callback(wsl_result, 0, ctx->user_data);
    }

    delete ctx;
}

static WslStorageResult spdk_read_async(
    WslStorageHandlePtr handle,
    void* buffer,
    size_t size,
    uint64_t offset,
    WslStorageCallback callback,
    void* user_data
) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);

    std::shared_ptr<strix::spdk::NVMeFile> file;
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        auto it = g_state.handles.find(handle_id);
        if (it == g_state.handles.end()) {
            return WSL_STORAGE_ERROR_NOT_FOUND;
        }
        file = it->second;
    }

    auto* ctx = new AsyncContext{callback, user_data, GetNanoseconds(), false};
    g_state.operations_in_flight++;

    if (!file->read_async(buffer, size, offset,
                          [](strix::spdk::IOResult r, void* ud) {
                              spdk_async_completion(r, ud);
                          }, ctx)) {
        delete ctx;
        g_state.operations_in_flight--;
        return WSL_STORAGE_ERROR_BUSY;
    }

    return WSL_STORAGE_OK;
}

static WslStorageResult spdk_write_async(
    WslStorageHandlePtr handle,
    const void* buffer,
    size_t size,
    uint64_t offset,
    WslStorageCallback callback,
    void* user_data
) {
    uint64_t handle_id = reinterpret_cast<uint64_t>(handle);

    std::shared_ptr<strix::spdk::NVMeFile> file;
    {
        std::lock_guard<std::mutex> lock(g_state.handles_mutex);
        auto it = g_state.handles.find(handle_id);
        if (it == g_state.handles.end()) {
            return WSL_STORAGE_ERROR_NOT_FOUND;
        }
        file = it->second;
    }

    auto* ctx = new AsyncContext{callback, user_data, GetNanoseconds(), true};
    g_state.operations_in_flight++;

    if (!file->write_async(buffer, size, offset,
                           [](strix::spdk::IOResult r, void* ud) {
                               spdk_async_completion(r, ud);
                           }, ctx)) {
        delete ctx;
        g_state.operations_in_flight--;
        return WSL_STORAGE_ERROR_BUSY;
    }

    return WSL_STORAGE_OK;
}

static int spdk_poll_completions(int max_completions) {
    if (!g_state.initialized || !g_state.controller) {
        return 0;
    }
    return static_cast<int>(g_state.controller->poll_all_queues(
        max_completions > 0 ? max_completions : 32));
}

// ============================================================================
// Statistics
// ============================================================================

static void spdk_get_stats(WslStorageStats* out_stats) {
    if (out_stats) {
        // Copy atomic values
        *out_stats = g_state.stats;

        // Add controller stats if available
        if (g_state.controller) {
            const auto& ctrl_stats = g_state.controller->stats();
            // Controller stats are already included in our tracking
        }
    }
}

static void spdk_reset_stats(void) {
    g_state.stats = {};
    if (g_state.controller) {
        g_state.controller->reset_stats();
    }
}

// ============================================================================
// Stub Implementations
// ============================================================================

// These would be fully implemented in a production plugin
static WslStorageResult spdk_fdatasync(WslStorageHandlePtr h) { return spdk_fsync(h); }
static WslStorageResult spdk_stat(const char* p, WslFileStat* s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_fstat(WslStorageHandlePtr h, WslFileStat* s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_lstat(const char* p, WslFileStat* s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_truncate(const char* p, int64_t s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_ftruncate(WslStorageHandlePtr h, int64_t s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_mkdir(const char* p, uint32_t m) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_rmdir(const char* p) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_opendir(const char* p, WslStorageHandlePtr* h) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_readdir(WslStorageHandlePtr h, WslDirEntry* e, size_t m, size_t* c) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_closedir(WslStorageHandlePtr h) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_unlink(const char* p) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_rename(const char* o, const char* n) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_link(const char* o, const char* n) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_symlink(const char* t, const char* l) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_readlink(const char* p, char* b, size_t s, size_t* l) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_chmod(const char* p, uint32_t m) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_chown(const char* p, uint32_t u, uint32_t g) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_utimens(const char* p, int64_t a, int64_t m) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_submit_batch(WslStorageOp* o, size_t c) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_wait_batch(WslStorageOp* o, size_t c, int t) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_mmap(WslStorageHandlePtr h, uint64_t o, size_t s, uint32_t p, uint32_t f, void** a) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_munmap(void* a, size_t s) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static WslStorageResult spdk_msync(void* a, size_t s, int f) { return WSL_STORAGE_ERROR_NOT_SUPPORTED; }
static void spdk_prefetch(const char** p, size_t c) {}
static void spdk_fadvise(WslStorageHandlePtr h, uint64_t o, size_t l, int a) {}

// ============================================================================
// Plugin Export
// ============================================================================

static const WslStoragePluginV1 g_plugin = {
    .descriptor = g_descriptor,

    .initialize = spdk_initialize,
    .shutdown = spdk_shutdown,

    .supports_path = spdk_supports_path,
    .get_features = spdk_get_features,

    .open = spdk_open,
    .close = spdk_close,
    .read = spdk_read,
    .write = spdk_write,
    .fsync = spdk_fsync,
    .fdatasync = spdk_fdatasync,
    .stat = spdk_stat,
    .fstat = spdk_fstat,
    .lstat = spdk_lstat,
    .truncate = spdk_truncate,
    .ftruncate = spdk_ftruncate,

    .mkdir = spdk_mkdir,
    .rmdir = spdk_rmdir,
    .opendir = spdk_opendir,
    .readdir = spdk_readdir,
    .closedir = spdk_closedir,

    .unlink = spdk_unlink,
    .rename = spdk_rename,
    .link = spdk_link,
    .symlink = spdk_symlink,
    .readlink = spdk_readlink,

    .chmod = spdk_chmod,
    .chown = spdk_chown,
    .utimens = spdk_utimens,

    .read_async = spdk_read_async,
    .write_async = spdk_write_async,
    .poll_completions = spdk_poll_completions,

    .submit_batch = spdk_submit_batch,
    .wait_batch = spdk_wait_batch,

    .mmap = spdk_mmap,
    .munmap = spdk_munmap,
    .msync = spdk_msync,

    .prefetch = spdk_prefetch,
    .fadvise = spdk_fadvise,

    .get_stats = spdk_get_stats,
    .reset_stats = spdk_reset_stats,
};

} // namespace plugins
} // namespace strix

// DLL Export
extern "C" __declspec(dllexport)
const WslStoragePluginV1* WslGetStoragePluginV1(void) {
    return &strix::plugins::g_plugin;
}
