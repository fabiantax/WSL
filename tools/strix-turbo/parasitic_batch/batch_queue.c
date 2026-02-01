/*
 * Strix-Turbo Thread-Local Batch Queue Implementation
 */

#define _GNU_SOURCE
#include "batch_queue.h"
#include "uring_backend.h"
#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <dlfcn.h>

/* ============================================================================
 * Thread-Local Queue Structure
 * ============================================================================ */

struct strix_batch_queue {
    /* Operations array */
    strix_batch_op_t* ops;
    size_t capacity;
    size_t count;

    /* io_uring context */
    strix_uring_ctx_t* uring;

    /* Sequence counter */
    uint64_t seq_counter;

    /* Timing */
    struct timespec last_submit;
    bool timer_started;

    /* Statistics */
    strix_queue_stats_t stats;

    /* Thread info */
    pthread_t owner_thread;
    bool initialized;
};

/* Thread-local queue */
static __thread strix_batch_queue_t* tls_queue = NULL;
static pthread_key_t queue_key;
static pthread_once_t queue_key_once = PTHREAD_ONCE_INIT;

/* Original syscall functions (for fallback) */
static ssize_t (*real_read)(int, void*, size_t) = NULL;
static ssize_t (*real_write)(int, const void*, size_t) = NULL;
static ssize_t (*real_pread)(int, void*, size_t, off_t) = NULL;
static ssize_t (*real_pwrite)(int, const void*, size_t, off_t) = NULL;
static int (*real_open)(const char*, int, ...) = NULL;
static int (*real_close)(int) = NULL;
static int (*real_stat)(const char*, struct stat*) = NULL;
static int (*real_fstat)(int, struct stat*) = NULL;
static int (*real_lstat)(const char*, struct stat*) = NULL;
static int (*real_fsync)(int) = NULL;
static int (*real_fdatasync)(int) = NULL;

/* Initialization flag */
static bool s_initialized = false;
static pthread_mutex_t s_init_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ============================================================================
 * Initialization
 * ============================================================================ */

static void queue_destructor(void* ptr) {
    strix_batch_queue_t* queue = ptr;
    if (!queue) return;

    /* Flush any pending operations */
    if (queue->count > 0) {
        strix_queue_submit_and_wait(queue);
    }

    /* Cleanup */
    if (queue->uring) {
        strix_uring_destroy(queue->uring);
    }
    free(queue->ops);
    free(queue);
}

static void init_queue_key(void) {
    pthread_key_create(&queue_key, queue_destructor);
}

static void load_real_functions(void) {
    /* Load original libc functions */
    real_read = dlsym(RTLD_NEXT, "read");
    real_write = dlsym(RTLD_NEXT, "write");
    real_pread = dlsym(RTLD_NEXT, "pread");
    real_pwrite = dlsym(RTLD_NEXT, "pwrite");
    real_open = dlsym(RTLD_NEXT, "open");
    real_close = dlsym(RTLD_NEXT, "close");
    real_stat = dlsym(RTLD_NEXT, "stat");
    real_fstat = dlsym(RTLD_NEXT, "fstat");
    real_lstat = dlsym(RTLD_NEXT, "lstat");
    real_fsync = dlsym(RTLD_NEXT, "fsync");
    real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");

    /* Fallback to syscall if dlsym fails */
    if (!real_read) {
        STRIX_DEBUG("dlsym(read) failed, using syscall fallback");
    }
}

int strix_queue_init(void) {
    pthread_mutex_lock(&s_init_mutex);

    if (s_initialized) {
        pthread_mutex_unlock(&s_init_mutex);
        return 0;
    }

    /* Initialize configuration */
    strix_config_init();

    /* Load real functions */
    load_real_functions();

    /* Initialize thread-local key */
    pthread_once(&queue_key_once, init_queue_key);

    /* Check io_uring availability */
    if (!strix_uring_is_available()) {
        STRIX_DEBUG("io_uring not available, batching disabled");
        g_strix_config.enabled = false;
    }

    s_initialized = true;
    pthread_mutex_unlock(&s_init_mutex);

    STRIX_DEBUG("Batch queue subsystem initialized");
    return 0;
}

