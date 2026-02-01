/*
 * Strix-Turbo Parasitic Batch Library
 *
 * LD_PRELOAD library that intercepts libc I/O calls and batches them
 * transparently via io_uring for massive performance gains on WSL2.
 *
 * Usage:
 *   LD_PRELOAD=/path/to/libparasitic_batch.so your_program
 *
 * Environment Variables:
 *   STRIX_BATCH_ENABLE=1     Enable batching (default)
 *   STRIX_BATCH_SIZE=64      Operations per batch
 *   STRIX_BATCH_TIMEOUT=1000 Flush timeout in microseconds
 *   STRIX_BATCH_DEBUG=1      Enable debug logging
 *   STRIX_BATCH_BLOCKLIST=prog1:prog2  Programs to skip
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "config.h"
#include "batch_queue.h"

/* ============================================================================
 * Recursion Guard
 *
 * Prevents infinite recursion when our intercepted functions call other
 * intercepted functions (e.g., debug logging calls write()).
 * ============================================================================ */

static __thread int recursion_depth = 0;

#define RECURSION_GUARD_ENTER() \
    do { \
        if (++recursion_depth > 1) { \
            recursion_depth--; \
            goto fallback; \
        } \
    } while (0)

#define RECURSION_GUARD_EXIT() \
    do { \
        recursion_depth--; \
    } while (0)

/* ============================================================================
 * Original Function Pointers
 * ============================================================================ */

static ssize_t (*orig_read)(int fd, void *buf, size_t count) = NULL;
static ssize_t (*orig_write)(int fd, const void *buf, size_t count) = NULL;
static ssize_t (*orig_pread)(int fd, void *buf, size_t count, off_t offset) = NULL;
static ssize_t (*orig_pwrite)(int fd, const void *buf, size_t count, off_t offset) = NULL;
static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_close)(int fd) = NULL;
static int (*orig_fsync)(int fd) = NULL;
static int (*orig_fdatasync)(int fd) = NULL;

/* Flag to track initialization */
static int initialized = 0;

/* ============================================================================
 * Initialization
 * ============================================================================ */

static void ensure_initialized(void) {
    if (initialized) return;

    /* Load original functions */
    orig_read = dlsym(RTLD_NEXT, "read");
    orig_write = dlsym(RTLD_NEXT, "write");
    orig_pread = dlsym(RTLD_NEXT, "pread");
    orig_pwrite = dlsym(RTLD_NEXT, "pwrite");
    orig_open = dlsym(RTLD_NEXT, "open");
    orig_openat = dlsym(RTLD_NEXT, "openat");
    orig_close = dlsym(RTLD_NEXT, "close");
    orig_fsync = dlsym(RTLD_NEXT, "fsync");
    orig_fdatasync = dlsym(RTLD_NEXT, "fdatasync");

    /* Initialize batch queue subsystem */
    strix_queue_init();

    initialized = 1;

    if (strix_is_enabled()) {
        STRIX_DEBUG("Parasitic batching ACTIVE");
    } else {
        STRIX_DEBUG("Parasitic batching DISABLED");
    }
}

/* Constructor - called when library is loaded */
__attribute__((constructor))
static void parasitic_init(void) {
    ensure_initialized();
}

/* Destructor - called when library is unloaded */
__attribute__((destructor))
static void parasitic_cleanup(void) {
    /* Flush any pending operations */
    strix_batch_queue_t* queue = strix_queue_get();
    if (queue && strix_queue_depth(queue) > 0) {
        strix_queue_submit_and_wait(queue);
    }

    strix_queue_cleanup();

    if (strix_is_debug()) {
        strix_queue_stats_t stats;
        strix_queue_get_stats(queue, &stats);
        fprintf(stderr, "[strix-batch] Final stats:\n");
        fprintf(stderr, "  ops_queued: %lu\n", stats.ops_queued);
        fprintf(stderr, "  ops_submitted: %lu\n", stats.ops_submitted);
        fprintf(stderr, "  batches_submitted: %lu\n", stats.batches_submitted);
        fprintf(stderr, "  sync_fallbacks: %lu\n", stats.sync_fallbacks);
        fprintf(stderr, "  bytes_read: %lu\n", stats.total_bytes_read);
        fprintf(stderr, "  bytes_written: %lu\n", stats.total_bytes_written);
    }
}

/* ============================================================================
 * Interposed Functions
 * ============================================================================ */

/*
 * read() - Intercept and batch read operations
 */
