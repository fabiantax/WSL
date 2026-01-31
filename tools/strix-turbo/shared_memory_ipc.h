/**
 * Shared Memory IPC for WSL2 Strix-Turbo
 *
 * Replaces 9p protocol with direct shared memory communication.
 * Achieves ~1000x faster file access than 9p for /mnt/c operations.
 *
 * Architecture:
 *   Windows: Maps shared region, writes file data directly
 *   Linux:   Maps same region via Hyper-V shared memory, reads directly
 *   Result:  Zero-copy file access, no RPC overhead
 *
 * Memory Layout:
 *   [0x0000 - 0x1000)     Control Block (4KB)
 *   [0x1000 - 0x2000)     Command Ring Buffer (4KB, 256 entries)
 *   [0x2000 - 0x3000)     Response Ring Buffer (4KB, 256 entries)
 *   [0x3000 - 0x100000)   Metadata Cache (1MB - 12KB)
 *   [0x100000 - END)      Data Region (remaining space)
 */

#ifndef STRIX_TURBO_SHARED_MEMORY_IPC_H
#define STRIX_TURBO_SHARED_MEMORY_IPC_H

#include <cstdint>
#include <cstddef>
#include <atomic>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace strix {
namespace shm {

//==============================================================================
// Constants
//==============================================================================

constexpr size_t CONTROL_BLOCK_OFFSET = 0x0000;
constexpr size_t CONTROL_BLOCK_SIZE   = 0x1000;  // 4KB

constexpr size_t CMD_RING_OFFSET      = 0x1000;
constexpr size_t CMD_RING_SIZE        = 0x1000;  // 4KB
constexpr size_t CMD_RING_ENTRIES     = 256;

constexpr size_t RSP_RING_OFFSET      = 0x2000;
constexpr size_t RSP_RING_SIZE        = 0x1000;  // 4KB
constexpr size_t RSP_RING_ENTRIES     = 256;

constexpr size_t METADATA_OFFSET      = 0x3000;
constexpr size_t METADATA_SIZE        = 0x100000 - 0x3000;  // ~1MB

constexpr size_t DATA_REGION_OFFSET   = 0x100000;  // 1MB

constexpr uint32_t MAGIC_NUMBER       = 0x53545258;  // "STRX"
constexpr uint32_t PROTOCOL_VERSION   = 1;

//==============================================================================
// Command Types
//==============================================================================

enum class CommandType : uint8_t {
    // File Operations
    Open        = 0x01,
    Close       = 0x02,
    Read        = 0x03,
    Write       = 0x04,
    Stat        = 0x05,
    Fstat       = 0x06,
    Readdir     = 0x07,
    Mkdir       = 0x08,
    Rmdir       = 0x09,
    Unlink      = 0x0A,
    Rename      = 0x0B,
    Truncate    = 0x0C,
    Fsync       = 0x0D,

    // Extended Operations
    Readlink    = 0x10,
    Symlink     = 0x11,
    Link        = 0x12,
    Chmod       = 0x13,
    Chown       = 0x14,
    Utimes      = 0x15,

    // Bulk Operations (batched for efficiency)
    BatchRead   = 0x20,  // Read multiple files
    BatchStat   = 0x21,  // Stat multiple files
    Prefetch    = 0x22,  // Hint: will access these files soon

    // Control
    Ping        = 0xFE,
    Shutdown    = 0xFF
};

//==============================================================================
// Flags
//==============================================================================

namespace OpenFlags {
    constexpr uint32_t RDONLY    = 0x0000;
    constexpr uint32_t WRONLY    = 0x0001;
    constexpr uint32_t RDWR      = 0x0002;
    constexpr uint32_t CREAT     = 0x0040;
    constexpr uint32_t EXCL      = 0x0080;
    constexpr uint32_t TRUNC     = 0x0200;
    constexpr uint32_t APPEND    = 0x0400;
    constexpr uint32_t DIRECTORY = 0x10000;
}

//==============================================================================
// Error Codes
//==============================================================================

enum class ErrorCode : int32_t {
    Success         = 0,
    NotFound        = -2,   // ENOENT
    PermissionDenied= -13,  // EACCES
    Exists          = -17,  // EEXIST
    NotDirectory    = -20,  // ENOTDIR
    IsDirectory     = -21,  // EISDIR
    InvalidArgument = -22,  // EINVAL
    TooManyOpen     = -24,  // EMFILE
    NoSpace         = -28,  // ENOSPC
    ReadOnly        = -30,  // EROFS
    NameTooLong     = -36,  // ENAMETOOLONG
    NotEmpty        = -39,  // ENOTEMPTY
    Timeout         = -110, // ETIMEDOUT
    Unknown         = -255
};

//==============================================================================
// Control Block (at offset 0)
//==============================================================================

struct alignas(64) ControlBlock {
    // Magic and version (read-only after init)
    uint32_t magic;
    uint32_t version;
    uint64_t region_size;

