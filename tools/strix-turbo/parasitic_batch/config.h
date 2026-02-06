/*
 * Strix-Turbo Parasitic Batch Configuration
 *
 * Environment variables to control batching behavior:
 *   STRIX_BATCH_SIZE      - Max operations per batch (default: 64)
 *   STRIX_BATCH_TIMEOUT   - Timeout in microseconds before forced flush (default: 1000)
 *   STRIX_BATCH_ENABLE    - Enable/disable batching (default: 1)
 *   STRIX_BATCH_DEBUG     - Enable debug logging (default: 0)
 *   STRIX_BATCH_BLOCKLIST - Colon-separated list of programs to skip
 */

#ifndef STRIX_CONFIG_H
#define STRIX_CONFIG_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Configuration structure */
typedef struct strix_config {
    /* Batching parameters */
    size_t batch_size;           /* Max operations per batch */
    uint64_t batch_timeout_us;   /* Timeout in microseconds */

    /* Feature flags */
    bool enabled;                /* Global enable/disable */
    bool debug;                  /* Debug logging */
    bool use_sqpoll;             /* Use io_uring SQPOLL mode */
    bool use_registered_files;   /* Use io_uring file registration */

    /* Ring parameters */
    unsigned int ring_entries;   /* io_uring queue entries */

    /* Blocklist */
    const char** blocklist;      /* Programs to skip */
    size_t blocklist_count;
} strix_config_t;

/* Global configuration instance */
extern strix_config_t g_strix_config;

/* Initialize configuration from environment */
void strix_config_init(void);

/* Check if current process should be excluded */
bool strix_config_is_blocked(void);

/* Configuration getters (thread-safe after init) */
static inline size_t strix_get_batch_size(void) {
    return g_strix_config.batch_size;
}

static inline uint64_t strix_get_batch_timeout(void) {
    return g_strix_config.batch_timeout_us;
}

static inline bool strix_is_enabled(void) {
    return g_strix_config.enabled;
}

static inline bool strix_is_debug(void) {
    return g_strix_config.debug;
}

/* Default values */
#define STRIX_DEFAULT_BATCH_SIZE      64
#define STRIX_DEFAULT_BATCH_TIMEOUT   1000   /* 1ms */
#define STRIX_DEFAULT_RING_ENTRIES    256
#define STRIX_MIN_BATCH_SIZE          4
#define STRIX_MAX_BATCH_SIZE          4096
#define STRIX_MIN_RING_ENTRIES        32
#define STRIX_MAX_RING_ENTRIES        32768

/* Debug logging macro */
#define STRIX_DEBUG(fmt, ...) \
    do { \
        if (strix_is_debug()) { \
            fprintf(stderr, "[strix-batch] " fmt "\n", ##__VA_ARGS__); \
        } \
    } while (0)

#ifdef __cplusplus
}
#endif

#endif /* STRIX_CONFIG_H */