void strix_queue_cleanup(void) {
    pthread_mutex_lock(&s_init_mutex);
    s_initialized = false;
    pthread_mutex_unlock(&s_init_mutex);
}

/* ============================================================================
 * Queue Management
 * ============================================================================ */

static strix_batch_queue_t* create_queue(void) {
    strix_batch_queue_t* queue = calloc(1, sizeof(strix_batch_queue_t));
    if (!queue) return NULL;

    queue->capacity = strix_get_batch_size();
    queue->ops = calloc(queue->capacity, sizeof(strix_batch_op_t));
    if (!queue->ops) {
        free(queue);
        return NULL;
    }

    /* Create io_uring context */
    queue->uring = strix_uring_create(
        g_strix_config.ring_entries,
        g_strix_config.use_sqpoll
    );
    if (!queue->uring) {
        STRIX_DEBUG("Failed to create io_uring context");
        free(queue->ops);
        free(queue);
        return NULL;
    }

    queue->owner_thread = pthread_self();
    queue->initialized = true;

    STRIX_DEBUG("Created batch queue for thread %lu", (unsigned long)queue->owner_thread);
    return queue;
}

strix_batch_queue_t* strix_queue_get(void) {
    if (!s_initialized) {
        strix_queue_init();
    }

    if (tls_queue) {
        return tls_queue;
    }

    tls_queue = create_queue();
    if (tls_queue) {
        pthread_setspecific(queue_key, tls_queue);
    }
    return tls_queue;
}

size_t strix_queue_depth(strix_batch_queue_t* queue) {
    return queue ? queue->count : 0;
}

bool strix_queue_should_flush(strix_batch_queue_t* queue) {
    if (!queue) return false;

    /* Flush if batch is full */
    if (queue->count >= queue->capacity) {
        return true;
    }

    /* Flush if timeout exceeded */
    if (queue->timer_started && queue->count > 0) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);

        uint64_t elapsed_us =
            (now.tv_sec - queue->last_submit.tv_sec) * 1000000 +
            (now.tv_nsec - queue->last_submit.tv_nsec) / 1000;

        if (elapsed_us >= strix_get_batch_timeout()) {
            return true;
        }
    }

    return false;
}

/* ============================================================================
 * Operation Queueing
 * ============================================================================ */

static strix_batch_op_t* alloc_op(strix_batch_queue_t* queue) {
    if (!queue || queue->count >= queue->capacity) {
        return NULL;
    }

    strix_batch_op_t* op = &queue->ops[queue->count++];
    memset(op, 0, sizeof(*op));
    op->seq_id = ++queue->seq_counter;
    op->status = STRIX_STATUS_PENDING;

    /* Start timer on first op */
    if (!queue->timer_started) {
        clock_gettime(CLOCK_MONOTONIC, &queue->last_submit);
        queue->timer_started = true;
    }

    queue->stats.ops_queued++;
    return op;
}

static int maybe_flush_and_wait(strix_batch_queue_t* queue, bool sync) {
    if (!sync) return 0;

    /* Submit batch */
    if (queue->count > 0) {
        int ret = strix_queue_submit_and_wait(queue);
        if (ret < 0) return ret;
    }
    return 0;
}

int strix_queue_read(int fd, void* buf, size_t count, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_read(fd, buf, count);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_read(fd, buf, count);
    }

    /* Auto-flush if needed */
    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        /* Queue full, flush and retry */
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_read(fd, buf, count);
        }
    }

    op->type = STRIX_OP_READ;
    op->fd = fd;
    op->buf = buf;
    op->len = count;
    op->offset = -1;  /* Use current position */
    op->sync_required = sync;

    /* Prep io_uring SQE */
    int ret = strix_uring_prep_read(queue->uring, op);
    if (ret < 0) {
        queue->count--;  /* Rollback */
        queue->stats.sync_fallbacks++;
        return strix_sync_read(fd, buf, count);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return op->result;
    }

    return 0;  /* Async - will complete later */
}

int strix_queue_pread(int fd, void* buf, size_t count, off_t offset, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_pread(fd, buf, count, offset);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_pread(fd, buf, count, offset);
    }

    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_pread(fd, buf, count, offset);
        }
    }

    op->type = STRIX_OP_PREAD;
    op->fd = fd;
    op->buf = buf;
    op->len = count;
    op->offset = offset;
    op->sync_required = sync;

    int ret = strix_uring_prep_read(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        queue->stats.sync_fallbacks++;
        return strix_sync_pread(fd, buf, count, offset);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return op->result;
    }

    return 0;
}

