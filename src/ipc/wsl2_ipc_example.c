/*
 * WSL2 ↔ Windows Cross-Process IPC Example
 *
 * This example demonstrates how to use the lock-free SPSC ring buffer
 * for inter-process communication across WSL2 and Windows.
 *
 * WARNING: Direct WSL2↔Windows shared memory has limitations. This code
 * shows the principle; actual deployment may need file-based or TCP fallback.
 *
 * Compile Linux side:
 *   gcc -std=c11 -O2 -lrt -lpthread spsc_ring_buffer.c wsl2_ipc_example.c -o wsl2_ipc
 */

#include "spsc_ring_buffer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

/* ============================================================================
 * Shared IPC Configuration
 * ============================================================================ */

#define SHM_NAME "/wsl_ipc_ring_buffer"
#define RING_CAPACITY 4096
#define ELEMENT_SIZE 128

/* Message structure that will be passed through the ring buffer */
typedef struct {
  uint32_t message_id;
  uint32_t timestamp;
  uint16_t payload_len;
  uint16_t reserved;
  uint8_t payload[ELEMENT_SIZE - 16];
} ipc_message_t;

_Static_assert(sizeof(ipc_message_t) == ELEMENT_SIZE,
               "IPC message size must match element size");

/* ============================================================================
 * Shared Memory Management (Linux/WSL2 Side)
 * ============================================================================ */

/*
 * Create or open shared memory region
 *
 * Returns:
 *   File descriptor on success, -1 on error
 *
 * Notes:
 *   - If SHM_NAME already exists, opens it
 *   - If new, creates and zero-initializes it
 */
int open_or_create_shared_memory(size_t size) {
  int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0666);
  if (fd < 0) {
    perror("shm_open");
    return -1;
  }

  struct stat sb;
  if (fstat(fd, &sb) < 0) {
    perror("fstat");
    close(fd);
    return -1;
  }

  /* If file is new (size 0), initialize it */
  if (sb.st_size == 0) {
    if (ftruncate(fd, size) < 0) {
      perror("ftruncate");
      close(fd);
      return -1;
    }

    printf("Created shared memory: %s (%zu bytes)\n", SHM_NAME, size);
  } else {
    printf("Opened existing shared memory: %s (%ld bytes)\n", SHM_NAME, sb.st_size);
  }

  return fd;
}

/*
 * Map shared memory into process address space
 */
spsc_ring_buffer_t *map_shared_memory(int fd, size_t size) {
  void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (ptr == MAP_FAILED) {
    perror("mmap");
    return NULL;
  }

  spsc_ring_buffer_t *rb = (spsc_ring_buffer_t *)ptr;

  /* Check if already initialized */
  if (rb->capacity == 0) {
    if (!spsc_init(rb, size, RING_CAPACITY, ELEMENT_SIZE)) {
      fprintf(stderr, "Failed to initialize ring buffer\n");
      munmap(ptr, size);
      return NULL;
    }
    printf("Initialized ring buffer in shared memory\n");
  } else {
    printf("Ring buffer already initialized\n");
  }

  return rb;
}

/*
 * Unmap and close shared memory
 */
void cleanup_shared_memory(int fd, void *ptr, size_t size) {
  if (ptr && ptr != MAP_FAILED) {
    munmap(ptr, size);
  }
  if (fd >= 0) {
    close(fd);
  }
}

/*
 * Remove shared memory (cleanup)
 */
void remove_shared_memory(void) {
  if (shm_unlink(SHM_NAME) < 0) {
    perror("shm_unlink");
  } else {
    printf("Removed shared memory: %s\n", SHM_NAME);
  }
}

/* ============================================================================
 * Producer Example (WSL2 Side)
 * ============================================================================ */

void producer_example(int count, int delay_ms) {
  printf("\n=== Producer (WSL2) ===\n");
  printf("Producing %d messages with %d ms delay between sends\n", count, delay_ms);

  size_t shm_size = spsc_memory_required(RING_CAPACITY, ELEMENT_SIZE);
  int fd = open_or_create_shared_memory(shm_size);
  if (fd < 0) {
    return;
  }

  spsc_ring_buffer_t *rb = map_shared_memory(fd, shm_size);
  if (!rb) {
    close(fd);
    return;
  }

  for (int i = 0; i < count; i++) {
    ipc_message_t msg = {0};
    msg.message_id = i;
    msg.timestamp = (uint32_t)time(NULL);
    msg.payload_len = snprintf((char *)msg.payload, sizeof(msg.payload),
                                "Message %d from producer", i);

    /* Try to send message */
    if (spsc_try_enqueue(rb, &msg)) {
      printf("[%d] Sent message: %s\n", i, msg.payload);
    } else {
      printf("[%d] Buffer full! Waiting...\n", i);
      usleep(100000);  /* 100ms */
      i--;  /* Retry */
      continue;
    }

    if (delay_ms > 0) {
      usleep(delay_ms * 1000);
    }
  }

  printf("Producer finished\n");
  printf("Buffer status: %zu elements remaining\n", spsc_count(rb));

  cleanup_shared_memory(fd, rb, shm_size);
}

