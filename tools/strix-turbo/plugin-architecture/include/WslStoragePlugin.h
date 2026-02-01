/*++

Copyright (c) Microsoft. All rights reserved.

Module Name:

    WslStoragePlugin.h

Abstract:

    Storage plugin interface for WSL2.
    Plugins implementing this interface can provide alternative
    storage backends (SPDK, VirtIO-FS, shared memory, etc.)

--*/

#pragma once

#include "WslPluginCapabilities.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Error Codes
// ============================================================================

typedef enum WslStorageResult {
    WSL_STORAGE_OK = 0,
    WSL_STORAGE_ERROR = -1,
    WSL_STORAGE_ERROR_NOT_FOUND = -2,
    WSL_STORAGE_ERROR_PERMISSION = -3,
    WSL_STORAGE_ERROR_EXISTS = -4,
    WSL_STORAGE_ERROR_NOT_DIR = -5,
    WSL_STORAGE_ERROR_IS_DIR = -6,
    WSL_STORAGE_ERROR_NO_SPACE = -7,
    WSL_STORAGE_ERROR_BUSY = -8,
    WSL_STORAGE_ERROR_TIMEOUT = -9,
    WSL_STORAGE_ERROR_NOT_SUPPORTED = -10,
    WSL_STORAGE_ERROR_INVALID_ARG = -11,
    WSL_STORAGE_ERROR_IO = -12,
    WSL_STORAGE_ERROR_READONLY = -13,
    WSL_STORAGE_ERROR_NAME_TOO_LONG = -14,
    WSL_STORAGE_ERROR_NOT_EMPTY = -15,
} WslStorageResult;

// ============================================================================
// Feature Flags
// ============================================================================

typedef uint32_t WslStorageFeatures;

#define WSL_STORAGE_FEAT_NONE           ((WslStorageFeatures)0)
#define WSL_STORAGE_FEAT_ASYNC          ((WslStorageFeatures)(1 << 0))  // Async I/O
#define WSL_STORAGE_FEAT_BATCH          ((WslStorageFeatures)(1 << 1))  // Batched ops
#define WSL_STORAGE_FEAT_DAX            ((WslStorageFeatures)(1 << 2))  // Direct Access
#define WSL_STORAGE_FEAT_ZERO_COPY      ((WslStorageFeatures)(1 << 3))  // Zero-copy
#define WSL_STORAGE_FEAT_PREFETCH       ((WslStorageFeatures)(1 << 4))  // Prefetching
#define WSL_STORAGE_FEAT_SPARSE         ((WslStorageFeatures)(1 << 5))  // Sparse files
#define WSL_STORAGE_FEAT_HOLES          ((WslStorageFeatures)(1 << 6))  // Hole punching
#define WSL_STORAGE_FEAT_XATTR          ((WslStorageFeatures)(1 << 7))  // Ext. attributes
#define WSL_STORAGE_FEAT_ATOMIC_WRITE   ((WslStorageFeatures)(1 << 8))  // Atomic writes
#define WSL_STORAGE_FEAT_MMAP           ((WslStorageFeatures)(1 << 9))  // Memory mapping
#define WSL_STORAGE_FEAT_SENDFILE       ((WslStorageFeatures)(1 << 10)) // sendfile(2)
#define WSL_STORAGE_FEAT_COPY_RANGE     ((WslStorageFeatures)(1 << 11)) // copy_file_range(2)

// ============================================================================
// File Types and Modes
// ============================================================================

#define WSL_S_IFMT   0170000
#define WSL_S_IFSOCK 0140000
#define WSL_S_IFLNK  0120000
#define WSL_S_IFREG  0100000
#define WSL_S_IFBLK  0060000
#define WSL_S_IFDIR  0040000
#define WSL_S_IFCHR  0020000
#define WSL_S_IFIFO  0010000

#define WSL_S_ISREG(m)  (((m) & WSL_S_IFMT) == WSL_S_IFREG)
#define WSL_S_ISDIR(m)  (((m) & WSL_S_IFMT) == WSL_S_IFDIR)
#define WSL_S_ISLNK(m)  (((m) & WSL_S_IFMT) == WSL_S_IFLNK)