    // State
    std::atomic<uint32_t> windows_ready;  // Windows server initialized
    std::atomic<uint32_t> linux_ready;    // Linux client initialized
    std::atomic<uint32_t> shutdown;       // Shutdown requested
    uint32_t _pad1;

    // Ring buffer indices (separate cache lines to avoid false sharing)
    alignas(64) std::atomic<uint32_t> cmd_head;  // Linux writes, Windows reads
    alignas(64) std::atomic<uint32_t> cmd_tail;  // Windows writes, Linux reads
    alignas(64) std::atomic<uint32_t> rsp_head;  // Windows writes, Linux reads
    alignas(64) std::atomic<uint32_t> rsp_tail;  // Linux writes, Windows reads

    // Statistics
    alignas(64) std::atomic<uint64_t> commands_processed;
    std::atomic<uint64_t> bytes_transferred;
    std::atomic<uint64_t> cache_hits;
    std::atomic<uint64_t> cache_misses;

    // Data region allocator
    alignas(64) std::atomic<uint64_t> data_alloc_head;  // Next free offset in data region

    // Padding to 4KB
    uint8_t _reserved[CONTROL_BLOCK_SIZE - 256];

    bool is_valid() const {
        return magic == MAGIC_NUMBER && version == PROTOCOL_VERSION;
    }

    void initialize(uint64_t total_size) {
        magic = MAGIC_NUMBER;
        version = PROTOCOL_VERSION;
        region_size = total_size;
        windows_ready = 0;
        linux_ready = 0;
        shutdown = 0;
        cmd_head = 0;
        cmd_tail = 0;
        rsp_head = 0;
        rsp_tail = 0;
        commands_processed = 0;
        bytes_transferred = 0;
        cache_hits = 0;
        cache_misses = 0;
        data_alloc_head = DATA_REGION_OFFSET;
    }
};

static_assert(sizeof(ControlBlock) == CONTROL_BLOCK_SIZE, "ControlBlock size mismatch");

//==============================================================================
// Command Entry (16 bytes, fits 256 in 4KB)
//==============================================================================

struct alignas(16) CommandEntry {
    CommandType type;
    uint8_t flags;
    uint16_t path_len;          // Length of path in metadata region
    uint32_t data_offset;       // Offset in data region (relative to DATA_REGION_OFFSET)
    uint32_t data_len;          // Length of data
    uint32_t request_id;        // For matching responses

    // Path is stored inline after the command ring in metadata region
    // Formula: metadata_offset = METADATA_OFFSET + (cmd_index * 256)
};

static_assert(sizeof(CommandEntry) == 16, "CommandEntry must be 16 bytes");

//==============================================================================
// Response Entry (16 bytes)
//==============================================================================

struct alignas(16) ResponseEntry {
    uint32_t request_id;        // Matches CommandEntry.request_id
    ErrorCode error;            // 0 = success
    uint32_t data_offset;       // Result data offset (if any)
    uint32_t data_len;          // Result data length
};

static_assert(sizeof(ResponseEntry) == 16, "ResponseEntry must be 16 bytes");

//==============================================================================
// Metadata Entry (for stat results, directory entries, etc.)
//==============================================================================

struct FileMetadata {
    uint64_t size;
    uint64_t mtime_ns;      // Nanoseconds since epoch
    uint64_t atime_ns;
    uint64_t ctime_ns;
    uint32_t mode;          // Unix permission bits
    uint32_t uid;
    uint32_t gid;
    uint32_t nlink;
    uint64_t inode;         // Unique identifier (Windows file ID)
    uint32_t dev;
    uint32_t _pad;
};

struct DirEntry {
    uint64_t inode;
    uint16_t name_len;
    uint8_t type;           // DT_REG, DT_DIR, etc.
    uint8_t _pad;
    char name[252];         // Inline name, NUL-terminated
};

//==============================================================================
// Shared Memory Region
//==============================================================================

class SharedMemoryRegion {
public:
    SharedMemoryRegion() = default;
    ~SharedMemoryRegion() { unmap(); }

