/**
 * io_uring Syscall Batching Framework - Implementation
 *
 * Implements the interfaces defined in uring_batch.h
 *
 * Build: g++ -O3 -std=c++17 uring_batch.cpp -luring -o your_app
 */

#include "uring_batch.h"

#include <liburing.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <cstring>
#include <algorithm>
#include <mutex>

namespace strix {
namespace uring {

//==============================================================================
// UringContext Implementation
//==============================================================================

UringContext::UringContext()
    : ring_(std::make_unique<struct io_uring>()) {
}

UringContext::~UringContext() {
    shutdown();
}

bool UringContext::initialize(const UringConfig& config) {
    if (initialized_) {
        return true;
    }

    config_ = config;

    struct io_uring_params params;
    std::memset(&params, 0, sizeof(params));

    // Set flags based on configuration
    if (config.use_sqpoll) {
        params.flags |= IORING_SETUP_SQPOLL;
        if (config.sq_thread_cpu >= 0) {
            params.flags |= IORING_SETUP_SQ_AFF;
            params.sq_thread_cpu = static_cast<uint32_t>(config.sq_thread_cpu);
        }
        params.sq_thread_idle = config.sq_thread_idle_ms;
    }

    if (config.use_iopoll) {
        params.flags |= IORING_SETUP_IOPOLL;
    }

    int ret = io_uring_queue_init_params(config.queue_depth, ring_.get(), &params);

    if (ret < 0) {
        // Try without SQPOLL if it failed
        if (config.use_sqpoll) {
            std::memset(&params, 0, sizeof(params));
            ret = io_uring_queue_init_params(config.queue_depth, ring_.get(), &params);
        }

        if (ret < 0) {
            return false;
        }
    }

    initialized_ = true;
    return true;
}

void UringContext::shutdown() {
    if (!initialized_) {
        return;
    }

    // Process remaining completions
    process_completions(0);

    // Unregister resources
    unregister_files();
    unregister_buffers();

    io_uring_queue_exit(ring_.get());
    initialized_ = false;

    // Clear callbacks
    callbacks_.clear();
}

int UringContext::register_files(int* fds, size_t count) {
    if (!initialized_ || !fds || count == 0) {
        return -1;
    }

    int ret = io_uring_register_files(ring_.get(), fds, static_cast<unsigned>(count));
    return ret < 0 ? -1 : 0;
}

bool UringContext::update_registered_file(int index, int new_fd) {
    if (!initialized_ || index < 0) {
        return false;
    }

    int ret = io_uring_register_files_update(ring_.get(), index, &new_fd, 1);
    return ret >= 0;
}

void UringContext::unregister_files() {
    if (initialized_) {
        io_uring_unregister_files(ring_.get());
    }
}

int UringContext::register_buffers(struct iovec* iovs, size_t count) {
    if (!initialized_ || !iovs || count == 0) {
        return -1;
    }

    int ret = io_uring_register_buffers(ring_.get(), iovs, static_cast<unsigned>(count));
    return ret < 0 ? -1 : 0;
}

void UringContext::unregister_buffers() {
    if (initialized_) {
        io_uring_unregister_buffers(ring_.get());
    }
}

UringContext::CallbackData* UringContext::alloc_callback(Callback cb, void* user_data) {
    if (!cb) {
        return nullptr;
    }

    auto cbd = std::make_unique<CallbackData>();
    cbd->callback = std::move(cb);
    cbd->user_data = user_data;

    CallbackData* ptr = cbd.get();
    callbacks_.push_back(std::move(cbd));
    return ptr;
}

void UringContext::free_callback(CallbackData* cbd) {
    // Find and remove from vector
    auto it = std::find_if(callbacks_.begin(), callbacks_.end(),
        [cbd](const std::unique_ptr<CallbackData>& p) { return p.get() == cbd; });

    if (it != callbacks_.end()) {
        callbacks_.erase(it);
    }
}

void UringContext::process_cqe(struct io_uring_cqe* cqe) {
    CallbackData* cbd = static_cast<CallbackData*>(io_uring_cqe_get_data(cqe));

    if (cbd && cbd->callback) {
        cbd->callback(cqe->res, cbd->user_data);
        free_callback(cbd);
    }

    stats_.completions.fetch_add(1, std::memory_order_relaxed);

    if (cqe->res < 0) {
        stats_.errors.fetch_add(1, std::memory_order_relaxed);
    }
}

uint32_t UringContext::process_completions(uint32_t max_completions) {
    if (!initialized_) {
        return 0;
    }

    struct io_uring_cqe* cqe;
    unsigned head;
    uint32_t count = 0;

    io_uring_for_each_cqe(ring_.get(), head, cqe) {
        process_cqe(cqe);
        count++;

        if (max_completions > 0 && count >= max_completions) {
            break;
        }
    }

    io_uring_cq_advance(ring_.get(), count);
    return count;
}

uint32_t UringContext::wait_completions(uint32_t min_completions, uint32_t timeout_ms) {
    if (!initialized_ || min_completions == 0) {
        return process_completions(0);
    }

    struct __kernel_timespec ts;
    struct __kernel_timespec* ts_ptr = nullptr;

    if (timeout_ms > 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (timeout_ms % 1000) * 1000000;
        ts_ptr = &ts;
    }

    struct io_uring_cqe* cqe;
    int ret = io_uring_wait_cqes(ring_.get(), &cqe, min_completions, ts_ptr, nullptr);

    if (ret < 0) {
        return 0;
    }

    return process_completions(0);
}

uint32_t UringContext::poll_completions() {
    // For IOPOLL mode, we need to reap completions via submit
    if (!initialized_ || !config_.use_iopoll) {
        return process_completions(0);
    }

    io_uring_submit(ring_.get());
    return process_completions(0);
}

//==============================================================================
// BatchBuilder Implementation
//==============================================================================

BatchBuilder::BatchBuilder(UringContext& ctx)
    : ctx_(ctx) {
}

BatchBuilder::~BatchBuilder() {
    // Don't auto-submit - user must explicitly call submit()
}

struct io_uring_sqe* BatchBuilder::get_sqe() {
    if (!ctx_.is_initialized()) {
        return nullptr;
    }

