/*
 * Strix-Turbo io_uring Backend
 *
 * Handles io_uring initialization, submission, and completion processing.
 * This is the actual interface to the kernel's async I/O subsystem.
 */

#ifndef STRIX_URING_BACKEND_H
#define STRIX_URING_BACKEND_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declarations */
struct strix_uring_ctx;
typedef struct strix_uring_ctx strix_uring_ctx_t;

struct strix_batch_op;

/* ============================================================================
 * Context Management
 * ============================================================================ */

/* Create io_uring context */
strix_uring_ctx_t* strix_uring_create(unsigned int entries, bool use_sqpoll);

/* Destroy io_uring context */
void strix_uring_destroy(strix_uring_ctx_t* ctx);

/* Check if io_uring is available */
bool strix_uring_is_available(void);

/* Get maximum batch size supported */
unsigned int strix_uring_max_batch(strix_uring_ctx_t* ctx);

/* ============================================================================
 * Submission
 * ============================================================================ */

/* Prepare a read operation */
int strix_uring_prep_read(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Prepare a write operation */
int strix_uring_prep_write(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Prepare an open operation */
int strix_uring_prep_open(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Prepare a close operation */
int strix_uring_prep_close(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Prepare a stat operation (using statx) */
int strix_uring_prep_stat(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Prepare an fsync operation */
int strix_uring_prep_fsync(strix_uring_ctx_t* ctx, struct strix_batch_op* op);

/* Submit all prepared operations */
int strix_uring_submit(strix_uring_ctx_t* ctx);

/* Submit and wait for at least one completion */
int strix_uring_submit_and_wait(strix_uring_ctx_t* ctx, unsigned int wait_nr);

/* ============================================================================
 * Completion Processing
 * ============================================================================ */

/* Completion callback type */
typedef void (*strix_uring_cqe_cb)(void* user_data, int32_t result);

/* Process available completions (non-blocking) */
int strix_uring_process_cqes(strix_uring_ctx_t* ctx, strix_uring_cqe_cb callback);

/* Wait for completions with timeout */
int strix_uring_wait_cqes(strix_uring_ctx_t* ctx, unsigned int count,
                          uint64_t timeout_ns, strix_uring_cqe_cb callback);

/* Get number of pending submissions */
unsigned int strix_uring_sq_pending(strix_uring_ctx_t* ctx);

/* Get number of ready completions */
unsigned int strix_uring_cq_ready(strix_uring_ctx_t* ctx);

/* ============================================================================
 * File Registration (optional optimization)
 * ============================================================================ */

/* Register files for faster access */
int strix_uring_register_files(strix_uring_ctx_t* ctx, int* fds, unsigned int count);

/* Unregister files */
int strix_uring_unregister_files(strix_uring_ctx_t* ctx);

/* Update registered file */
int strix_uring_update_file(strix_uring_ctx_t* ctx, int slot, int new_fd);

/* ============================================================================
 * Buffer Registration (optional optimization)
 * ============================================================================ */

/* Register buffers for zero-copy I/O */
int strix_uring_register_buffers(strix_uring_ctx_t* ctx,
                                  struct iovec* iovs, unsigned int count);

/* Unregister buffers */
int strix_uring_unregister_buffers(strix_uring_ctx_t* ctx);

/* ============================================================================
 * Probing
 * ============================================================================ */

/* Check if specific operation is supported */
bool strix_uring_op_supported(int op);

/* Get supported operations mask */
uint64_t strix_uring_supported_ops(void);

/* ============================================================================
 * Statistics
 * ============================================================================ */

typedef struct strix_uring_stats {
    uint64_t sqe_submitted;
    uint64_t cqe_processed;
    uint64_t sq_full_events;
    uint64_t cq_overflow_events;
    uint64_t submit_calls;
    uint64_t wait_calls;
} strix_uring_stats_t;

void strix_uring_get_stats(strix_uring_ctx_t* ctx, strix_uring_stats_t* stats);

#ifdef __cplusplus
}
#endif

#endif /* STRIX_URING_BACKEND_H */