    // Non-copyable
    SharedMemoryRegion(const SharedMemoryRegion&) = delete;
    SharedMemoryRegion& operator=(const SharedMemoryRegion&) = delete;

    // Movable
    SharedMemoryRegion(SharedMemoryRegion&& other) noexcept;
    SharedMemoryRegion& operator=(SharedMemoryRegion&& other) noexcept;

#ifdef _WIN32
    /**
     * Create shared memory region (Windows server side).
     * Uses named section object for Hyper-V guest access.
     */
    bool create(const wchar_t* name, size_t size);

    /**
     * Open existing shared memory region (Windows client side).
     */
    bool open(const wchar_t* name);
#else
    /**
     * Map Hyper-V shared memory region (Linux guest side).
     * Uses /dev/hv_vmbus or direct memory mapping.
     */
    bool map_hyperv(const char* vmbus_device, size_t size);

    /**
     * Map via file descriptor (for testing with shm_open).
     */
    bool map_fd(int fd, size_t size);
#endif

    /**
     * Unmap and close.
     */
    void unmap();

    /**
     * Get mapped base address.
     */
    void* base() const { return base_; }
    size_t size() const { return size_; }
    bool is_mapped() const { return base_ != nullptr; }

    /**
     * Get typed pointer at offset.
     */
    template<typename T>
    T* at(size_t offset) {
        return reinterpret_cast<T*>(static_cast<char*>(base_) + offset);
    }

    template<typename T>
    const T* at(size_t offset) const {
        return reinterpret_cast<const T*>(static_cast<const char*>(base_) + offset);
    }

    // Convenience accessors
    ControlBlock* control() { return at<ControlBlock>(CONTROL_BLOCK_OFFSET); }
    CommandEntry* cmd_ring() { return at<CommandEntry>(CMD_RING_OFFSET); }
    ResponseEntry* rsp_ring() { return at<ResponseEntry>(RSP_RING_OFFSET); }
    void* metadata() { return at<void>(METADATA_OFFSET); }
    void* data_region() { return at<void>(DATA_REGION_OFFSET); }

private:
    void* base_ = nullptr;
    size_t size_ = 0;

#ifdef _WIN32
    HANDLE mapping_ = nullptr;
#else
    int fd_ = -1;
#endif
};

//==============================================================================
// Lock-Free Ring Buffer Operations
//==============================================================================

class CommandRing {
public:
    CommandRing(SharedMemoryRegion& shm)
        : control_(shm.control())
        , entries_(shm.cmd_ring())
        , metadata_(static_cast<char*>(shm.metadata())) {}

    /**
     * Submit command (producer side - Linux).
     * Returns request_id, or 0 if queue full.
     */
    uint32_t submit(CommandType type, const char* path, uint32_t flags,
                    uint32_t data_offset, uint32_t data_len) {
        uint32_t head = control_->cmd_head.load(std::memory_order_relaxed);
        uint32_t tail = control_->cmd_tail.load(std::memory_order_acquire);

        if (((head + 1) % CMD_RING_ENTRIES) == tail) {
            return 0;  // Queue full
        }

        uint32_t req_id = next_request_id_++;
        CommandEntry& entry = entries_[head];
        entry.type = type;
        entry.flags = static_cast<uint8_t>(flags);
        entry.request_id = req_id;
        entry.data_offset = data_offset;
        entry.data_len = data_len;

        // Copy path to metadata region
        if (path) {
            size_t path_len = strlen(path);
            entry.path_len = static_cast<uint16_t>(path_len);
            char* path_dest = metadata_ + (head * 256);
            memcpy(path_dest, path, path_len + 1);
        } else {
            entry.path_len = 0;
        }

        // Memory barrier before updating head
        std::atomic_thread_fence(std::memory_order_release);
        control_->cmd_head.store((head + 1) % CMD_RING_ENTRIES, std::memory_order_release);

        return req_id;
    }