int strix_queue_write(int fd, const void* buf, size_t count, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_write(fd, buf, count);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_write(fd, buf, count);
    }

    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_write(fd, buf, count);
        }
    }

    op->type = STRIX_OP_WRITE;
    op->fd = fd;
    op->buf = (void*)buf;  /* Safe: we only read from it */
    op->len = count;
    op->offset = -1;
    op->sync_required = sync;

    int ret = strix_uring_prep_write(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        queue->stats.sync_fallbacks++;
        return strix_sync_write(fd, buf, count);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        queue->stats.total_bytes_written += op->result > 0 ? op->result : 0;
        return op->result;
    }

    return 0;
}

int strix_queue_pwrite(int fd, const void* buf, size_t count, off_t offset, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_pwrite(fd, buf, count, offset);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_pwrite(fd, buf, count, offset);
    }

    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_pwrite(fd, buf, count, offset);
        }
    }

    op->type = STRIX_OP_PWRITE;
    op->fd = fd;
    op->buf = (void*)buf;
    op->len = count;
    op->offset = offset;
    op->sync_required = sync;

    int ret = strix_uring_prep_write(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        queue->stats.sync_fallbacks++;
        return strix_sync_pwrite(fd, buf, count, offset);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        queue->stats.total_bytes_written += op->result > 0 ? op->result : 0;
        return op->result;
    }

    return 0;
}

int strix_queue_open(const char* path, int flags, mode_t mode, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_open(path, flags, mode);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_open(path, flags, mode);
    }

    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_open(path, flags, mode);
        }
    }

    op->type = STRIX_OP_OPEN;
    op->path = path;
    op->flags = flags;
    op->mode = mode;
    op->sync_required = sync;

    int ret = strix_uring_prep_open(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        queue->stats.sync_fallbacks++;
        return strix_sync_open(path, flags, mode);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return (int)op->result;
    }

    return 0;
}

int strix_queue_close(int fd, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_close(fd);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_close(fd);
    }

    if (strix_queue_should_flush(queue)) {
        strix_queue_submit(queue);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_close(fd);
        }
    }

    op->type = STRIX_OP_CLOSE;
    op->fd = fd;
    op->sync_required = sync;

    int ret = strix_uring_prep_close(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        queue->stats.sync_fallbacks++;
        return strix_sync_close(fd);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return (int)op->result;
    }

    return 0;
}

int strix_queue_fsync(int fd, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_fsync(fd);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_fsync(fd);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_fsync(fd);
        }
    }

    op->type = STRIX_OP_FSYNC;
    op->fd = fd;
    op->sync_required = sync;

    int ret = strix_uring_prep_fsync(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        return strix_sync_fsync(fd);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return (int)op->result;
    }

    return 0;
}

int strix_queue_fdatasync(int fd, bool sync) {
    if (!strix_is_enabled()) {
        return strix_sync_fdatasync(fd);
    }

    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) {
        return strix_sync_fdatasync(fd);
    }

    strix_batch_op_t* op = alloc_op(queue);
    if (!op) {
        strix_queue_submit_and_wait(queue);
        op = alloc_op(queue);
        if (!op) {
            return strix_sync_fdatasync(fd);
        }
    }

    op->type = STRIX_OP_FDATASYNC;
    op->fd = fd;
    op->sync_required = sync;

    int ret = strix_uring_prep_fsync(queue->uring, op);
    if (ret < 0) {
        queue->count--;
        return strix_sync_fdatasync(fd);
    }

    if (sync) {
        ret = maybe_flush_and_wait(queue, true);
        if (ret < 0) return ret;
        return (int)op->result;
    }

    return 0;
}

/* Stat operations use synchronous fallback for now
 * (statx via io_uring requires struct conversion) */
int strix_queue_stat(const char* path, struct stat* buf, bool sync) {
    (void)sync;  /* Always sync for stat */
    return strix_sync_stat(path, buf);
}

int strix_queue_fstat(int fd, struct stat* buf, bool sync) {
    (void)sync;
    return strix_sync_fstat(fd, buf);
}