// Open flags
#define WSL_O_RDONLY    0x0000
#define WSL_O_WRONLY    0x0001
#define WSL_O_RDWR      0x0002
#define WSL_O_CREAT     0x0040
#define WSL_O_EXCL      0x0080
#define WSL_O_TRUNC     0x0200
#define WSL_O_APPEND    0x0400
#define WSL_O_NONBLOCK  0x0800
#define WSL_O_DIRECTORY 0x10000
#define WSL_O_NOFOLLOW  0x20000
#define WSL_O_CLOEXEC   0x80000
#define WSL_O_DIRECT    0x4000

// ============================================================================
// Data Structures
// ============================================================================

// Opaque file handle
typedef struct WslStorageHandle* WslStorageHandlePtr;

// File statistics
typedef struct WslFileStat {
    uint64_t dev;
    uint64_t ino;
    uint32_t mode;
    uint32_t nlink;
    uint32_t uid;
    uint32_t gid;
    uint64_t rdev;
    int64_t  size;
    int64_t  blksize;
    int64_t  blocks;
    int64_t  atime_sec;
    int64_t  atime_nsec;
    int64_t  mtime_sec;
    int64_t  mtime_nsec;
    int64_t  ctime_sec;
    int64_t  ctime_nsec;
} WslFileStat;

// Directory entry
typedef struct WslDirEntry {
    uint64_t ino;
    uint64_t off;       // Offset for seekdir
    uint16_t reclen;
    uint8_t  type;      // DT_REG, DT_DIR, etc.
    char     name[256]; // NUL-terminated
} WslDirEntry;

// Async completion callback
typedef void (*WslStorageCallback)(
    WslStorageResult result,
    size_t bytes_transferred,
    void* user_data
);

// Batch operation descriptor
typedef struct WslStorageOp {
    enum {
        WSL_OP_READ,
        WSL_OP_WRITE,
        WSL_OP_FSYNC,
        WSL_OP_STAT,
    } type;

    union {
        struct {
            WslStorageHandlePtr handle;
            void* buffer;
            size_t size;
            uint64_t offset;
        } rw;

        struct {
            WslStorageHandlePtr handle;
        } fsync;

        struct {
            const char* path;
            WslFileStat* out_stat;
        } stat;
    };

    WslStorageResult result;
    size_t bytes_transferred;

} WslStorageOp;

// Statistics for telemetry and A/B testing
typedef struct WslStorageStats {
    // Counts
    uint64_t reads_completed;
    uint64_t writes_completed;
    uint64_t bytes_read;
    uint64_t bytes_written;
    uint64_t errors;

    // Cache performance
    uint64_t cache_hits;
    uint64_t cache_misses;
    uint64_t cache_evictions;
    uint64_t cache_bytes_used;

    // Latency (nanoseconds)
    uint64_t total_read_latency_ns;
    uint64_t total_write_latency_ns;
    uint64_t min_read_latency_ns;
    uint64_t max_read_latency_ns;
    uint64_t min_write_latency_ns;
    uint64_t max_write_latency_ns;

    // Histogram buckets (< 1us, 1-10us, 10-100us, 100us-1ms, 1-10ms, >10ms)
    uint64_t read_latency_histogram[6];
    uint64_t write_latency_histogram[6];

} WslStorageStats;

// ============================================================================
// Storage Plugin Interface v1
// ============================================================================

#define WSL_STORAGE_PLUGIN_VERSION 1