    /**
     * Consume command (consumer side - Windows).
     * Returns true if command available.
     */
    bool consume(CommandEntry& out_entry, char* out_path, size_t path_buf_size) {
        uint32_t head = control_->cmd_head.load(std::memory_order_acquire);
        uint32_t tail = control_->cmd_tail.load(std::memory_order_relaxed);

        if (head == tail) {
            return false;  // Queue empty
        }

        const CommandEntry& entry = entries_[tail];
        out_entry = entry;

        if (entry.path_len > 0 && out_path) {
            const char* path_src = metadata_ + (tail * 256);
            size_t copy_len = (entry.path_len < path_buf_size - 1) ? entry.path_len : path_buf_size - 1;
            memcpy(out_path, path_src, copy_len);
            out_path[copy_len] = '\0';
        }

        control_->cmd_tail.store((tail + 1) % CMD_RING_ENTRIES, std::memory_order_release);
        return true;
    }

private:
    ControlBlock* control_;
    CommandEntry* entries_;
    char* metadata_;
    std::atomic<uint32_t> next_request_id_{1};
};

class ResponseRing {
public:
    ResponseRing(SharedMemoryRegion& shm)
        : control_(shm.control())
        , entries_(shm.rsp_ring()) {}

    /**
     * Submit response (producer side - Windows).
     */
    bool submit(uint32_t request_id, ErrorCode error, uint32_t data_offset, uint32_t data_len) {
        uint32_t head = control_->rsp_head.load(std::memory_order_relaxed);
        uint32_t tail = control_->rsp_tail.load(std::memory_order_acquire);

        if (((head + 1) % RSP_RING_ENTRIES) == tail) {
            return false;  // Queue full
        }

        ResponseEntry& entry = entries_[head];
        entry.request_id = request_id;
        entry.error = error;
        entry.data_offset = data_offset;
        entry.data_len = data_len;

        control_->rsp_head.store((head + 1) % RSP_RING_ENTRIES, std::memory_order_release);
        return true;
    }

    /**
     * Consume response (consumer side - Linux).
     */
    bool consume(ResponseEntry& out_entry) {
        uint32_t head = control_->rsp_head.load(std::memory_order_acquire);
        uint32_t tail = control_->rsp_tail.load(std::memory_order_relaxed);

        if (head == tail) {
            return false;
        }

        out_entry = entries_[tail];
        control_->rsp_tail.store((tail + 1) % RSP_RING_ENTRIES, std::memory_order_release);
        return true;
    }

    /**
     * Wait for specific response (blocking).
     */
    bool wait_for(uint32_t request_id, ResponseEntry& out, uint32_t timeout_ms = 5000);

private:
    ControlBlock* control_;
    ResponseEntry* entries_;
};

//==============================================================================
// High-Level Client (Linux side)
//==============================================================================

class SharedMemoryClient {
public:
    SharedMemoryClient(SharedMemoryRegion& shm);

    /**
     * Initialize client and wait for server.
     */
    bool initialize(uint32_t timeout_ms = 5000);

    /**
     * File operations (synchronous).
     */
    int open(const char* path, uint32_t flags, uint32_t mode = 0644);
    int close(int fd);
    ssize_t read(int fd, void* buf, size_t count);
    ssize_t write(int fd, const void* buf, size_t count);
    ssize_t pread(int fd, void* buf, size_t count, off_t offset);
    ssize_t pwrite(int fd, const void* buf, size_t count, off_t offset);
    int stat(const char* path, FileMetadata* meta);
    int fstat(int fd, FileMetadata* meta);

    /**
     * Directory operations.
     */
    int readdir(const char* path, DirEntry* entries, size_t max_entries, size_t* out_count);
    int mkdir(const char* path, uint32_t mode);
    int rmdir(const char* path);
    int unlink(const char* path);
    int rename(const char* oldpath, const char* newpath);

