/*
 * Strix-Turbo Parasitic Batch Library - Test Suite
 *
 * Tests the LD_PRELOAD library functionality with and without batching.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <errno.h>
#include <assert.h>

#define TEST_FILE "/tmp/strix_test_file"
#define TEST_SIZE (64 * 1024)  /* 64KB */

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) \
    do { \
        printf("TEST: %s... ", name); \
        fflush(stdout); \
    } while (0)

#define PASS() \
    do { \
        printf("PASSED\n"); \
        tests_passed++; \
    } while (0)

#define FAIL(msg) \
    do { \
        printf("FAILED: %s\n", msg); \
        tests_failed++; \
    } while (0)

/* ============================================================================
 * Test Functions
 * ============================================================================ */

static void test_basic_write_read(void) {
    TEST("basic write/read");

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    const char* data = "Hello, Strix-Turbo!";
    ssize_t written = write(fd, data, strlen(data));
    if (written != (ssize_t)strlen(data)) {
        FAIL("write failed");
        close(fd);
        return;
    }

    /* Seek back to beginning */
    lseek(fd, 0, SEEK_SET);

    char buf[64] = {0};
    ssize_t bytes_read = read(fd, buf, sizeof(buf) - 1);
    if (bytes_read != (ssize_t)strlen(data)) {
        FAIL("read wrong size");
        close(fd);
        return;
    }

    if (strcmp(buf, data) != 0) {
        FAIL("data mismatch");
        close(fd);
        return;
    }

    close(fd);
    PASS();
}

static void test_pread_pwrite(void) {
    TEST("pread/pwrite");

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    /* Write at different offsets */
    const char* data1 = "AAAA";
    const char* data2 = "BBBB";
    const char* data3 = "CCCC";

    pwrite(fd, data1, 4, 0);
    pwrite(fd, data2, 4, 100);
    pwrite(fd, data3, 4, 200);

    /* Read back */
    char buf[8];

    pread(fd, buf, 4, 0);
    buf[4] = '\0';
    if (strcmp(buf, "AAAA") != 0) {
        FAIL("pread offset 0 failed");
        close(fd);
        return;
    }

    pread(fd, buf, 4, 100);
    buf[4] = '\0';
    if (strcmp(buf, "BBBB") != 0) {
        FAIL("pread offset 100 failed");
        close(fd);
        return;
    }

    pread(fd, buf, 4, 200);
    buf[4] = '\0';
    if (strcmp(buf, "CCCC") != 0) {
        FAIL("pread offset 200 failed");
        close(fd);
        return;
    }

    close(fd);
    PASS();
}

static void test_multiple_files(void) {
    TEST("multiple files");

    char files[10][64];
    int fds[10];

    /* Create multiple files */
    for (int i = 0; i < 10; i++) {
        snprintf(files[i], sizeof(files[i]), "/tmp/strix_test_%d", i);
        fds[i] = open(files[i], O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fds[i] < 0) {
            FAIL("open failed");
            return;
        }
    }

    /* Write to all files */
    for (int i = 0; i < 10; i++) {
        char data[32];
        snprintf(data, sizeof(data), "File %d content", i);
        write(fds[i], data, strlen(data));
    }

    /* Read back and verify */
    for (int i = 0; i < 10; i++) {
        lseek(fds[i], 0, SEEK_SET);
        char buf[64] = {0};
        read(fds[i], buf, sizeof(buf) - 1);

        char expected[32];
        snprintf(expected, sizeof(expected), "File %d content", i);
        if (strcmp(buf, expected) != 0) {
            FAIL("content mismatch");
            break;
        }
    }

    /* Close all files */
    for (int i = 0; i < 10; i++) {
        close(fds[i]);
        unlink(files[i]);
    }

    PASS();
}