ssize_t read(int fd, void *buf, size_t count) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    /* Skip special file descriptors */
    if (fd < 0 || fd <= STDERR_FILENO) {
        goto fallback;
    }

    /* Use batched read */
    ssize_t result = strix_queue_read(fd, buf, count, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_read ? orig_read(fd, buf, count) : -1;
}

/*
 * write() - Intercept and batch write operations
 */
ssize_t write(int fd, const void *buf, size_t count) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    /* Skip special file descriptors (stdin/stdout/stderr) */
    if (fd < 0 || fd <= STDERR_FILENO) {
        goto fallback;
    }

    /* Use batched write */
    ssize_t result = strix_queue_write(fd, buf, count, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_write ? orig_write(fd, buf, count) : -1;
}

/*
 * pread() - Intercept positioned read
 */
ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    if (fd < 0) {
        goto fallback;
    }

    ssize_t result = strix_queue_pread(fd, buf, count, offset, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_pread ? orig_pread(fd, buf, count, offset) : -1;
}

/*
 * pwrite() - Intercept positioned write
 */
ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    if (fd < 0) {
        goto fallback;
    }

    ssize_t result = strix_queue_pwrite(fd, buf, count, offset, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_pwrite ? orig_pwrite(fd, buf, count, offset) : -1;
}

/*
 * open() - Intercept file open
 */
int open(const char *pathname, int flags, ...) {
    ensure_initialized();

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);  /* mode_t is promoted to int */
        va_end(ap);
    }

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    /* Skip /proc, /sys, /dev - these may not work well with io_uring */
    if (pathname &&
        (strncmp(pathname, "/proc", 5) == 0 ||
         strncmp(pathname, "/sys", 4) == 0 ||
         strncmp(pathname, "/dev", 4) == 0)) {
        goto fallback;
    }

    int result = strix_queue_open(pathname, flags, mode, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_open ? orig_open(pathname, flags, mode) : -1;
}

/*
 * openat() - Intercept directory-relative open
 */
int openat(int dirfd, const char *pathname, int flags, ...) {
    ensure_initialized();

    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    /* For simplicity, fall back to original for non-AT_FDCWD cases */
    if (dirfd != AT_FDCWD) {
        return orig_openat ? orig_openat(dirfd, pathname, flags, mode) : -1;
    }

    /* Delegate to our open() implementation */
    return open(pathname, flags, mode);
}

/*
 * close() - Intercept file close
 */
int close(int fd) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    /* Skip special fds */
    if (fd < 0 || fd <= STDERR_FILENO) {
        goto fallback;
    }

    int result = strix_queue_close(fd, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_close ? orig_close(fd) : -1;
}

/*
 * fsync() - Intercept fsync
 */
int fsync(int fd) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    if (fd < 0) {
        goto fallback;
    }

    int result = strix_queue_fsync(fd, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_fsync ? orig_fsync(fd) : -1;
}

/*
 * fdatasync() - Intercept fdatasync
 */
int fdatasync(int fd) {
    ensure_initialized();

    RECURSION_GUARD_ENTER();

    if (!strix_is_enabled()) {
        goto fallback;
    }

    if (fd < 0) {
        goto fallback;
    }

    int result = strix_queue_fdatasync(fd, true);
    RECURSION_GUARD_EXIT();
    return result;

fallback:
    RECURSION_GUARD_EXIT();
    return orig_fdatasync ? orig_fdatasync(fd) : -1;
}

/* ============================================================================
 * 64-bit variants (for compatibility)
 * ============================================================================ */

ssize_t read64(int fd, void *buf, size_t count) __attribute__((alias("read")));
ssize_t write64(int fd, const void *buf, size_t count) __attribute__((alias("write")));
ssize_t pread64(int fd, void *buf, size_t count, off_t offset) __attribute__((alias("pread")));
ssize_t pwrite64(int fd, const void *buf, size_t count, off_t offset) __attribute__((alias("pwrite")));
int open64(const char *pathname, int flags, ...) __attribute__((alias("open")));

/* ============================================================================
 * Batch Control API (for programs that want explicit control)
 * ============================================================================ */

/*
 * Force flush all pending batched operations
 */
int strix_flush(void) {
    strix_batch_queue_t* queue = strix_queue_get();
    if (!queue) return 0;

    return strix_queue_submit_and_wait(queue);
}

/*
 * Get current batch depth
 */
size_t strix_pending_count(void) {
    strix_batch_queue_t* queue = strix_queue_get();
    return queue ? strix_queue_depth(queue) : 0;
}

/*
 * Temporarily disable batching for this thread
 */
void strix_disable(void) {
    g_strix_config.enabled = false;
}

/*
 * Re-enable batching for this thread
 */
void strix_enable(void) {
    g_strix_config.enabled = true;
}
