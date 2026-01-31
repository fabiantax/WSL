/**
 * io_uring Syscall Batching Framework for WSL2 Strix-Turbo
 *
 * Batches thousands of syscalls into single VM exit.
 * Reduces VM exit overhead from ~1000 cycles/syscall to ~1 cycle/syscall.
 *
 * Key insight: In WSL2, every syscall crosses the hypervisor boundary.
 * io_uring allows submitting 1000s of operations with ONE boundary crossing.
 *
 * Prerequisites:
 *   - Kernel 5.6+ with CONFIG_IO_URING=y
 *   - liburing: apt install liburing-dev
 *
 * Build:
 *   g++ -O3 -luring your_app.cpp
 */

#ifndef STRIX_TURBO_URING_BATCH_H
#define STRIX_TURBO_URING_BATCH_H

#include <cstdint>
#include <cstddef>
#include <functional>
#include <vector>
#include <memory>
#include <atomic>
#include <chrono>

// Forward declaration (actual liburing types in implementation)
struct io_uring;
struct io_uring_sqe;
struct io_uring_cqe;

namespace strix {
namespace uring {

//==============================================================================
// Configuration
//==============================================================================

struct UringConfig {
    uint32_t queue_depth;           // SQ/CQ entries (default: 4096)
    uint32_t sq_thread_cpu;         // Pin SQPOLL thread to CPU (-1 = no pin)
    uint32_t sq_thread_idle_ms;     // SQPOLL idle timeout (default: 1000)
    bool use_sqpoll;                // Kernel-side submission polling
    bool use_iopoll;                // Busy-poll for completions
    bool use_registered_files;      // Pre-register file descriptors
    bool use_registered_buffers;    // Pre-register buffers

    static UringConfig high_throughput() {
        return {
            .queue_depth = 4096,
            .sq_thread_cpu = -1,
            .sq_thread_idle_ms = 2000,
            .use_sqpoll = true,     // Kernel polls SQ, no syscall needed
            .use_iopoll = false,    // Don't busy-poll CQ
            .use_registered_files = true,
            .use_registered_buffers = true
        };
    }

    static UringConfig low_latency() {
        return {
            .queue_depth = 256,
            .sq_thread_cpu = 15,    // Pin to last core
            .sq_thread_idle_ms = 0, // Never idle
            .use_sqpoll = true,
            .use_iopoll = true,     // Busy-poll for sub-microsecond latency
            .use_registered_files = true,
            .use_registered_buffers = true
        };
    }

    static UringConfig balanced() {
        return {
            .queue_depth = 1024,
            .sq_thread_cpu = -1,
            .sq_thread_idle_ms = 1000,
            .use_sqpoll = true,
            .use_iopoll = false,
            .use_registered_files = true,
            .use_registered_buffers = false
        };
    }
};

//==============================================================================
// Completion Callback
//==============================================================================

using Callback = std::function<void(int32_t result, void* user_data)>;

//==============================================================================
// Operation Types
//==============================================================================

enum class OpType : uint8_t {
    Read,
    Write,
    Readv,
    Writev,
    Fsync,
    Fdatasync,
    PollAdd,
    PollRemove,
    SyncFileRange,
    SendMsg,
    RecvMsg,
    Timeout,
    TimeoutRemove,
    Accept,
    Connect,
    Close,
    Statx,
    OpenAt,
    MkdirAt,
    UnlinkAt,
    RenameAt,
    Splice,
    Tee,
    Shutdown,
    Renameat2,
    LinkAt,
    SymlinkAt,
    Fadvise,
    Madvise,
    Send,
    Recv,
    OpenAt2,
    Epoll,
    Provide_Buffers,
    Remove_Buffers,
    Nop
};

//==============================================================================
// Batch Builder
//==============================================================================

/**
 * Builds a batch of io_uring operations.
 *
 * Usage:
 *   BatchBuilder batch(ring);
 *   batch.read(fd1, buf1, size1, offset1, callback1, data1);
 *   batch.read(fd2, buf2, size2, offset2, callback2, data2);
 *   batch.write(fd3, buf3, size3, offset3, callback3, data3);
 *   batch.submit();  // Single syscall for all operations
 */
class BatchBuilder {
public:
    explicit BatchBuilder(class UringContext& ctx);
    ~BatchBuilder();

    // Non-copyable
    BatchBuilder(const BatchBuilder&) = delete;
    BatchBuilder& operator=(const BatchBuilder&) = delete;

