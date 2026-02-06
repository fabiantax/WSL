/*
 * Strix-Turbo io_uring Backend Implementation
 *
 * This implementation uses liburing for io_uring access.
 * Build with: -luring
 */

#define _GNU_SOURCE
#include "uring_backend.h"
#include "batch_queue.h"
#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>
#include <liburing.h>

/* io_uring context structure */
struct strix_uring_ctx {
    struct io_uring ring;
    bool initialized;
    bool use_sqpoll;
    unsigned int entries;
    strix_uring_stats_t stats;

    /* Registered files */
    int* registered_fds;
    unsigned int registered_count;

    /* Probe results */
    struct io_uring_probe* probe;
};

/* Static probe for capability detection */
static struct io_uring_probe* s_probe = NULL;
static bool s_probe_initialized = false;

/* ============================================================================
 * Capability Detection
 * ============================================================================ */

static void ensure_probe_initialized(void) {
    if (s_probe_initialized) return;

    /* Create temporary ring for probing */
    struct io_uring temp_ring;
    if (io_uring_queue_init(8, &temp_ring, 0) == 0) {
        s_probe = io_uring_get_probe_ring(&temp_ring);
        io_uring_queue_exit(&temp_ring);
    }
    s_probe_initialized = true;
}

bool strix_uring_is_available(void) {
    /* Try to create a minimal ring */
    struct io_uring ring;
    int ret = io_uring_queue_init(8, &ring, 0);
    if (ret == 0) {
        io_uring_queue_exit(&ring);
        return true;
    }
    return false;
}

bool strix_uring_op_supported(int op) {
    ensure_probe_initialized();
    if (!s_probe) return false;
    return io_uring_opcode_supported(s_probe, op);
}

uint64_t strix_uring_supported_ops(void) {
    ensure_probe_initialized();
    if (!s_probe) return 0;

    uint64_t mask = 0;
    int ops[] = {
        IORING_OP_NOP, IORING_OP_READV, IORING_OP_WRITEV,
        IORING_OP_FSYNC, IORING_OP_READ_FIXED, IORING_OP_WRITE_FIXED,
        IORING_OP_POLL_ADD, IORING_OP_POLL_REMOVE,
        IORING_OP_SYNC_FILE_RANGE, IORING_OP_SENDMSG, IORING_OP_RECVMSG,
        IORING_OP_TIMEOUT, IORING_OP_TIMEOUT_REMOVE,
        IORING_OP_ACCEPT, IORING_OP_ASYNC_CANCEL,
        IORING_OP_LINK_TIMEOUT, IORING_OP_CONNECT,
        IORING_OP_FALLOCATE, IORING_OP_OPENAT, IORING_OP_CLOSE,
        IORING_OP_FILES_UPDATE, IORING_OP_STATX,
        IORING_OP_READ, IORING_OP_WRITE,
        IORING_OP_FADVISE, IORING_OP_MADVISE,
        IORING_OP_SEND, IORING_OP_RECV,
        IORING_OP_OPENAT2, IORING_OP_EPOLL_CTL,
        IORING_OP_SPLICE, IORING_OP_PROVIDE_BUFFERS, IORING_OP_REMOVE_BUFFERS
    };

    for (size_t i = 0; i < sizeof(ops)/sizeof(ops[0]); i++) {
        if (io_uring_opcode_supported(s_probe, ops[i])) {
            mask |= (1ULL << ops[i]);
        }
    }
    return mask;
}

/* ============================================================================
 * Context Management
 * ============================================================================ */

strix_uring_ctx_t* strix_uring_create(unsigned int entries, bool use_sqpoll) {
    strix_uring_ctx_t* ctx = calloc(1, sizeof(strix_uring_ctx_t));
    if (!ctx) return NULL;

    ctx->entries = entries;
    ctx->use_sqpoll = use_sqpoll;

    /* Setup flags */
    unsigned int flags = 0;
    if (use_sqpoll) {
        flags |= IORING_SETUP_SQPOLL;
        flags |= IORING_SETUP_SQ_AFF;  /* Pin to current CPU */
    }

    /* Initialize ring */
    int ret = io_uring_queue_init(entries, &ctx->ring, flags);
    if (ret < 0) {
        STRIX_DEBUG("io_uring_queue_init failed: %s", strerror(-ret));

        /* Retry without SQPOLL if that failed */
        if (use_sqpoll) {
            ret = io_uring_queue_init(entries, &ctx->ring, 0);
            if (ret < 0) {
                free(ctx);
                return NULL;
            }
            ctx->use_sqpoll = false;
            STRIX_DEBUG("Fallback to non-SQPOLL mode");
        } else {
            free(ctx);
            return NULL;
        }
    }

    /* Get probe for this ring */
    ctx->probe = io_uring_get_probe_ring(&ctx->ring);

    ctx->initialized = true;
    STRIX_DEBUG("Created io_uring context: entries=%u, sqpoll=%s",
                entries, ctx->use_sqpoll ? "yes" : "no");

    return ctx;
}

