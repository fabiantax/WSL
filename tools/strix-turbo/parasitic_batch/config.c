/*
 * Strix-Turbo Parasitic Batch Configuration Implementation
 */

#define _GNU_SOURCE
#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>

/* Global configuration instance */
strix_config_t g_strix_config = {
    .batch_size = STRIX_DEFAULT_BATCH_SIZE,
    .batch_timeout_us = STRIX_DEFAULT_BATCH_TIMEOUT,
    .enabled = true,
    .debug = false,
    .use_sqpoll = false,
    .use_registered_files = false,
    .ring_entries = STRIX_DEFAULT_RING_ENTRIES,
    .blocklist = NULL,
    .blocklist_count = 0
};

/* Static blocklist storage */
static const char* s_blocklist[64];
static char s_blocklist_storage[4096];

/* Helper to parse size_t with bounds */
static size_t parse_size_bounded(const char* env, size_t def, size_t min, size_t max) {
    const char* val = getenv(env);
    if (!val) return def;

    char* end;
    unsigned long parsed = strtoul(val, &end, 10);
    if (*end != '\0' || parsed < min || parsed > max) {
        return def;
    }
    return (size_t)parsed;
}

/* Helper to parse uint64_t */
static uint64_t parse_uint64(const char* env, uint64_t def) {
    const char* val = getenv(env);
    if (!val) return def;

    char* end;
    unsigned long long parsed = strtoull(val, &end, 10);
    if (*end != '\0') {
        return def;
    }
    return (uint64_t)parsed;
}

/* Helper to parse bool */
static bool parse_bool(const char* env, bool def) {
    const char* val = getenv(env);
    if (!val) return def;

    if (strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0 ||
        strcasecmp(val, "yes") == 0 || strcasecmp(val, "on") == 0) {
        return true;
    }
    if (strcmp(val, "0") == 0 || strcasecmp(val, "false") == 0 ||
        strcasecmp(val, "no") == 0 || strcasecmp(val, "off") == 0) {
        return false;
    }
    return def;
}

/* Parse blocklist from environment */
static void parse_blocklist(void) {
    const char* val = getenv("STRIX_BATCH_BLOCKLIST");
    if (!val || !*val) return;

    /* Copy to storage */
    size_t len = strlen(val);
    if (len >= sizeof(s_blocklist_storage)) {
        len = sizeof(s_blocklist_storage) - 1;
    }
    memcpy(s_blocklist_storage, val, len);
    s_blocklist_storage[len] = '\0';

    /* Tokenize */
    char* saveptr;
    char* token = strtok_r(s_blocklist_storage, ":", &saveptr);
    size_t count = 0;

    while (token && count < 64) {
        s_blocklist[count++] = token;
        token = strtok_r(NULL, ":", &saveptr);
    }

    g_strix_config.blocklist = s_blocklist;
    g_strix_config.blocklist_count = count;
}

/* Get current process name */
static const char* get_process_name(void) {
    static char name[256] = {0};
    if (name[0]) return name;

    /* Try /proc/self/comm first */
    FILE* f = fopen("/proc/self/comm", "r");
    if (f) {
        if (fgets(name, sizeof(name), f)) {
            /* Remove trailing newline */
            size_t len = strlen(name);
            if (len > 0 && name[len-1] == '\n') {
                name[len-1] = '\0';
            }
        }
        fclose(f);
        if (name[0]) return name;
    }

    /* Fallback to program_invocation_short_name */
    extern char* program_invocation_short_name;
    if (program_invocation_short_name) {
        strncpy(name, program_invocation_short_name, sizeof(name) - 1);
        return name;
    }

    return "unknown";
}

void strix_config_init(void) {
    /* Parse environment variables */
    g_strix_config.batch_size = parse_size_bounded(
        "STRIX_BATCH_SIZE",
        STRIX_DEFAULT_BATCH_SIZE,
        STRIX_MIN_BATCH_SIZE,
        STRIX_MAX_BATCH_SIZE
    );

    g_strix_config.batch_timeout_us = parse_uint64(
        "STRIX_BATCH_TIMEOUT",
        STRIX_DEFAULT_BATCH_TIMEOUT
    );

    g_strix_config.ring_entries = (unsigned int)parse_size_bounded(
        "STRIX_RING_ENTRIES",
        STRIX_DEFAULT_RING_ENTRIES,
        STRIX_MIN_RING_ENTRIES,
        STRIX_MAX_RING_ENTRIES
    );

    g_strix_config.enabled = parse_bool("STRIX_BATCH_ENABLE", true);
    g_strix_config.debug = parse_bool("STRIX_BATCH_DEBUG", false);
    g_strix_config.use_sqpoll = parse_bool("STRIX_BATCH_SQPOLL", false);
    g_strix_config.use_registered_files = parse_bool("STRIX_BATCH_REGFILES", false);

    parse_blocklist();

    /* Check if blocked */
    if (strix_config_is_blocked()) {
        g_strix_config.enabled = false;
    }

    if (g_strix_config.debug) {
        fprintf(stderr, "[strix-batch] Configuration:\n");
        fprintf(stderr, "  enabled: %s\n", g_strix_config.enabled ? "yes" : "no");
        fprintf(stderr, "  batch_size: %zu\n", g_strix_config.batch_size);
        fprintf(stderr, "  batch_timeout: %lu us\n", g_strix_config.batch_timeout_us);
        fprintf(stderr, "  ring_entries: %u\n", g_strix_config.ring_entries);
        fprintf(stderr, "  use_sqpoll: %s\n", g_strix_config.use_sqpoll ? "yes" : "no");
        fprintf(stderr, "  process: %s\n", get_process_name());
    }
}

bool strix_config_is_blocked(void) {
    if (g_strix_config.blocklist_count == 0) {
        return false;
    }

    const char* name = get_process_name();
    for (size_t i = 0; i < g_strix_config.blocklist_count; i++) {
        if (strcmp(name, g_strix_config.blocklist[i]) == 0) {
            return true;
        }
    }
    return false;
}