/* ============================================================================
 * Consumer Example (Windows or another WSL2 process)
 * ============================================================================ */

void consumer_example(int expected_count, int timeout_sec) {
  printf("\n=== Consumer (Windows/WSL2) ===\n");
  printf("Consuming up to %d messages with %d second timeout\n",
         expected_count, timeout_sec);

  size_t shm_size = spsc_memory_required(RING_CAPACITY, ELEMENT_SIZE);
  int fd = open_or_create_shared_memory(shm_size);
  if (fd < 0) {
    return;
  }

  spsc_ring_buffer_t *rb = map_shared_memory(fd, shm_size);
  if (!rb) {
    close(fd);
    return;
  }

  int consumed = 0;
  time_t start_time = time(NULL);

  printf("Waiting for messages...\n");

  while (consumed < expected_count) {
    ipc_message_t msg = {0};

    if (spsc_try_dequeue(rb, &msg)) {
      printf("[%d] Received message (id=%u, ts=%u): %s\n",
             consumed, msg.message_id, msg.timestamp, msg.payload);
      consumed++;
    } else {
      /* Check timeout */
      time_t elapsed = time(NULL) - start_time;
      if (elapsed > timeout_sec) {
        printf("Timeout waiting for more messages\n");
        break;
      }

      /* Sleep before retrying */
      usleep(10000);  /* 10ms */
    }
  }

  printf("Consumer finished\n");
  printf("Messages consumed: %d\n", consumed);
  printf("Buffer status: %zu elements remaining\n", spsc_count(rb));

  cleanup_shared_memory(fd, rb, shm_size);
}

/* ============================================================================
 * Benchmark Example
 * ============================================================================ */

void benchmark_throughput(void) {
  printf("\n=== Throughput Benchmark ===\n");

  size_t shm_size = spsc_memory_required(RING_CAPACITY, ELEMENT_SIZE);
  int fd = open_or_create_shared_memory(shm_size);
  if (fd < 0) {
    return;
  }

  spsc_ring_buffer_t *rb = map_shared_memory(fd, shm_size);
  if (!rb) {
    close(fd);
    return;
  }

  const int iterations = 100000;
  printf("Performing %d enqueue/dequeue pairs...\n", iterations);

  /* Benchmark enqueue/dequeue */
  clock_t start = clock();

  for (int i = 0; i < iterations; i++) {
    ipc_message_t msg = {.message_id = i};

    if (!spsc_try_enqueue(rb, &msg)) {
      fprintf(stderr, "Enqueue failed at iteration %d\n", i);
      break;
    }

    ipc_message_t result;
    if (!spsc_try_dequeue(rb, &result)) {
      fprintf(stderr, "Dequeue failed at iteration %d\n", i);
      break;
    }
  }

  clock_t end = clock();
  double elapsed = (double)(end - start) / CLOCKS_PER_SEC;

  printf("Time: %.3f seconds\n", elapsed);
  printf("Throughput: %.1f million ops/sec\n",
         (iterations * 2) / (elapsed * 1e6));
  printf("Latency per round-trip: %.1f µs\n",
         (elapsed / iterations) * 1e6);

  cleanup_shared_memory(fd, rb, shm_size);
}

/* ============================================================================
 * Main - Command Line Interface
 * ============================================================================ */

void print_usage(const char *prog) {
  printf("Usage: %s <mode> [args...]\n", prog);
  printf("\n");
  printf("Modes:\n");
  printf("  producer [count] [delay_ms]  - Send messages (default: 100 messages, 10ms delay)\n");
  printf("  consumer [count] [timeout]   - Receive messages (default: 100 messages, 60s timeout)\n");
  printf("  benchmark                    - Throughput benchmark\n");
  printf("  cleanup                      - Remove shared memory\n");
  printf("\n");
  printf("Example (two terminals):\n");
  printf("  Terminal 1: %s producer 100 10\n", prog);
  printf("  Terminal 2: %s consumer 100 30\n", prog);
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    print_usage(argv[0]);
    return 1;
  }

  const char *mode = argv[1];

  if (strcmp(mode, "producer") == 0) {
    int count = 100;
    int delay_ms = 10;

    if (argc > 2) {
      count = atoi(argv[2]);
    }
    if (argc > 3) {
      delay_ms = atoi(argv[3]);
    }

    producer_example(count, delay_ms);
  } else if (strcmp(mode, "consumer") == 0) {
    int count = 100;
    int timeout_sec = 60;

    if (argc > 2) {
      count = atoi(argv[2]);
    }
    if (argc > 3) {
      timeout_sec = atoi(argv[3]);
    }

    consumer_example(count, timeout_sec);
  } else if (strcmp(mode, "benchmark") == 0) {
    benchmark_throughput();
  } else if (strcmp(mode, "cleanup") == 0) {
    remove_shared_memory();
  } else {
    fprintf(stderr, "Unknown mode: %s\n", mode);
    print_usage(argv[0]);
    return 1;
  }

  return 0;
}