void strix_uring_destroy(strix_uring_ctx_t* ctx) {
    if (!ctx) return;

    if (ctx->initialized) {
        /* Unregister files if any */
        if (ctx->registered_fds) {
            io_uring_unregister_files(&ctx->ring);
            free(ctx->registered_fds);
        }

        if (ctx->probe) {
            io_uring_free_probe(ctx->probe);
        }

        io_uring_queue_exit(&ctx->ring);
    }

    free(ctx);
}

unsigned int strix_uring_max_batch(strix_uring_ctx_t* ctx) {
    return ctx ? ctx->entries : 0;
}

/* ============================================================================
 * Submission Helpers
 * ============================================================================ */

static struct io_uring_sqe* get_sqe(strix_uring_ctx_t* ctx) {
    struct io_uring_sqe* sqe = io_uring_get_sqe(&ctx->ring);
    if (!sqe) {
        ctx->stats.sq_full_events++;
        /* Try submitting to make room */
        io_uring_submit(&ctx->ring);
        sqe = io_uring_get_sqe(&ctx->ring);
    }
    return sqe;
}

int strix_uring_prep_read(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    io_uring_prep_read(sqe, op->fd, op->buf, op->len, op->offset);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

int strix_uring_prep_write(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    io_uring_prep_write(sqe, op->fd, op->buf, op->len, op->offset);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

int strix_uring_prep_open(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    /* Use openat with AT_FDCWD for current directory */
    io_uring_prep_openat(sqe, AT_FDCWD, op->path, op->flags, op->mode);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

int strix_uring_prep_close(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    io_uring_prep_close(sqe, op->fd);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

int strix_uring_prep_stat(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    /* Use statx for async stat */
    /* Note: This requires converting struct stat to struct statx */
    io_uring_prep_statx(sqe, AT_FDCWD, op->path, 0,
                        STATX_BASIC_STATS, (struct statx*)op->buf);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

int strix_uring_prep_fsync(strix_uring_ctx_t* ctx, struct strix_batch_op* op) {
    if (!ctx || !ctx->initialized || !op) return -EINVAL;

    struct io_uring_sqe* sqe = get_sqe(ctx);
    if (!sqe) return -EAGAIN;

    unsigned int flags = (op->type == STRIX_OP_FDATASYNC) ? IORING_FSYNC_DATASYNC : 0;
    io_uring_prep_fsync(sqe, op->fd, flags);
    io_uring_sqe_set_data(sqe, op);

    return 0;
}

/* ============================================================================
 * Submission
 * ============================================================================ */

int strix_uring_submit(strix_uring_ctx_t* ctx) {
    if (!ctx || !ctx->initialized) return -EINVAL;

    int ret = io_uring_submit(&ctx->ring);
    if (ret >= 0) {
        ctx->stats.sqe_submitted += ret;
        ctx->stats.submit_calls++;
    }
    return ret;
}

int strix_uring_submit_and_wait(strix_uring_ctx_t* ctx, unsigned int wait_nr) {
    if (!ctx || !ctx->initialized) return -EINVAL;

    int ret = io_uring_submit_and_wait(&ctx->ring, wait_nr);
    if (ret >= 0) {
        ctx->stats.sqe_submitted += ret;
        ctx->stats.submit_calls++;
        ctx->stats.wait_calls++;
    }
    return ret;
}

unsigned int strix_uring_sq_pending(strix_uring_ctx_t* ctx) {
    if (!ctx || !ctx->initialized) return 0;
    return io_uring_sq_ready(&ctx->ring);
}

unsigned int strix_uring_cq_ready(strix_uring_ctx_t* ctx) {
    if (!ctx || !ctx->initialized) return 0;
    return io_uring_cq_ready(&ctx->ring);
}

/* ============================================================================
 * Completion Processing
 * ============================================================================ */

int strix_uring_process_cqes(strix_uring_ctx_t* ctx, strix_uring_cqe_cb callback) {
    if (!ctx || !ctx->initialized) return -EINVAL;

    struct io_uring_cqe* cqe;
    unsigned int head;
    int count = 0;

    io_uring_for_each_cqe(&ctx->ring, head, cqe) {
        /* Get user data (our batch_op pointer) */
        struct strix_batch_op* op = io_uring_cqe_get_data(cqe);

        if (op) {
            /* Update operation result */
            op->result = cqe->res;
            if (cqe->res < 0) {
                op->error = -cqe->res;
                op->status = STRIX_STATUS_ERROR;
            } else {
                op->error = 0;
                op->status = STRIX_STATUS_COMPLETED;
            }

            /* Call user callback if provided */
            if (callback) {
                callback(op, cqe->res);
            }

            /* Call operation-specific callback */
            if (op->callback) {
                op->callback(op->user_data, op->result);
            }
        }

        count++;
        ctx->stats.cqe_processed++;
    }

    /* Advance CQ head */
    io_uring_cq_advance(&ctx->ring, count);

    return count;
}

int strix_uring_wait_cqes(strix_uring_ctx_t* ctx, unsigned int count,
                          uint64_t timeout_ns, strix_uring_cqe_cb callback) {
    if (!ctx || !ctx->initialized) return -EINVAL;

    struct __kernel_timespec ts = {
        .tv_sec = timeout_ns / 1000000000ULL,
        .tv_nsec = timeout_ns % 1000000000ULL
    };

    struct io_uring_cqe* cqe;
    int ret = io_uring_wait_cqes(&ctx->ring, &cqe, count, &ts, NULL);

    ctx->stats.wait_calls++;

    if (ret < 0) {
        return ret;
    }

    /* Process all available completions */
    return strix_uring_process_cqes(ctx, callback);
}

/* ============================================================================
 * File Registration
 * ============================================================================ */

int strix_uring_register_files(strix_uring_ctx_t* ctx, int* fds, unsigned int count) {
    if (!ctx || !ctx->initialized || !fds || count == 0) return -EINVAL;

    /* Unregister existing files first */
    if (ctx->registered_fds) {
        io_uring_unregister_files(&ctx->ring);
        free(ctx->registered_fds);
        ctx->registered_fds = NULL;
        ctx->registered_count = 0;
    }

    int ret = io_uring_register_files(&ctx->ring, fds, count);
    if (ret < 0) {
        return ret;
    }

    /* Store copy of registered fds */
    ctx->registered_fds = malloc(count * sizeof(int));
    if (ctx->registered_fds) {
        memcpy(ctx->registered_fds, fds, count * sizeof(int));
        ctx->registered_count = count;
    }

    return 0;
}

int strix_uring_unregister_files(strix_uring_ctx_t* ctx) {
    if (!ctx || !ctx->initialized) return -EINVAL;
    if (!ctx->registered_fds) return 0;

    int ret = io_uring_unregister_files(&ctx->ring);
    free(ctx->registered_fds);
    ctx->registered_fds = NULL;
    ctx->registered_count = 0;

    return ret;
}

int strix_uring_update_file(strix_uring_ctx_t* ctx, int slot, int new_fd) {
    if (!ctx || !ctx->initialized) return -EINVAL;
    if (!ctx->registered_fds || slot < 0 || (unsigned)slot >= ctx->registered_count) {
        return -EINVAL;
    }

    int ret = io_uring_register_files_update(&ctx->ring, slot, &new_fd, 1);
    if (ret >= 0) {
        ctx->registered_fds[slot] = new_fd;
    }
    return ret;
}

/* ============================================================================
 * Buffer Registration
 * ============================================================================ */

int strix_uring_register_buffers(strix_uring_ctx_t* ctx,
                                  struct iovec* iovs, unsigned int count) {
    if (!ctx || !ctx->initialized || !iovs || count == 0) return -EINVAL;
    return io_uring_register_buffers(&ctx->ring, iovs, count);
}

int strix_uring_unregister_buffers(strix_uring_ctx_t* ctx) {
    if (!ctx || !ctx->initialized) return -EINVAL;
    return io_uring_unregister_buffers(&ctx->ring);
}

/* ============================================================================
 * Statistics
 * ============================================================================ */

void strix_uring_get_stats(strix_uring_ctx_t* ctx, strix_uring_stats_t* stats) {
    if (!ctx || !stats) return;
    memcpy(stats, &ctx->stats, sizeof(strix_uring_stats_t));
}