    //--------------------------------------------------------------------------
    // File I/O
    //--------------------------------------------------------------------------

    /**
     * Queue read operation.
     */
    BatchBuilder& read(int fd, void* buf, size_t size, off_t offset,
                       Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue write operation.
     */
    BatchBuilder& write(int fd, const void* buf, size_t size, off_t offset,
                        Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue vectored read (readv).
     */
    BatchBuilder& readv(int fd, const struct iovec* iov, int iovcnt, off_t offset,
                        Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue vectored write (writev).
     */
    BatchBuilder& writev(int fd, const struct iovec* iov, int iovcnt, off_t offset,
                         Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue fsync.
     */
    BatchBuilder& fsync(int fd, bool datasync = false,
                        Callback cb = nullptr, void* user_data = nullptr);

    //--------------------------------------------------------------------------
    // File Management
    //--------------------------------------------------------------------------

    /**
     * Queue open (openat).
     */
    BatchBuilder& open(int dirfd, const char* path, int flags, mode_t mode,
                       Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue close.
     */
    BatchBuilder& close(int fd, Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue statx.
     */
    BatchBuilder& statx(int dirfd, const char* path, int flags, unsigned mask,
                        struct statx* statxbuf,
                        Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue mkdir.
     */
    BatchBuilder& mkdir(int dirfd, const char* path, mode_t mode,
                        Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue unlink.
     */
    BatchBuilder& unlink(int dirfd, const char* path, int flags,
                         Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Queue rename.
     */
    BatchBuilder& rename(int olddirfd, const char* oldpath,
                         int newdirfd, const char* newpath, unsigned flags,
                         Callback cb = nullptr, void* user_data = nullptr);

    //--------------------------------------------------------------------------
    // Network I/O
    //--------------------------------------------------------------------------

    BatchBuilder& accept(int sockfd, struct sockaddr* addr, socklen_t* addrlen,
                         int flags, Callback cb = nullptr, void* user_data = nullptr);

    BatchBuilder& connect(int sockfd, const struct sockaddr* addr, socklen_t addrlen,
                          Callback cb = nullptr, void* user_data = nullptr);

    BatchBuilder& send(int sockfd, const void* buf, size_t len, int flags,
                       Callback cb = nullptr, void* user_data = nullptr);

    BatchBuilder& recv(int sockfd, void* buf, size_t len, int flags,
                       Callback cb = nullptr, void* user_data = nullptr);

    //--------------------------------------------------------------------------
    // Advanced
    //--------------------------------------------------------------------------

    /**
     * Queue timeout (relative).
     */
    BatchBuilder& timeout(uint64_t ns, Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Link next operation (execute only if previous succeeds).
     */
    BatchBuilder& link();

    /**
     * Hard link (execute only if previous succeeds, fail rest if this fails).
     */
    BatchBuilder& hardlink();

    /**
     * Set fixed file index (for registered files).
     */
    BatchBuilder& fixed_file(int registered_index);

    /**
     * Set fixed buffer index (for registered buffers).
     */
    BatchBuilder& fixed_buffer(int registered_index);

    /**
     * No-op (useful for linked chains).
     */
    BatchBuilder& nop(Callback cb = nullptr, void* user_data = nullptr);

    //--------------------------------------------------------------------------
    // Submission
    //--------------------------------------------------------------------------

    /**
     * Submit all queued operations.
     * With SQPOLL, this may not need a syscall.
     *
     * @return Number of operations submitted
     */
    int submit();

    /**
     * Submit and wait for at least min_complete completions.
     */
    int submit_and_wait(uint32_t min_complete);

    /**
     * Get number of pending operations.
     */
    size_t pending() const { return pending_count_; }

    /**
     * Clear pending operations without submitting.
     */
    void clear();

private:
    class UringContext& ctx_;
    size_t pending_count_ = 0;
    bool link_next_ = false;
    bool hardlink_next_ = false;
    int fixed_file_idx_ = -1;
    int fixed_buf_idx_ = -1;

    struct io_uring_sqe* get_sqe();
    void apply_flags(struct io_uring_sqe* sqe);
};

//==============================================================================
// io_uring Context
//==============================================================================

class UringContext {
public:
    UringContext();
    ~UringContext();

    // Non-copyable
    UringContext(const UringContext&) = delete;
    UringContext& operator=(const UringContext&) = delete;

    /**
     * Initialize io_uring with configuration.
     */
    bool initialize(const UringConfig& config = UringConfig::balanced());

    /**
     * Shutdown and release resources.
     */
    void shutdown();

    bool is_initialized() const { return initialized_; }

    //--------------------------------------------------------------------------
    // Registration (for zero-copy and efficiency)
    //--------------------------------------------------------------------------

    /**
     * Register file descriptors for faster access.
     * Returns starting index, or -1 on failure.
     */
    int register_files(int* fds, size_t count);

    /**
     * Update registered file at index.
     */
    bool update_registered_file(int index, int new_fd);

    /**
     * Unregister all files.
     */
    void unregister_files();

    /**
     * Register buffers for zero-copy I/O.
     * Returns starting index, or -1 on failure.
     */
    int register_buffers(struct iovec* iovs, size_t count);

    /**
     * Unregister all buffers.
     */
    void unregister_buffers();

    //--------------------------------------------------------------------------
    // Completion Processing
    //--------------------------------------------------------------------------

    /**
     * Process available completions (non-blocking).
     *
     * @param max_completions Maximum to process (0 = all available)
     * @return Number of completions processed
     */
    uint32_t process_completions(uint32_t max_completions = 0);

    /**
     * Wait for completions (blocking).
     *
     * @param min_completions Minimum to wait for
     * @param timeout_ms Timeout in milliseconds (0 = infinite)
     * @return Number of completions processed
     */
    uint32_t wait_completions(uint32_t min_completions, uint32_t timeout_ms = 0);

    /**
     * Poll for completions (busy-wait).
     * Use only with iopoll enabled.
     */
    uint32_t poll_completions();

    //--------------------------------------------------------------------------
    // Statistics
    //--------------------------------------------------------------------------

    struct Statistics {
        std::atomic<uint64_t> submissions{0};
        std::atomic<uint64_t> completions{0};
        std::atomic<uint64_t> errors{0};
        std::atomic<uint64_t> sq_full_events{0};  // Submission queue was full
        std::atomic<uint64_t> cq_overflow_events{0};  // Completion queue overflow

        void reset() {
            submissions = 0;
            completions = 0;
            errors = 0;
            sq_full_events = 0;
            cq_overflow_events = 0;
        }
    };

    const Statistics& stats() const { return stats_; }
    void reset_stats() { stats_.reset(); }

    //--------------------------------------------------------------------------
    // Internal (for BatchBuilder)
    //--------------------------------------------------------------------------

    struct io_uring* ring() { return ring_.get(); }
    const UringConfig& config() const { return config_; }

private:
    bool initialized_ = false;
    UringConfig config_;
    std::unique_ptr<struct io_uring> ring_;
    Statistics stats_;

    // Callback storage
    struct CallbackData {
        Callback callback;
        void* user_data;
    };
    std::vector<std::unique_ptr<CallbackData>> callbacks_;

    friend class BatchBuilder;
    CallbackData* alloc_callback(Callback cb, void* user_data);
    void free_callback(CallbackData* cbd);
    void process_cqe(struct io_uring_cqe* cqe);
};

//==============================================================================
// Convenience Functions
//==============================================================================

/**
 * Simple synchronous batch read of multiple files.
 *
 * Usage:
 *   std::vector<BatchReadResult> results;
 *   batch_read_files(ctx, {
 *       {"/path/to/file1", buf1, size1, 0},
 *       {"/path/to/file2", buf2, size2, 0},
 *       ...
 *   }, results);
 */
struct BatchReadRequest {
    const char* path;
    void* buffer;
    size_t size;
    off_t offset;
};

struct BatchReadResult {
    ssize_t bytes_read;
    int error;  // 0 on success, errno on failure
};

bool batch_read_files(UringContext& ctx,
                      const std::vector<BatchReadRequest>& requests,
                      std::vector<BatchReadResult>& results);

/**
 * Parallel directory scan with io_uring.
 * Much faster than sequential readdir() for large directories.
 */
struct DirEntry {
    char name[256];
    uint8_t type;  // DT_REG, DT_DIR, etc.
    uint64_t inode;
    uint64_t size;
};

bool parallel_readdir(UringContext& ctx, const char* dirpath,
                      std::vector<DirEntry>& entries);

/**
 * Batch stat multiple paths.
 */
struct BatchStatRequest {
    const char* path;
};

struct BatchStatResult {
    int error;
    struct statx statx;
};

bool batch_stat(UringContext& ctx,
                const std::vector<BatchStatRequest>& requests,
                std::vector<BatchStatResult>& results);

//==============================================================================
// High-Level Async File API
//==============================================================================

/**
 * Async file handle using io_uring.
 */
class AsyncFile {
public:
    AsyncFile(UringContext& ctx);
    ~AsyncFile();

    /**
     * Open file asynchronously.
     */
    void open(const char* path, int flags, mode_t mode, Callback cb, void* user_data = nullptr);

    /**
     * Open file synchronously.
     */
    bool open_sync(const char* path, int flags, mode_t mode = 0644);

    /**
     * Check if file is open.
     */
    bool is_open() const { return fd_ >= 0; }
    int fd() const { return fd_; }

    /**
     * Async read.
     */
    void read(void* buf, size_t size, off_t offset, Callback cb, void* user_data = nullptr);

    /**
     * Async write.
     */
    void write(const void* buf, size_t size, off_t offset, Callback cb, void* user_data = nullptr);

    /**
     * Sync read (submits and waits).
     */
    ssize_t read_sync(void* buf, size_t size, off_t offset);

    /**
     * Sync write (submits and waits).
     */
    ssize_t write_sync(const void* buf, size_t size, off_t offset);

    /**
     * Async close.
     */
    void close(Callback cb = nullptr, void* user_data = nullptr);

    /**
     * Sync close.
     */
    void close_sync();

private:
    UringContext& ctx_;
    int fd_ = -1;
    int registered_idx_ = -1;
};

//==============================================================================
// Event Loop Integration
//==============================================================================

/**
 * Event loop that processes io_uring completions.
 * Can integrate with other event sources.
 */
class EventLoop {
public:
    EventLoop(UringContext& ctx);
    ~EventLoop();

    /**
     * Run event loop until stop() is called.
     */
    void run();

    /**
     * Run one iteration of event loop.
     * @param timeout_ms Maximum time to wait (0 = non-blocking)
     * @return Number of events processed
     */
    uint32_t run_once(uint32_t timeout_ms = 100);

    /**
     * Stop the event loop.
     */
    void stop();

    /**
     * Check if loop is running.
     */
    bool is_running() const { return running_.load(std::memory_order_acquire); }

    /**
     * Schedule callback to run on next iteration.
     */
    void post(std::function<void()> fn);

    /**
     * Schedule callback to run after delay.
     */
    void post_delayed(std::function<void()> fn, std::chrono::milliseconds delay);

private:
    UringContext& ctx_;
    std::atomic<bool> running_{false};
    std::atomic<bool> stop_requested_{false};

    // Posted callbacks
    std::vector<std::function<void()>> posted_;
    std::mutex posted_mutex_;

    // Delayed callbacks
    struct DelayedCallback {
        std::chrono::steady_clock::time_point when;
        std::function<void()> fn;
    };
    std::vector<DelayedCallback> delayed_;
};

//==============================================================================
// WSL2-Specific Optimizations
//==============================================================================

/**
 * Batch processor optimized for WSL2's VM exit overhead.
 *
 * Key insight: In WSL2, syscalls cross hypervisor boundary.
 * Batching amortizes this cost across many operations.
 *
 * Strategy:
 * 1. Collect operations until batch is "full" or timeout
 * 2. Submit entire batch in one syscall
 * 3. Process completions in batches
 */
class WSL2BatchProcessor {
public:
    WSL2BatchProcessor(UringContext& ctx);

    struct Config {
        size_t max_batch_size;      // Max ops before auto-submit (default: 256)
        uint32_t batch_timeout_us;  // Max time before auto-submit (default: 100)
        bool auto_submit;           // Auto-submit when batch is ready
    };

    void configure(const Config& cfg);

    /**
     * Queue operation for batching.
     * May trigger submit if batch is full.
     */
    void queue_read(int fd, void* buf, size_t size, off_t offset,
                    Callback cb, void* user_data);
    void queue_write(int fd, const void* buf, size_t size, off_t offset,
                     Callback cb, void* user_data);

    /**
     * Force submit current batch.
     */
    int flush();

    /**
     * Process completions and check for auto-submit.
     * Call this periodically.
     */
    uint32_t tick();

private:
    UringContext& ctx_;
    BatchBuilder batch_;
    Config config_;
    std::chrono::steady_clock::time_point batch_start_;
    size_t batch_count_ = 0;

    void maybe_auto_submit();
};

} // namespace uring
} // namespace strix

#endif // STRIX_TURBO_URING_BATCH_H
