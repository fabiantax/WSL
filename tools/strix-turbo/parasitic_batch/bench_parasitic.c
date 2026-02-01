/*
 * Strix-Turbo Parasitic Batch Library - Performance Benchmark
 *
 * Measures performance with and without io_uring batching.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/stat.h>

#define BENCH_DIR "/tmp/strix_bench"
#define FILE_COUNT 100
#define ITERATIONS 10
#define SMALL_SIZE 4096
#define LARGE_SIZE (64 * 1024)

static double get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static void setup(void) {
    mkdir(BENCH_DIR, 0755);
}

static void cleanup(void) {
    char path[256];
    for (int i = 0; i < FILE_COUNT; i++) {
        snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);
        unlink(path);
    }
    rmdir(BENCH_DIR);
}

/* ============================================================================
 * Benchmarks
 * ============================================================================ */

static void bench_small_writes(void) {
    printf("\n=== Small Writes (%d files x %d bytes x %d iterations) ===\n",
           FILE_COUNT, SMALL_SIZE, ITERATIONS);

    char* buf = malloc(SMALL_SIZE);
    memset(buf, 'A', SMALL_SIZE);

    double total_time = 0;
    size_t total_bytes = 0;

    for (int iter = 0; iter < ITERATIONS; iter++) {
        double start = get_time_ms();

        for (int i = 0; i < FILE_COUNT; i++) {
            char path[256];
            snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);

            int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                write(fd, buf, SMALL_SIZE);
                close(fd);
                total_bytes += SMALL_SIZE;
            }
        }

        double elapsed = get_time_ms() - start;
        total_time += elapsed;
    }

    printf("  Total time: %.2f ms\n", total_time);
    printf("  Throughput: %.2f MB/s\n", (total_bytes / 1024.0 / 1024.0) / (total_time / 1000.0));
    printf("  Ops/sec:    %.0f\n", (FILE_COUNT * ITERATIONS) / (total_time / 1000.0));

    free(buf);
}

static void bench_small_reads(void) {
    printf("\n=== Small Reads (%d files x %d bytes x %d iterations) ===\n",
           FILE_COUNT, SMALL_SIZE, ITERATIONS);

    /* First create test files */
    char* wbuf = malloc(SMALL_SIZE);
    memset(wbuf, 'B', SMALL_SIZE);

    for (int i = 0; i < FILE_COUNT; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, wbuf, SMALL_SIZE);
            close(fd);
        }
    }
    free(wbuf);

    /* Now benchmark reads */
    char* buf = malloc(SMALL_SIZE);
    double total_time = 0;
    size_t total_bytes = 0;

    for (int iter = 0; iter < ITERATIONS; iter++) {
        double start = get_time_ms();

        for (int i = 0; i < FILE_COUNT; i++) {
            char path[256];
            snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);

            int fd = open(path, O_RDONLY);
            if (fd >= 0) {
                ssize_t n = read(fd, buf, SMALL_SIZE);
                if (n > 0) total_bytes += n;
                close(fd);
            }
        }

        double elapsed = get_time_ms() - start;
        total_time += elapsed;
    }

    printf("  Total time: %.2f ms\n", total_time);
    printf("  Throughput: %.2f MB/s\n", (total_bytes / 1024.0 / 1024.0) / (total_time / 1000.0));
    printf("  Ops/sec:    %.0f\n", (FILE_COUNT * ITERATIONS) / (total_time / 1000.0));

    free(buf);
}

static void bench_large_sequential(void) {
    printf("\n=== Large Sequential I/O (%d KB file) ===\n", LARGE_SIZE / 1024);

    char* buf = malloc(LARGE_SIZE);
    memset(buf, 'C', LARGE_SIZE);

    char path[256];
    snprintf(path, sizeof(path), "%s/large_file", BENCH_DIR);

    /* Write benchmark */
    double write_start = get_time_ms();

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        for (int i = 0; i < 100; i++) {
            write(fd, buf, LARGE_SIZE);
        }
        fsync(fd);
        close(fd);
    }

    double write_time = get_time_ms() - write_start;
    double write_mb = (LARGE_SIZE * 100.0) / 1024.0 / 1024.0;
    printf("  Write: %.2f MB in %.2f ms (%.2f MB/s)\n",
           write_mb, write_time, write_mb / (write_time / 1000.0));

    /* Read benchmark */
    double read_start = get_time_ms();

    fd = open(path, O_RDONLY);
    if (fd >= 0) {
        for (int i = 0; i < 100; i++) {
            read(fd, buf, LARGE_SIZE);
        }
        close(fd);
    }

    double read_time = get_time_ms() - read_start;
    printf("  Read:  %.2f MB in %.2f ms (%.2f MB/s)\n",
           write_mb, read_time, write_mb / (read_time / 1000.0));

    unlink(path);
    free(buf);
}

