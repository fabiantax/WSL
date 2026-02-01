/**
 * io_uring Batch Framework - Unit Tests
 *
 * Build: g++ -O2 -std=c++17 uring_batch_test.cpp uring_batch.cpp -luring -o uring_batch_test
 * Run: ./uring_batch_test
 */

#include "uring_batch.h"

#include <iostream>
#include <fstream>
#include <cstring>
#include <cassert>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

using namespace strix::uring;

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) std::cout << "TEST: " << name << "... " << std::flush
#define PASS() do { std::cout << "PASSED\n"; tests_passed++; } while(0)
#define FAIL(msg) do { std::cout << "FAILED: " << msg << "\n"; tests_failed++; } while(0)

//==============================================================================
// Test Helpers
//==============================================================================

static const char* TEST_DIR = "/tmp/strix_uring_test";
static const char* TEST_FILE = "/tmp/strix_uring_test/test_file.txt";

static void setup() {
    mkdir(TEST_DIR, 0755);
}

static void cleanup() {
    unlink(TEST_FILE);

    // Remove other test files
    for (int i = 0; i < 10; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d.txt", TEST_DIR, i);
        unlink(path);
    }

    rmdir(TEST_DIR);
}

//==============================================================================
// Tests
//==============================================================================

static void test_context_init() {
    TEST("context initialization");

    UringContext ctx;

    if (ctx.is_initialized()) {
        FAIL("should not be initialized before init");
        return;
    }

    if (!ctx.initialize(UringConfig::balanced())) {
        FAIL("initialization failed");
        return;
    }

    if (!ctx.is_initialized()) {
        FAIL("should be initialized after init");
        return;
    }

    ctx.shutdown();

    if (ctx.is_initialized()) {
        FAIL("should not be initialized after shutdown");
        return;
    }

    PASS();
}

static void test_basic_write_read() {
    TEST("basic write/read");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    // Create test file
    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    const char* test_data = "Hello, io_uring!";
    size_t test_len = strlen(test_data);
    ssize_t write_result = -1;
    ssize_t read_result = -1;
    char read_buf[64] = {0};

    // Write
    BatchBuilder write_batch(ctx);
    write_batch.write(fd, test_data, test_len, 0,
        [](int32_t result, void* data) {
            *static_cast<ssize_t*>(data) = result;
        }, &write_result);
    write_batch.submit_and_wait(1);
    ctx.process_completions(0);

    if (write_result != static_cast<ssize_t>(test_len)) {
        FAIL("write returned wrong size");
        close(fd);
        return;
    }

    // Read
    BatchBuilder read_batch(ctx);
    read_batch.read(fd, read_buf, sizeof(read_buf) - 1, 0,
        [](int32_t result, void* data) {
            *static_cast<ssize_t*>(data) = result;
        }, &read_result);
    read_batch.submit_and_wait(1);
    ctx.process_completions(0);

    if (read_result != static_cast<ssize_t>(test_len)) {
        FAIL("read returned wrong size");
        close(fd);
        return;
    }

    if (strcmp(read_buf, test_data) != 0) {
        FAIL("data mismatch");
        close(fd);
        return;
    }

    close(fd);
    PASS();
}

static void test_batch_multiple_ops() {
    TEST("batch multiple operations");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    // Create multiple files
    std::vector<int> fds;
    std::vector<ssize_t> results(10, 0);
    char write_data[10][64];
    char read_data[10][64];

    for (int i = 0; i < 10; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d.txt", TEST_DIR, i);

        int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            FAIL("open failed");
            for (int f : fds) close(f);
            return;
        }
        fds.push_back(fd);
        snprintf(write_data[i], sizeof(write_data[i]), "File %d content", i);
    }

    // Batch write all files
    BatchBuilder write_batch(ctx);
    for (int i = 0; i < 10; i++) {
        write_batch.write(fds[i], write_data[i], strlen(write_data[i]), 0,
            [](int32_t result, void* data) {
                *static_cast<ssize_t*>(data) = result;
            }, &results[i]);
    }

    int submitted = write_batch.submit_and_wait(10);
    ctx.process_completions(0);

    if (submitted < 10) {
        FAIL("not all writes submitted");
        for (int f : fds) close(f);
        return;
    }

    // Batch read all files
    memset(read_data, 0, sizeof(read_data));
    BatchBuilder read_batch(ctx);
    for (int i = 0; i < 10; i++) {
        read_batch.read(fds[i], read_data[i], sizeof(read_data[i]) - 1, 0);
    }

    read_batch.submit_and_wait(10);
    ctx.process_completions(0);

    // Verify
    bool all_match = true;
    for (int i = 0; i < 10; i++) {
        if (strcmp(write_data[i], read_data[i]) != 0) {
            all_match = false;
            break;
        }
    }

    for (int f : fds) close(f);

    if (!all_match) {
        FAIL("data mismatch in batch");
        return;
    }

    PASS();
}

static void test_async_file() {
    TEST("AsyncFile class");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    AsyncFile file(ctx);

    // Open sync
    if (!file.open_sync(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC)) {
        FAIL("open_sync failed");
        return;
    }

    if (!file.is_open()) {
        FAIL("file should be open");
        return;
    }

    // Write sync
    const char* data = "AsyncFile test data";
    ssize_t written = file.write_sync(data, strlen(data), 0);
    if (written != static_cast<ssize_t>(strlen(data))) {
        FAIL("write_sync failed");
        return;
    }

    // Read sync
    char buf[64] = {0};
    ssize_t bytes_read = file.read_sync(buf, sizeof(buf) - 1, 0);
    if (bytes_read != written) {
        FAIL("read_sync wrong size");
        return;
    }

    if (strcmp(buf, data) != 0) {
        FAIL("data mismatch");
        return;
    }

    file.close_sync();

    if (file.is_open()) {
        FAIL("file should be closed");
        return;
    }

    PASS();
}