typedef struct WslStoragePluginV1 {
    // ========================================================================
    // Identity
    // ========================================================================
    WslPluginDescriptor descriptor;

    // ========================================================================
    // Lifecycle
    // ========================================================================

    // Initialize the plugin. Called once when loaded.
    // Returns WSL_STORAGE_OK on success.
    WslStorageResult (*initialize)(const WslPluginContext* ctx);

    // Shutdown the plugin. Called before unloading.
    void (*shutdown)(void);

    // ========================================================================
    // Capability Query
    // ========================================================================

    // Check if this plugin can handle the given path.
    // For example, SPDK plugin might only handle /mnt/spdk/*
    bool (*supports_path)(const char* path);

    // Get supported features
    WslStorageFeatures (*get_features)(void);

    // ========================================================================
    // Synchronous File Operations
    // ========================================================================

    WslStorageResult (*open)(
        const char* path,
        uint32_t flags,
        uint32_t mode,
        WslStorageHandlePtr* out_handle
    );

    WslStorageResult (*close)(WslStorageHandlePtr handle);

    WslStorageResult (*read)(
        WslStorageHandlePtr handle,
        void* buffer,
        size_t size,
        uint64_t offset,
        size_t* out_bytes_read
    );

    WslStorageResult (*write)(
        WslStorageHandlePtr handle,
        const void* buffer,
        size_t size,
        uint64_t offset,
        size_t* out_bytes_written
    );

    WslStorageResult (*fsync)(WslStorageHandlePtr handle);
    WslStorageResult (*fdatasync)(WslStorageHandlePtr handle);

    WslStorageResult (*stat)(const char* path, WslFileStat* out_stat);
    WslStorageResult (*fstat)(WslStorageHandlePtr handle, WslFileStat* out_stat);
    WslStorageResult (*lstat)(const char* path, WslFileStat* out_stat);

    WslStorageResult (*truncate)(const char* path, int64_t size);
    WslStorageResult (*ftruncate)(WslStorageHandlePtr handle, int64_t size);

    // ========================================================================
    // Directory Operations
    // ========================================================================

    WslStorageResult (*mkdir)(const char* path, uint32_t mode);
    WslStorageResult (*rmdir)(const char* path);

    WslStorageResult (*opendir)(const char* path, WslStorageHandlePtr* out_handle);
    WslStorageResult (*readdir)(
        WslStorageHandlePtr handle,
        WslDirEntry* entries,
        size_t max_entries,
        size_t* out_count
    );
    WslStorageResult (*closedir)(WslStorageHandlePtr handle);

    // ========================================================================
    // Link Operations
    // ========================================================================

    WslStorageResult (*unlink)(const char* path);
    WslStorageResult (*rename)(const char* oldpath, const char* newpath);
    WslStorageResult (*link)(const char* oldpath, const char* newpath);
    WslStorageResult (*symlink)(const char* target, const char* linkpath);
    WslStorageResult (*readlink)(const char* path, char* buffer, size_t size, size_t* out_len);

    // ========================================================================
    // Attribute Operations
    // ========================================================================

    WslStorageResult (*chmod)(const char* path, uint32_t mode);
    WslStorageResult (*chown)(const char* path, uint32_t uid, uint32_t gid);
    WslStorageResult (*utimens)(const char* path, int64_t atime_ns, int64_t mtime_ns);

    // ========================================================================
    // Asynchronous Operations (optional - check get_features)
    // ========================================================================

    WslStorageResult (*read_async)(
        WslStorageHandlePtr handle,
        void* buffer,
        size_t size,
        uint64_t offset,
        WslStorageCallback callback,
        void* user_data
    );

    WslStorageResult (*write_async)(
        WslStorageHandlePtr handle,
        const void* buffer,
        size_t size,
        uint64_t offset,
        WslStorageCallback callback,
        void* user_data
    );

    // Poll for completions. Returns number of completions.
    int (*poll_completions)(int max_completions);

    // ========================================================================
    // Batch Operations (optional - check get_features)
    // ========================================================================

    WslStorageResult (*submit_batch)(
        WslStorageOp* ops,
        size_t count
    );

    WslStorageResult (*wait_batch)(
        WslStorageOp* ops,
        size_t count,
        int timeout_ms
    );

    // ========================================================================
    // Memory Mapping (optional - check get_features)
    // ========================================================================

    WslStorageResult (*mmap)(
        WslStorageHandlePtr handle,
        uint64_t offset,
        size_t size,
        uint32_t prot,      // PROT_READ, PROT_WRITE, PROT_EXEC
        uint32_t flags,     // MAP_SHARED, MAP_PRIVATE
        void** out_addr
    );

    WslStorageResult (*munmap)(void* addr, size_t size);
    WslStorageResult (*msync)(void* addr, size_t size, int flags);

    // ========================================================================
    // Prefetch Hints (optional - check get_features)
    // ========================================================================

    // Hint that these files will be accessed soon
    void (*prefetch)(const char** paths, size_t count);

    // Hint about sequential access pattern
    void (*fadvise)(WslStorageHandlePtr handle, uint64_t offset, size_t len, int advice);

    // ========================================================================
    // Statistics
    // ========================================================================

    void (*get_stats)(WslStorageStats* out_stats);
    void (*reset_stats)(void);

} WslStoragePluginV1;

// ============================================================================
// Plugin Export
// ============================================================================

// DLL export name
#define WSL_STORAGE_PLUGIN_EXPORT "WslGetStoragePluginV1"

// Export function type
typedef const WslStoragePluginV1* (*WslGetStoragePluginFunc)(void);

#ifdef __cplusplus
}
#endif