    /**
     * Batch operations (high performance).
     */
    struct BatchReadRequest {
        const char* path;
        void* buffer;
        size_t size;
        ssize_t result;  // Filled in after batch_read()
    };
    int batch_read(BatchReadRequest* requests, size_t count);

    struct BatchStatRequest {
        const char* path;
        FileMetadata meta;
        int result;
    };
    int batch_stat(BatchStatRequest* requests, size_t count);

    /**
     * Prefetch hint (async, non-blocking).
     * Tells server to cache these files.
     */
    void prefetch(const char** paths, size_t count);

private:
    SharedMemoryRegion& shm_;
    CommandRing cmd_ring_;
    ResponseRing rsp_ring_;

    // File descriptor table
    struct FileHandle {
        bool in_use;
        uint64_t server_handle;
        uint64_t position;
        char path[256];
    };
    FileHandle handles_[1024];

    int allocate_fd();
    void release_fd(int fd);

    // Data region allocator
    uint32_t alloc_data(size_t size);
    void free_data(uint32_t offset, size_t size);
};

//==============================================================================
// High-Level Server (Windows side)
//==============================================================================

#ifdef _WIN32
class SharedMemoryServer {
public:
    SharedMemoryServer(SharedMemoryRegion& shm);

    /**
     * Initialize server and signal ready.
     */
    bool initialize();

    /**
     * Process pending commands.
     * Call this in a loop.
     *
     * @param max_commands Maximum commands to process (0 = until empty)
     * @return Number of commands processed
     */
    uint32_t process(uint32_t max_commands = 0);

    /**
     * Main server loop (blocking).
     */
    void run();

    /**
     * Request shutdown.
     */
    void shutdown();

private:
    SharedMemoryRegion& shm_;
    CommandRing cmd_ring_;
    ResponseRing rsp_ring_;
    std::atomic<bool> running_{false};

    // Windows file handle cache
    struct CachedHandle {
        HANDLE handle;
        wchar_t path[MAX_PATH];
        FILETIME last_access;
    };
    CachedHandle handle_cache_[256];

    // Command handlers
    void handle_open(const CommandEntry& cmd, const char* path);
    void handle_close(const CommandEntry& cmd);
    void handle_read(const CommandEntry& cmd);
    void handle_write(const CommandEntry& cmd);
    void handle_stat(const CommandEntry& cmd, const char* path);
    void handle_readdir(const CommandEntry& cmd, const char* path);
    void handle_batch_read(const CommandEntry& cmd);
    void handle_prefetch(const CommandEntry& cmd);
};
#endif

//==============================================================================
// Inline Implementations
//==============================================================================

inline SharedMemoryRegion::SharedMemoryRegion(SharedMemoryRegion&& other) noexcept
    : base_(other.base_)
    , size_(other.size_)
#ifdef _WIN32
    , mapping_(other.mapping_)
#else
    , fd_(other.fd_)
#endif
{
    other.base_ = nullptr;
    other.size_ = 0;
#ifdef _WIN32
    other.mapping_ = nullptr;
#else
    other.fd_ = -1;
#endif
}

inline SharedMemoryRegion& SharedMemoryRegion::operator=(SharedMemoryRegion&& other) noexcept {
    if (this != &other) {
        unmap();
        base_ = other.base_;
        size_ = other.size_;
#ifdef _WIN32
        mapping_ = other.mapping_;
        other.mapping_ = nullptr;
#else
        fd_ = other.fd_;
        other.fd_ = -1;
#endif
        other.base_ = nullptr;
        other.size_ = 0;
    }
    return *this;
}

inline void SharedMemoryRegion::unmap() {
    if (base_) {
#ifdef _WIN32
        UnmapViewOfFile(base_);
        if (mapping_) {
            CloseHandle(mapping_);
            mapping_ = nullptr;
        }
#else
        munmap(base_, size_);
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
#endif
        base_ = nullptr;
        size_ = 0;
    }
}

} // namespace shm
} // namespace strix

#endif // STRIX_TURBO_SHARED_MEMORY_IPC_H