static void bench_mixed_workload(void) {
    printf("\n=== Mixed Workload (simulating git-like access) ===\n");

    /* Simulate git-like access patterns:
     * - Many small reads (index, loose objects)
     * - Occasional writes
     * - Random access pattern
     */

    char* buf = malloc(SMALL_SIZE);
    double total_time = 0;
    int ops = 0;

    /* Create initial files */
    for (int i = 0; i < FILE_COUNT; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            memset(buf, 'D' + (i % 10), SMALL_SIZE);
            write(fd, buf, SMALL_SIZE);
            close(fd);
        }
    }

    double start = get_time_ms();

    for (int iter = 0; iter < ITERATIONS; iter++) {
        /* Random reads (80%) */
        for (int i = 0; i < 80; i++) {
            int idx = rand() % FILE_COUNT;
            char path[256];
            snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, idx);

            int fd = open(path, O_RDONLY);
            if (fd >= 0) {
                read(fd, buf, SMALL_SIZE);
                close(fd);
                ops++;
            }
        }

        /* Random writes (20%) */
        for (int i = 0; i < 20; i++) {
            int idx = rand() % FILE_COUNT;
            char path[256];
            snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, idx);

            int fd = open(path, O_WRONLY);
            if (fd >= 0) {
                memset(buf, 'W', SMALL_SIZE);
                write(fd, buf, SMALL_SIZE);
                close(fd);
                ops++;
            }
        }
    }

    total_time = get_time_ms() - start;

    printf("  Total operations: %d\n", ops);
    printf("  Total time: %.2f ms\n", total_time);
    printf("  Ops/sec: %.0f\n", ops / (total_time / 1000.0));

    free(buf);
}

static void bench_rapid_open_close(void) {
    printf("\n=== Rapid Open/Close (metadata operations) ===\n");

    /* Create test files */
    for (int i = 0; i < FILE_COUNT; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            write(fd, "x", 1);
            close(fd);
        }
    }

    double start = get_time_ms();
    int ops = 0;

    for (int iter = 0; iter < ITERATIONS * 10; iter++) {
        for (int i = 0; i < FILE_COUNT; i++) {
            char path[256];
            snprintf(path, sizeof(path), "%s/file_%d", BENCH_DIR, i);

            int fd = open(path, O_RDONLY);
            if (fd >= 0) {
                close(fd);
                ops++;
            }
        }
    }

    double elapsed = get_time_ms() - start;

    printf("  Open/close pairs: %d\n", ops);
    printf("  Total time: %.2f ms\n", elapsed);
    printf("  Ops/sec: %.0f\n", ops / (elapsed / 1000.0));
}

/* ============================================================================
 * Main
 * ============================================================================ */

int main(void) {
    printf("\n");
    printf("================================================\n");
    printf("  Strix-Turbo Parasitic Batch Benchmark\n");
    printf("================================================\n");

    /* Check if batching is active */
    const char* preload = getenv("LD_PRELOAD");
    if (preload && strstr(preload, "libparasitic_batch")) {
        printf("  Mode: BATCHED (io_uring)\n");
    } else {
        printf("  Mode: BASELINE (direct syscalls)\n");
    }

    setup();

    /* Run benchmarks */
    bench_small_writes();
    bench_small_reads();
    bench_large_sequential();
    bench_mixed_workload();
    bench_rapid_open_close();

    cleanup();

    printf("\n================================================\n");
    printf("  Benchmark complete\n");
    printf("================================================\n\n");

    return 0;
}