static void test_batch_stat() {
    TEST("batch_stat convenience function");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    // Create test files with known sizes
    for (int i = 0; i < 5; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d.txt", TEST_DIR, i);

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            char data[100];
            int size = (i + 1) * 10;
            memset(data, 'A', size);
            write(fd, data, size);
            close(fd);
        }
    }

    // Batch stat
    std::vector<BatchStatRequest> requests;
    for (int i = 0; i < 5; i++) {
        char* path = new char[256];
        snprintf(path, 256, "%s/file_%d.txt", TEST_DIR, i);
        requests.push_back({path});
    }

    std::vector<BatchStatResult> results;
    if (!batch_stat(ctx, requests, results)) {
        FAIL("batch_stat failed");
        for (auto& r : requests) delete[] r.path;
        return;
    }

    bool sizes_match = true;
    for (int i = 0; i < 5; i++) {
        int expected = (i + 1) * 10;
        if (results[i].error != 0 || results[i].statx.stx_size != static_cast<uint64_t>(expected)) {
            sizes_match = false;
            break;
        }
    }

    for (auto& r : requests) delete[] r.path;

    if (!sizes_match) {
        FAIL("file sizes don't match expected");
        return;
    }

    PASS();
}

static void test_wsl2_batch_processor() {
    TEST("WSL2BatchProcessor");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    WSL2BatchProcessor processor(ctx);
    WSL2BatchProcessor::Config cfg;
    cfg.max_batch_size = 10;
    cfg.batch_timeout_us = 1000;
    cfg.auto_submit = true;
    processor.configure(cfg);

    // Queue multiple writes
    std::vector<ssize_t> results(5, 0);
    char data[5][32];

    for (int i = 0; i < 5; i++) {
        snprintf(data[i], sizeof(data[i]), "Block %d\n", i);
        processor.queue_write(fd, data[i], strlen(data[i]), i * 32,
            [](int32_t result, void* ptr) {
                *static_cast<ssize_t*>(ptr) = result;
            }, &results[i]);
    }

    // Flush and process
    processor.flush();
    ctx.wait_completions(5, 1000);
    ctx.process_completions(0);

    close(fd);

    // Verify all writes succeeded
    bool all_ok = true;
    for (int i = 0; i < 5; i++) {
        if (results[i] <= 0) {
            all_ok = false;
            break;
        }
    }

    if (!all_ok) {
        FAIL("not all writes succeeded");
        return;
    }

    PASS();
}

static void test_statistics() {
    TEST("statistics tracking");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    ctx.reset_stats();

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    // Do some operations
    BatchBuilder batch(ctx);
    const char* data = "stats test";
    for (int i = 0; i < 5; i++) {
        batch.write(fd, data, strlen(data), i * 20);
    }
    batch.submit_and_wait(5);
    ctx.process_completions(0);

    close(fd);

    const auto& stats = ctx.stats();

    if (stats.submissions < 5) {
        FAIL("submissions count too low");
        return;
    }

    if (stats.completions < 5) {
        FAIL("completions count too low");
        return;
    }

    PASS();
}

static void test_linked_operations() {
    TEST("linked operations");

    UringContext ctx;
    if (!ctx.initialize()) {
        FAIL("init failed");
        return;
    }

    int fd = open(TEST_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        FAIL("open failed");
        return;
    }

    // Link write followed by fsync
    const char* data = "linked data";
    ssize_t write_result = -1;
    int fsync_result = -1;

    BatchBuilder batch(ctx);
    batch.write(fd, data, strlen(data), 0,
        [](int32_t result, void* ptr) {
            *static_cast<ssize_t*>(ptr) = result;
        }, &write_result);
    batch.link();  // Link next op
    batch.fsync(fd, false,
        [](int32_t result, void* ptr) {
            *static_cast<int*>(ptr) = result;
        }, &fsync_result);

    batch.submit_and_wait(2);
    ctx.process_completions(0);

    close(fd);

    if (write_result != static_cast<ssize_t>(strlen(data))) {
        FAIL("linked write failed");
        return;
    }

    if (fsync_result != 0) {
        FAIL("linked fsync failed");
        return;
    }

    PASS();
}

//==============================================================================
// Main
//==============================================================================

int main() {
    std::cout << "\n";
    std::cout << "================================================\n";
    std::cout << "  Strix-Turbo io_uring Batch Framework Tests\n";
    std::cout << "================================================\n";
    std::cout << "\n";

    setup();

    test_context_init();
    test_basic_write_read();
    test_batch_multiple_ops();
    test_async_file();
    test_batch_stat();
    test_wsl2_batch_processor();
    test_statistics();
    test_linked_operations();

    cleanup();

    std::cout << "\n";
    std::cout << "================================================\n";
    std::cout << "  Results: " << tests_passed << " passed, " << tests_failed << " failed\n";
    std::cout << "================================================\n";
    std::cout << "\n";

    return tests_failed > 0 ? 1 : 0;
}