int strix_queue_lstat(const char* path, struct stat* buf, bool sync) {
    (void)sync;
    return strix_sync_lstat(path, buf);
}

/* ============================================================================
 * Batch Submission
 * ============================================================================ */

int strix_queue_submit(strix_batch_queue_t* queue) {
    if (!queue || queue->count == 0) return 0;

    int ret = strix_uring_submit(queue->uring);
    if (ret < 0) {
        STRIX_DEBUG("io_uring submit failed: %s", strerror(-ret));
        return ret;
    }

    queue->stats.batches_submitted++;
    queue->stats.ops_submitted += ret;
    queue->timer_started = false;

    STRIX_DEBUG("Submitted batch of %d operations", ret);
    return ret;
}

int strix_queue_submit_and_wait(strix_batch_queue_t* queue) {
    if (!queue || queue->count == 0) return 0;

    int submitted = strix_uring_submit_and_wait(queue->uring, queue->count);
    if (submitted < 0) {
        STRIX_DEBUG("io_uring submit_and_wait failed: %s", strerror(-submitted));
        return submitted;
    }

    /* Process completions */
    int completed = strix_uring_process_cqes(queue->uring, NULL);

    queue->stats.batches_submitted++;
    queue->stats.ops_submitted += submitted;
    queue->stats.ops_completed += completed;

    /* Reset queue */
    queue->count = 0;
    queue->timer_started = false;

    STRIX_DEBUG("Submitted and completed batch of %d operations", completed);
    return completed;
}

int strix_queue_process_completions(strix_batch_queue_t* queue) {
    if (!queue) return 0;
    return strix_uring_process_cqes(queue->uring, NULL);
}

/* ============================================================================
 * Synchronous Fallbacks
 * ============================================================================ */

ssize_t strix_sync_read(int fd, void* buf, size_t count) {
    if (real_read) return real_read(fd, buf, count);
    return syscall(SYS_read, fd, buf, count);
}

ssize_t strix_sync_pread(int fd, void* buf, size_t count, off_t offset) {
    if (real_pread) return real_pread(fd, buf, count, offset);
    return syscall(SYS_pread64, fd, buf, count, offset);
}

ssize_t strix_sync_write(int fd, const void* buf, size_t count) {
    if (real_write) return real_write(fd, buf, count);
    return syscall(SYS_write, fd, buf, count);
}

ssize_t strix_sync_pwrite(int fd, const void* buf, size_t count, off_t offset) {
    if (real_pwrite) return real_pwrite(fd, buf, count, offset);
    return syscall(SYS_pwrite64, fd, buf, count, offset);
}

int strix_sync_open(const char* path, int flags, mode_t mode) {
    if (real_open) return real_open(path, flags, mode);
    return syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}

int strix_sync_close(int fd) {
    if (real_close) return real_close(fd);
    return syscall(SYS_close, fd);
}

int strix_sync_stat(const char* path, struct stat* buf) {
    if (real_stat) return real_stat(path, buf);
    return syscall(SYS_stat, path, buf);
}

int strix_sync_fstat(int fd, struct stat* buf) {
    if (real_fstat) return real_fstat(fd, buf);
    return syscall(SYS_fstat, fd, buf);
}

int strix_sync_lstat(const char* path, struct stat* buf) {
    if (real_lstat) return real_lstat(path, buf);
    return syscall(SYS_lstat, path, buf);
}

int strix_sync_fsync(int fd) {
    if (real_fsync) return real_fsync(fd);
    return syscall(SYS_fsync, fd);
}

int strix_sync_fdatasync(int fd) {
    if (real_fdatasync) return real_fdatasync(fd);
    return syscall(SYS_fdatasync, fd);
}

/* ============================================================================
 * Statistics
 * ============================================================================ */

void strix_queue_get_stats(strix_batch_queue_t* queue, strix_queue_stats_t* stats) {
    if (!queue || !stats) return;
    memcpy(stats, &queue->stats, sizeof(strix_queue_stats_t));
}

void strix_queue_reset_stats(strix_batch_queue_t* queue) {
    if (!queue) return;
    memset(&queue->stats, 0, sizeof(strix_queue_stats_t));
}
