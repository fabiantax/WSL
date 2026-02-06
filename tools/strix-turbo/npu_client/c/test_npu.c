/*
 * Strix-Turbo NPU Client - C Library Test
 *
 * Tests the C library against a running NPU bridge.
 * Start the bridge first: python npu_bridge_windows.py
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "strix_npu.h"

#define TEST(name) printf("TEST: %s... ", name); fflush(stdout)
#define PASS() printf("PASSED\n")
#define FAIL(msg) printf("FAILED: %s\n", msg)

static int tests_passed = 0;
static int tests_failed = 0;

/* Test configuration */
static void test_config(void) {
    TEST("config initialization");

    strix_npu_config_t config;
    strix_npu_config_init(&config);

    if (strcmp(config.host, "localhost") != 0) {
        FAIL("wrong default host");
        tests_failed++;
        return;
    }

    if (config.port != 9999) {
        FAIL("wrong default port");
        tests_failed++;
        return;
    }

    if (config.timeout_ms != 30000) {
        FAIL("wrong default timeout");
        tests_failed++;
        return;
    }

    PASS();
    tests_passed++;
}

/* Test path hashing */
static void test_path_hash(void) {
    TEST("path hashing");

    uint32_t hash1 = strix_npu_path_hash("/path/to/file.txt");
    uint32_t hash2 = strix_npu_path_hash("/path/to/file.txt");
    uint32_t hash3 = strix_npu_path_hash("/different/path.txt");

    if (hash1 != hash2) {
        FAIL("same path gives different hashes");
        tests_failed++;
        return;
    }

    if (hash1 == hash3) {
        FAIL("different paths give same hash");
        tests_failed++;
        return;
    }

    PASS();
    tests_passed++;
}

/* Test client creation */
static void test_client_create(void) {
    TEST("client creation");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    if (!client) {
        FAIL("create returned NULL");
        tests_failed++;
        return;
    }

    if (strix_npu_is_connected(client)) {
        FAIL("client connected before connect()");
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

/* Test error strings */
static void test_error_strings(void) {
    TEST("error strings");

    const char* ok = strix_npu_strerror(STRIX_NPU_OK);
    if (!ok || strlen(ok) == 0) {
        FAIL("empty error string for OK");
        tests_failed++;
        return;
    }

    const char* connect_err = strix_npu_strerror(STRIX_NPU_ERROR_CONNECT);
    if (!connect_err || strlen(connect_err) == 0) {
        FAIL("empty error string for CONNECT");
        tests_failed++;
        return;
    }

    PASS();
    tests_passed++;
}

/* Test connection (requires bridge running) */
static void test_connection(void) {
    TEST("connection to bridge");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    if (!client) {
        FAIL("create failed");
        tests_failed++;
        return;
    }

    int ret = strix_npu_connect(client);
    if (ret != STRIX_NPU_OK) {
        printf("SKIPPED (bridge not running: %s)\n", strix_npu_strerror(ret));
        strix_npu_destroy(client);
        return;
    }

    if (!strix_npu_is_connected(client)) {
        FAIL("not connected after connect()");
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

/* Test ping (requires bridge running) */
static void test_ping(void) {
    TEST("ping bridge");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    int ret = strix_npu_connect(client);
    if (ret != STRIX_NPU_OK) {
        printf("SKIPPED (bridge not running)\n");
        strix_npu_destroy(client);
        return;
    }

    ret = strix_npu_ping(client);
    if (ret != STRIX_NPU_OK) {
        FAIL(strix_npu_strerror(ret));
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

/* Test status (requires bridge running) */
static void test_status(void) {
    TEST("get status");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    int ret = strix_npu_connect(client);
    if (ret != STRIX_NPU_OK) {
        printf("SKIPPED (bridge not running)\n");
        strix_npu_destroy(client);
        return;
    }

    strix_npu_status_t status;
    ret = strix_npu_status(client, &status);
    if (ret != STRIX_NPU_OK) {
        FAIL(strix_npu_strerror(ret));
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    if (strlen(status.provider) == 0) {
        FAIL("empty provider");
        strix_npu_free_status(&status);
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    printf("(provider=%s) ", status.provider);

    strix_npu_free_status(&status);
    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

/* Test record access (requires bridge running) */
static void test_record_access(void) {
    TEST("record file access");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    int ret = strix_npu_connect(client);
    if (ret != STRIX_NPU_OK) {
        printf("SKIPPED (bridge not running)\n");
        strix_npu_destroy(client);
        return;
    }

    ret = strix_npu_record_access(client, "/test/path/file.txt");
    if (ret != STRIX_NPU_OK) {
        FAIL(strix_npu_strerror(ret));
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

/* Test predict next (requires bridge running) */
static void test_predict_next(void) {
    TEST("predict next accesses");

    strix_npu_client_t* client = strix_npu_create("localhost", 9999);
    int ret = strix_npu_connect(client);
    if (ret != STRIX_NPU_OK) {
        printf("SKIPPED (bridge not running)\n");
        strix_npu_destroy(client);
        return;
    }

    /* Record some accesses first */
    strix_npu_record_access(client, "/path/a");
    strix_npu_record_access(client, "/path/b");
    strix_npu_record_access(client, "/path/c");

    strix_npu_predictions_t predictions;
    ret = strix_npu_predict_next(client, 5, &predictions);
    if (ret != STRIX_NPU_OK) {
        FAIL(strix_npu_strerror(ret));
        strix_npu_destroy(client);
        tests_failed++;
        return;
    }

    printf("(count=%zu) ", predictions.count);

    strix_npu_free_predictions(&predictions);
    strix_npu_destroy(client);
    PASS();
    tests_passed++;
}

int main(void) {
    printf("\n");
    printf("========================================\n");
    printf("  Strix-Turbo NPU Client C Tests\n");
    printf("========================================\n");
    printf("\n");

    /* Unit tests (no bridge required) */
    printf("--- Unit Tests ---\n");
    test_config();
    test_path_hash();
    test_client_create();
    test_error_strings();

    /* Integration tests (require bridge) */
    printf("\n--- Integration Tests ---\n");
    printf("(Start bridge with: python npu_bridge_windows.py)\n\n");
    test_connection();
    test_ping();
    test_status();
    test_record_access();
    test_predict_next();

    /* Summary */
    printf("\n========================================\n");
    printf("  Results: %d passed, %d failed\n", tests_passed, tests_failed);
    printf("========================================\n\n");

    return tests_failed > 0 ? 1 : 0;
}