    struct io_uring_sqe* sqe = io_uring_get_sqe(ctx_.ring());
    if (!sqe) {
        ctx_.stats_.sq_full_events.fetch_add(1, std::memory_order_relaxed);

        // Try submitting to make room
        io_uring_submit(ctx_.ring());
        sqe = io_uring_get_sqe(ctx_.ring());
    }

    return sqe;
}

void BatchBuilder::apply_flags(struct io_uring_sqe* sqe) {
    if (link_next_) {
        sqe->flags |= IOSQE_IO_LINK;
        link_next_ = false;
    }

    if (hardlink_next_) {
        sqe->flags |= IOSQE_IO_HARDLINK;
        hardlink_next_ = false;
    }

    if (fixed_file_idx_ >= 0) {
        sqe->flags |= IOSQE_FIXED_FILE;
        // Note: fd should be the registered index, not actual fd
        fixed_file_idx_ = -1;
    }

    if (fixed_buf_idx_ >= 0) {
        // Fixed buffer index is set in specific prep functions
        fixed_buf_idx_ = -1;
    }
}

BatchBuilder& BatchBuilder::read(int fd, void* buf, size_t size, off_t offset,
                                  Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_read(sqe, fd, buf, static_cast<unsigned>(size), offset);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::write(int fd, const void* buf, size_t size, off_t offset,
                                   Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_write(sqe, fd, buf, static_cast<unsigned>(size), offset);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::readv(int fd, const struct iovec* iov, int iovcnt, off_t offset,
                                   Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_readv(sqe, fd, iov, static_cast<unsigned>(iovcnt), offset);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::writev(int fd, const struct iovec* iov, int iovcnt, off_t offset,
                                    Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_writev(sqe, fd, iov, static_cast<unsigned>(iovcnt), offset);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::fsync(int fd, bool datasync, Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    unsigned flags = datasync ? IORING_FSYNC_DATASYNC : 0;
    io_uring_prep_fsync(sqe, fd, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::open(int dirfd, const char* path, int flags, mode_t mode,
                                  Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_openat(sqe, dirfd, path, flags, mode);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::close(int fd, Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_close(sqe, fd);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::statx(int dirfd, const char* path, int flags, unsigned mask,
                                   struct statx* statxbuf, Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_statx(sqe, dirfd, path, flags, mask, statxbuf);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::mkdir(int dirfd, const char* path, mode_t mode,
                                   Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_mkdirat(sqe, dirfd, path, mode);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::unlink(int dirfd, const char* path, int flags,
                                    Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_unlinkat(sqe, dirfd, path, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::rename(int olddirfd, const char* oldpath,
                                    int newdirfd, const char* newpath, unsigned flags,
                                    Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_renameat(sqe, olddirfd, oldpath, newdirfd, newpath, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::accept(int sockfd, struct sockaddr* addr, socklen_t* addrlen,
                                    int flags, Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_accept(sqe, sockfd, addr, addrlen, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::connect(int sockfd, const struct sockaddr* addr, socklen_t addrlen,
                                     Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_connect(sqe, sockfd, addr, addrlen);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::send(int sockfd, const void* buf, size_t len, int flags,
                                  Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_send(sqe, sockfd, buf, len, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::recv(int sockfd, void* buf, size_t len, int flags,
                                  Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_recv(sqe, sockfd, buf, len, flags);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::timeout(uint64_t ns, Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    // Allocate timespec (needs to stay valid until completion)
    static thread_local struct __kernel_timespec ts;
    ts.tv_sec = ns / 1000000000ULL;
    ts.tv_nsec = ns % 1000000000ULL;

    io_uring_prep_timeout(sqe, &ts, 0, 0);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

BatchBuilder& BatchBuilder::link() {
    link_next_ = true;
    return *this;
}

BatchBuilder& BatchBuilder::hardlink() {
    hardlink_next_ = true;
    return *this;
}

BatchBuilder& BatchBuilder::fixed_file(int registered_index) {
    fixed_file_idx_ = registered_index;
    return *this;
}

BatchBuilder& BatchBuilder::fixed_buffer(int registered_index) {
    fixed_buf_idx_ = registered_index;
    return *this;
}

BatchBuilder& BatchBuilder::nop(Callback cb, void* user_data) {
    struct io_uring_sqe* sqe = get_sqe();
    if (!sqe) return *this;

    io_uring_prep_nop(sqe);

    auto* cbd = ctx_.alloc_callback(std::move(cb), user_data);
    io_uring_sqe_set_data(sqe, cbd);

    apply_flags(sqe);
    pending_count_++;

    return *this;
}

int BatchBuilder::submit() {
    if (!ctx_.is_initialized() || pending_count_ == 0) {
        return 0;
    }

    int ret = io_uring_submit(ctx_.ring());
    if (ret >= 0) {
        ctx_.stats_.submissions.fetch_add(ret, std::memory_order_relaxed);
    }

    pending_count_ = 0;
    return ret;
}

int BatchBuilder::submit_and_wait(uint32_t min_complete) {
    if (!ctx_.is_initialized() || pending_count_ == 0) {
        return 0;
    }

    int ret = io_uring_submit_and_wait(ctx_.ring(), min_complete);
    if (ret >= 0) {
        ctx_.stats_.submissions.fetch_add(ret, std::memory_order_relaxed);
    }

    pending_count_ = 0;
    return ret;
}

void BatchBuilder::clear() {
    // Clear pending SQEs by resetting the SQ head
    // This is tricky - we'd need to access ring internals
    // For now, just reset our counter
    pending_count_ = 0;
    link_next_ = false;
    hardlink_next_ = false;
    fixed_file_idx_ = -1;
    fixed_buf_idx_ = -1;
}

//==============================================================================
// Convenience Functions
//==============================================================================

bool batch_read_files(UringContext& ctx,
                      const std::vector<BatchReadRequest>& requests,
                      std::vector<BatchReadResult>& results) {
    if (!ctx.is_initialized() || requests.empty()) {
        return false;
    }

    results.resize(requests.size());

    // Open files, read, close - all batched
    std::vector<int> fds(requests.size(), -1);
    std::vector<struct statx> statx_results(requests.size());

    // Phase 1: Open all files
    BatchBuilder batch(ctx);
    for (size_t i = 0; i < requests.size(); i++) {
        batch.open(AT_FDCWD, requests[i].path, O_RDONLY, 0,
            [](int32_t result, void* data) {
                int* fd_ptr = static_cast<int*>(data);
                *fd_ptr = result;
            }, &fds[i]);
    }
    batch.submit_and_wait(static_cast<uint32_t>(requests.size()));
    ctx.process_completions(0);

    // Phase 2: Read all files
    BatchBuilder read_batch(ctx);
    for (size_t i = 0; i < requests.size(); i++) {
        if (fds[i] >= 0) {
            read_batch.read(fds[i], requests[i].buffer, requests[i].size, requests[i].offset,
                [](int32_t result, void* data) {
                    BatchReadResult* r = static_cast<BatchReadResult*>(data);
                    r->bytes_read = result >= 0 ? result : 0;
                    r->error = result < 0 ? -result : 0;
                }, &results[i]);
        } else {
            results[i].bytes_read = 0;
            results[i].error = -fds[i];
        }
    }
    read_batch.submit_and_wait(static_cast<uint32_t>(requests.size()));
    ctx.process_completions(0);

    // Phase 3: Close all files
    BatchBuilder close_batch(ctx);
    for (size_t i = 0; i < requests.size(); i++) {
        if (fds[i] >= 0) {
            close_batch.close(fds[i]);
        }
    }
    close_batch.submit_and_wait(static_cast<uint32_t>(requests.size()));
    ctx.process_completions(0);

    return true;
}

bool parallel_readdir(UringContext& ctx, const char* dirpath,
                      std::vector<DirEntry>& entries) {
    // io_uring doesn't have direct readdir support
    // Fall back to synchronous for now
    DIR* dir = opendir(dirpath);
    if (!dir) {
        return false;
    }

    struct dirent* ent;
    while ((ent = readdir(dir)) != nullptr) {
        if (ent->d_name[0] == '.' &&
            (ent->d_name[1] == '\0' ||
             (ent->d_name[1] == '.' && ent->d_name[2] == '\0'))) {
            continue;
        }

        DirEntry entry;
        std::strncpy(entry.name, ent->d_name, sizeof(entry.name) - 1);
        entry.name[sizeof(entry.name) - 1] = '\0';
        entry.type = ent->d_type;
        entry.inode = ent->d_ino;
        entry.size = 0;  // Would need stat to get this

        entries.push_back(entry);
    }

    closedir(dir);

    // Now batch statx for sizes
    if (!entries.empty() && ctx.is_initialized()) {
        std::vector<struct statx> statx_bufs(entries.size());
        std::string base_path = dirpath;
        if (base_path.back() != '/') {
            base_path += '/';
        }

        BatchBuilder batch(ctx);
        for (size_t i = 0; i < entries.size(); i++) {
            std::string full_path = base_path + entries[i].name;
            batch.statx(AT_FDCWD, full_path.c_str(), 0, STATX_SIZE, &statx_bufs[i],
                [](int32_t result, void* data) {
                    (void)result;
                    (void)data;
                }, nullptr);
        }
        batch.submit_and_wait(static_cast<uint32_t>(entries.size()));
        ctx.process_completions(0);

        for (size_t i = 0; i < entries.size(); i++) {
            entries[i].size = statx_bufs[i].stx_size;
        }
    }

    return true;
}

bool batch_stat(UringContext& ctx,
                const std::vector<BatchStatRequest>& requests,
                std::vector<BatchStatResult>& results) {
    if (!ctx.is_initialized() || requests.empty()) {
        return false;
    }

    results.resize(requests.size());

    BatchBuilder batch(ctx);
    for (size_t i = 0; i < requests.size(); i++) {
        batch.statx(AT_FDCWD, requests[i].path, 0, STATX_BASIC_STATS, &results[i].statx,
            [](int32_t result, void* data) {
                BatchStatResult* r = static_cast<BatchStatResult*>(data);
                r->error = result < 0 ? -result : 0;
            }, &results[i]);
    }

    batch.submit_and_wait(static_cast<uint32_t>(requests.size()));
    ctx.process_completions(0);

    return true;
}

//==============================================================================
// AsyncFile Implementation
//==============================================================================

AsyncFile::AsyncFile(UringContext& ctx)
    : ctx_(ctx) {
}

AsyncFile::~AsyncFile() {
    if (fd_ >= 0) {
        close_sync();
    }
}

void AsyncFile::open(const char* path, int flags, mode_t mode, Callback cb, void* user_data) {
    BatchBuilder batch(ctx_);
    batch.open(AT_FDCWD, path, flags, mode,
        [this, cb, user_data](int32_t result, void*) {
            if (result >= 0) {
                fd_ = result;
            }
            if (cb) {
                cb(result, user_data);
            }
        }, nullptr);
    batch.submit();
}

bool AsyncFile::open_sync(const char* path, int flags, mode_t mode) {
    bool success = false;

    BatchBuilder batch(ctx_);
    batch.open(AT_FDCWD, path, flags, mode,
        [this, &success](int32_t result, void*) {
            if (result >= 0) {
                fd_ = result;
                success = true;
            }
        }, nullptr);
    batch.submit_and_wait(1);
    ctx_.process_completions(0);

    return success;
}

void AsyncFile::read(void* buf, size_t size, off_t offset, Callback cb, void* user_data) {
    if (fd_ < 0) {
        if (cb) cb(-EBADF, user_data);
        return;
    }

    BatchBuilder batch(ctx_);
    batch.read(fd_, buf, size, offset, std::move(cb), user_data);
    batch.submit();
}

void AsyncFile::write(const void* buf, size_t size, off_t offset, Callback cb, void* user_data) {
    if (fd_ < 0) {
        if (cb) cb(-EBADF, user_data);
        return;
    }

    BatchBuilder batch(ctx_);
    batch.write(fd_, buf, size, offset, std::move(cb), user_data);
    batch.submit();
}

ssize_t AsyncFile::read_sync(void* buf, size_t size, off_t offset) {
    if (fd_ < 0) {
        return -EBADF;
    }

    ssize_t result = 0;

    BatchBuilder batch(ctx_);
    batch.read(fd_, buf, size, offset,
        [&result](int32_t res, void*) {
            result = res;
        }, nullptr);
    batch.submit_and_wait(1);
    ctx_.process_completions(0);

    return result;
}

ssize_t AsyncFile::write_sync(const void* buf, size_t size, off_t offset) {
    if (fd_ < 0) {
        return -EBADF;
    }

    ssize_t result = 0;

    BatchBuilder batch(ctx_);
    batch.write(fd_, buf, size, offset,
        [&result](int32_t res, void*) {
            result = res;
        }, nullptr);
    batch.submit_and_wait(1);
    ctx_.process_completions(0);

    return result;
}

void AsyncFile::close(Callback cb, void* user_data) {
    if (fd_ < 0) {
        if (cb) cb(0, user_data);
        return;
    }

    int fd = fd_;
    fd_ = -1;

    BatchBuilder batch(ctx_);
    batch.close(fd, std::move(cb), user_data);
    batch.submit();
}

void AsyncFile::close_sync() {
    if (fd_ < 0) {
        return;
    }

    int fd = fd_;
    fd_ = -1;

    BatchBuilder batch(ctx_);
    batch.close(fd);
    batch.submit_and_wait(1);
    ctx_.process_completions(0);
}

//==============================================================================
// EventLoop Implementation
//==============================================================================

EventLoop::EventLoop(UringContext& ctx)
    : ctx_(ctx) {
}

EventLoop::~EventLoop() {
    stop();
}

void EventLoop::run() {
    running_.store(true, std::memory_order_release);
    stop_requested_.store(false, std::memory_order_release);

    while (!stop_requested_.load(std::memory_order_acquire)) {
        run_once(100);
    }

    running_.store(false, std::memory_order_release);
}

uint32_t EventLoop::run_once(uint32_t timeout_ms) {
    // Process posted callbacks
    {
        std::lock_guard<std::mutex> lock(posted_mutex_);
        for (auto& fn : posted_) {
            fn();
        }
        posted_.clear();
    }

    // Process delayed callbacks
    auto now = std::chrono::steady_clock::now();
    auto it = delayed_.begin();
    while (it != delayed_.end()) {
        if (it->when <= now) {
            it->fn();
            it = delayed_.erase(it);
        } else {
            ++it;
        }
    }

    // Process io_uring completions
    return ctx_.wait_completions(1, timeout_ms);
}

void EventLoop::stop() {
    stop_requested_.store(true, std::memory_order_release);
}

void EventLoop::post(std::function<void()> fn) {
    std::lock_guard<std::mutex> lock(posted_mutex_);
    posted_.push_back(std::move(fn));
}

void EventLoop::post_delayed(std::function<void()> fn, std::chrono::milliseconds delay) {
    DelayedCallback dc;
    dc.when = std::chrono::steady_clock::now() + delay;
    dc.fn = std::move(fn);
    delayed_.push_back(std::move(dc));
}

//==============================================================================
// WSL2BatchProcessor Implementation
//==============================================================================

WSL2BatchProcessor::WSL2BatchProcessor(UringContext& ctx)
    : ctx_(ctx)
    , batch_(ctx) {
    config_.max_batch_size = 256;
    config_.batch_timeout_us = 100;
    config_.auto_submit = true;
}

void WSL2BatchProcessor::configure(const Config& cfg) {
    config_ = cfg;
}

void WSL2BatchProcessor::queue_read(int fd, void* buf, size_t size, off_t offset,
                                     Callback cb, void* user_data) {
    if (batch_count_ == 0) {
        batch_start_ = std::chrono::steady_clock::now();
    }

    batch_.read(fd, buf, size, offset, std::move(cb), user_data);
    batch_count_++;

    maybe_auto_submit();
}

void WSL2BatchProcessor::queue_write(int fd, const void* buf, size_t size, off_t offset,
                                      Callback cb, void* user_data) {
    if (batch_count_ == 0) {
        batch_start_ = std::chrono::steady_clock::now();
    }

    batch_.write(fd, buf, size, offset, std::move(cb), user_data);
    batch_count_++;

    maybe_auto_submit();
}

int WSL2BatchProcessor::flush() {
    int ret = batch_.submit();
    batch_count_ = 0;
    return ret;
}

uint32_t WSL2BatchProcessor::tick() {
    // Check for timeout-based auto-submit
    if (config_.auto_submit && batch_count_ > 0) {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - batch_start_);

        if (elapsed.count() >= config_.batch_timeout_us) {
            flush();
        }
    }

    return ctx_.process_completions(0);
}

void WSL2BatchProcessor::maybe_auto_submit() {
    if (!config_.auto_submit) {
        return;
    }

    if (batch_count_ >= config_.max_batch_size) {
        flush();
    }
}

} // namespace uring
} // namespace strix
