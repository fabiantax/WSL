/*
 * Strix-Turbo Thread-Local Batch Queue
 *
 * Each thread maintains its own batch queue to avoid synchronization overhead.
 * Operations are queued locally and submitted together via io_uring.
 */

#ifndef STRIX_BATCH_QUEUE_H
#define STRIX_BATCH_QUEUE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Operation types */
typedef enum {
    STRIX_OP_NONE = 0,
    STRIX_OP_READ,
    STRIX_OP_WRITE,
    STRIX_OP_OPEN,
    STRIX_OP_CLOSE,
    STRIX_OP_STAT,
    STRIX_OP_FSTAT,
    STRIX_OP_LSTAT,
    STRIX_OP_FSYNC,
    STRIX_OP_FDATASYNC,
    STRIX_OP_READV,
    STRIX_OP_WRITEV,
    STRIX_OP_PREAD,
    STRIX_OP_PWRITE,
} strix_op_type_t;

/* Operation status */
typedef enum {
    STRIX_STATUS_PENDING = 0,
    STRIX_STATUS_SUBMITTED,
    STRIX_STATUS_COMPLETED,
    STRIX_STATUS_ERROR
} strix_op_status_t;

/* Forward declarations */
struct strix_batch_queue;
typedef struct strix_batch_queue strix_batch_queue_t;

/* Completion callback */
typedef void (*strix_completion_cb)(void* user_data, ssize_t result);

/* Operation descriptor */
typedef struct strix_batch_op {
    strix_op_type_t type;
    strix_op_status_t status;

    /* File descriptor or path */
    int fd;
    const char* path;

    /* Buffer info */
    void* buf;
    size_t len;
    off_t offset;

    /* Flags */
    int flags;
    mode_t mode;

    /* Result */
    ssize_t result;
    int error;

    /* Callback */
    strix_completion_cb callback;
    void* user_data;

    /* Sequencing */
    uint64_t seq_id;
    bool sync_required;  /* Must complete before returning */
} strix_batch_op_t;

/* ============================================================================
 * Queue Management
 * ============================================================================ */

/* Get thread-local batch queue (creates if needed) */
strix_batch_queue_t* strix_queue_get(void);

/* Initialize batch queue subsystem */
int strix_queue_init(void);

/* Cleanup batch queue subsystem */
void strix_queue_cleanup(void);

/* Get current queue depth */
size_t strix_queue_depth(strix_batch_queue_t* queue);

/* Check if queue should be flushed */
bool strix_queue_should_flush(strix_batch_queue_t* queue);

/* ============================================================================
 * Queueing Operations
 * ============================================================================ */

/* Queue a read operation */
int strix_queue_read(int fd, void* buf, size_t count, bool sync);

/* Queue a pread operation */
int strix_queue_pread(int fd, void* buf, size_t count, off_t offset, bool sync);

/* Queue a write operation */
int strix_queue_write(int fd, const void* buf, size_t count, bool sync);

/* Queue a pwrite operation */
int strix_queue_pwrite(int fd, const void* buf, size_t count, off_t offset, bool sync);

/* Queue an open operation */
int strix_queue_open(const char* path, int flags, mode_t mode, bool sync);

/* Queue a close operation */
int strix_queue_close(int fd, bool sync);

/* Queue a stat operation */
int strix_queue_stat(const char* path, struct stat* buf, bool sync);

/* Queue an fstat operation */
int strix_queue_fstat(int fd, struct stat* buf, bool sync);

/* Queue an lstat operation */
int strix_queue_lstat(const char* path, struct stat* buf, bool sync);

/* Queue a fsync operation */
int strix_queue_fsync(int fd, bool sync);

/* Queue a fdatasync operation */
int strix_queue_fdatasync(int fd, bool sync);

/* ============================================================================
 * Batch Submission
 * ============================================================================ */

/* Submit all pending operations */
int strix_queue_submit(strix_batch_queue_t* queue);

/* Submit and wait for all operations to complete */
int strix_queue_submit_and_wait(strix_batch_queue_t* queue);

/* Wait for a specific operation to complete */
int strix_queue_wait_op(strix_batch_queue_t* queue, uint64_t seq_id);

/* Process completions (non-blocking) */
int strix_queue_process_completions(strix_batch_queue_t* queue);

/* ============================================================================
 * Synchronous Fallback
 * ============================================================================ */

/* Execute operation synchronously (bypassing queue) */
ssize_t strix_sync_read(int fd, void* buf, size_t count);
ssize_t strix_sync_pread(int fd, void* buf, size_t count, off_t offset);
ssize_t strix_sync_write(int fd, const void* buf, size_t count);
ssize_t strix_sync_pwrite(int fd, const void* buf, size_t count, off_t offset);
int strix_sync_open(const char* path, int flags, mode_t mode);
int strix_sync_close(int fd);
int strix_sync_stat(const char* path, struct stat* buf);
int strix_sync_fstat(int fd, struct stat* buf);
int strix_sync_lstat(const char* path, struct stat* buf);
int strix_sync_fsync(int fd);
int strix_sync_fdatasync(int fd);

/* ============================================================================
 * Statistics
 * ============================================================================ */

typedef struct strix_queue_stats {
    uint64_t ops_queued;
    uint64_t ops_submitted;
    uint64_t ops_completed;
    uint64_t batches_submitted;
    uint64_t sync_fallbacks;
    uint64_t errors;
    uint64_t total_bytes_read;
    uint64_t total_bytes_written;
} strix_queue_stats_t;

/* Get queue statistics */
void strix_queue_get_stats(strix_batch_queue_t* queue, strix_queue_stats_t* stats);

/* Reset statistics */
void strix_queue_reset_stats(strix_batch_queue_t* queue);

#ifdef __cplusplus
}
#endif

#endif /* STRIX_BATCH_QUEUE_H */