static void test_large_io(void) {
    TEST("large I/O");

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    /* Allocate large buffer */
    char* buf = malloc(TEST_SIZE);
    if (!buf) {
        FAIL("malloc failed");
        close(fd);
        return;
    }

    /* Fill with pattern */
    for (size_t i = 0; i < TEST_SIZE; i++) {
        buf[i] = (char)(i & 0xFF);
    }

    /* Write in chunks */
    size_t written = 0;
    while (written < TEST_SIZE) {
        ssize_t n = write(fd, buf + written, TEST_SIZE - written);
        if (n <= 0) {
            FAIL("write failed");
            free(buf);
            close(fd);
            return;
        }
        written += n;
    }

    /* Seek back */
    lseek(fd, 0, SEEK_SET);

    /* Read back */
    char* rbuf = malloc(TEST_SIZE);
    if (!rbuf) {
        FAIL("malloc failed");
        free(buf);
        close(fd);
        return;
    }

    size_t bytes_read = 0;
    while (bytes_read < TEST_SIZE) {
        ssize_t n = read(fd, rbuf + bytes_read, TEST_SIZE - bytes_read);
        if (n <= 0) {
            FAIL("read failed");
            free(buf);
            free(rbuf);
            close(fd);
            return;
        }
        bytes_read += n;
    }

    /* Verify */
    if (memcmp(buf, rbuf, TEST_SIZE) != 0) {
        FAIL("data verification failed");
        free(buf);
        free(rbuf);
        close(fd);
        return;
    }

    free(buf);
    free(rbuf);
    close(fd);
    PASS();
}

static void test_fsync(void) {
    TEST("fsync/fdatasync");

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    write(fd, "test data", 9);

    if (fsync(fd) < 0) {
        FAIL("fsync failed");
        close(fd);
        return;
    }

    write(fd, "more data", 9);

    if (fdatasync(fd) < 0) {
        FAIL("fdatasync failed");
        close(fd);
        return;
    }

    close(fd);
    PASS();
}

static void test_error_handling(void) {
    TEST("error handling");

    /* Try to read from invalid fd */
    char buf[64];
    ssize_t result = read(-1, buf, sizeof(buf));
    if (result >= 0) {
        FAIL("expected error for invalid fd");
        return;
    }

    /* Try to open non-existent file */
    int fd = open("/nonexistent/path/file", O_RDONLY);
    if (fd >= 0) {
        FAIL("expected error for non-existent file");
        close(fd);
        return;
    }

    PASS();
}

static void test_rapid_open_close(void) {
    TEST("rapid open/close");

    for (int i = 0; i < 100; i++) {
        int fd = open(TEST_FILE, O_RDWR | O_CREAT, 0644);
        if (fd < 0) {
            FAIL("open failed");
            return;
        }
        write(fd, "x", 1);
        close(fd);
    }

    PASS();
}

static void test_stdio_passthrough(void) {
    TEST("stdio passthrough");

    /* These should work without batching (passed through) */
    const char* msg = "stdio test\n";
    ssize_t written = write(STDOUT_FILENO, msg, strlen(msg));
    if (written != (ssize_t)strlen(msg)) {
        FAIL("stdout write failed");
        return;
    }

    PASS();
}

/* ============================================================================
 * Main
 * ============================================================================ */

int main(void) {
    printf("\n");
    printf("========================================\n");
    printf("  Strix-Turbo Parasitic Batch Tests\n");
    printf("========================================\n");
    printf("\n");

    /* Check if batching is active */
    const char* preload = getenv("LD_PRELOAD");
    if (preload && strstr(preload, "libparasitic_batch")) {
        printf("Batching: ENABLED\n");
    } else {
        printf("Batching: DISABLED (baseline)\n");
    }
    printf("\n");

    /* Run tests */
    test_basic_write_read();
    test_pread_pwrite();
    test_multiple_files();
    test_large_io();
    test_fsync();
    test_error_handling();
    test_rapid_open_close();
    test_stdio_passthrough();

    /* Summary */
    printf("\n");
    printf("========================================\n");
    printf("  Results: %d passed, %d failed\n", tests_passed, tests_failed);
    printf("========================================\n");
    printf("\n");

    /* Cleanup */
    unlink(TEST_FILE);

    return tests_failed > 0 ? 1 : 0;
}
