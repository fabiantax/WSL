/*
 * Unit Tests for Lock-Free SPSC Ring Buffer
 *
 * Compile with:
 *   gcc -std=c11 -O2 -lpthread spsc_ring_buffer.c spsc_ring_buffer_test.c -o test
 */

#include "spsc_ring_buffer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <threads.h>
#include <time.h>

/* Test counter */
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST_ASSERT(cond, msg) \
  do { \
    if (!(cond)) { \
      fprintf(stderr, "FAIL: %s\n", msg); \
      tests_failed++; \
    } else { \
      tests_passed++; \
    } \
  } while (0)

#define TEST_CASE(name) \
  printf("\n=== Test: %s ===\n", name)

/* ============================================================================
 * Basic Functionality Tests
 * ============================================================================ */

void test_basic_enqueue_dequeue(void) {
  TEST_CASE("Basic Enqueue/Dequeue");

  spsc_ring_buffer_t *rb = spsc_create(16, sizeof(uint32_t));
  TEST_ASSERT(rb != NULL, "Ring buffer creation");

  uint32_t value = 42;
  TEST_ASSERT(spsc_try_enqueue(rb, &value), "Enqueue success");

  uint32_t result = 0;
  TEST_ASSERT(spsc_try_dequeue(rb, &result), "Dequeue success");
  TEST_ASSERT(result == 42, "Value matches");

  TEST_ASSERT(spsc_is_empty(rb), "Buffer is empty after dequeue");

  spsc_destroy(rb);
}

void test_multiple_elements(void) {
  TEST_CASE("Multiple Elements");

  spsc_ring_buffer_t *rb = spsc_create(16, sizeof(uint32_t));

  /* Enqueue 10 elements */
  for (uint32_t i = 0; i < 10; i++) {
    TEST_ASSERT(spsc_try_enqueue(rb, &i), "Enqueue element");
  }

  /* Dequeue and verify */
  for (uint32_t i = 0; i < 10; i++) {
    uint32_t result = 0;
    TEST_ASSERT(spsc_try_dequeue(rb, &result), "Dequeue element");
    TEST_ASSERT(result == i, "Value matches in order");
  }

  TEST_ASSERT(spsc_is_empty(rb), "Buffer empty after consuming all");
  spsc_destroy(rb);
}

void test_capacity_full(void) {
  TEST_CASE("Capacity - Full Detection");

  spsc_ring_buffer_t *rb = spsc_create(4, sizeof(uint32_t));

  uint32_t val = 0;
  for (int i = 0; i < 3; i++) {
    TEST_ASSERT(spsc_try_enqueue(rb, &val), "Enqueue element");
  }

  /* 4th element should fail (capacity = 4, but 1 slot is reserved for boundary) */
  TEST_ASSERT(!spsc_try_enqueue(rb, &val), "Enqueue fails when full");
  TEST_ASSERT(spsc_is_full(rb), "Buffer reports full");

  spsc_destroy(rb);
}

void test_empty_buffer(void) {
  TEST_CASE("Empty Buffer Detection");

  spsc_ring_buffer_t *rb = spsc_create(16, sizeof(uint32_t));

  TEST_ASSERT(spsc_is_empty(rb), "Buffer is empty initially");

  uint32_t result = 0;
  TEST_ASSERT(!spsc_try_dequeue(rb, &result), "Dequeue from empty fails");

  spsc_destroy(rb);
}

/* ============================================================================
 * Wrapping Tests (modulo behavior)
 * ============================================================================ */

void test_wraparound(void) {
  TEST_CASE("Wraparound - Modulo Behavior");

  spsc_ring_buffer_t *rb = spsc_create(8, sizeof(uint32_t));

  /* Fill buffer completely */
  for (uint32_t i = 0; i < 7; i++) {
    spsc_try_enqueue(rb, &i);
  }

  /* Consume all */
  uint32_t dummy;
  for (int i = 0; i < 7; i++) {
    spsc_try_dequeue(rb, &dummy);
  }

  /* Now indices have wrapped, add more */
  uint32_t val1 = 100, val2 = 200;
  TEST_ASSERT(spsc_try_enqueue(rb, &val1), "Enqueue after wrap");
  TEST_ASSERT(spsc_try_enqueue(rb, &val2), "Enqueue after wrap");

  uint32_t result1 = 0, result2 = 0;
  TEST_ASSERT(spsc_try_dequeue(rb, &result1), "Dequeue after wrap");
  TEST_ASSERT(spsc_try_dequeue(rb, &result2), "Dequeue after wrap");

  TEST_ASSERT(result1 == 100 && result2 == 200, "Values match after wrap");

  spsc_destroy(rb);
}

/* ============================================================================
 * Alignment Tests
 * ============================================================================ */

void test_cache_line_alignment(void) {
  TEST_CASE("Cache Line Alignment");

  spsc_ring_buffer_t *rb = spsc_create(256, 64);
  TEST_ASSERT(rb != NULL, "Ring buffer creation");

  /* Verify structure layout has proper padding
   * write_pos and read_pos should be on separate cache lines
   */
  uintptr_t write_addr = (uintptr_t)&rb->write_pos;
  uintptr_t read_addr = (uintptr_t)&rb->read_pos;

  /* Calculate offset from write to read */
  ptrdiff_t offset = (ptrdiff_t)read_addr - (ptrdiff_t)write_addr;

  /* They should be CACHE_LINE_SIZE apart */
  TEST_ASSERT(offset == CACHE_LINE_SIZE, "write_pos to read_pos spacing matches cache line");

  /* Buffer pointer should be non-NULL and cache-line aligned */
  TEST_ASSERT(rb->buffer != NULL, "buffer pointer is initialized");
  TEST_ASSERT(((uintptr_t)rb->buffer) % CACHE_LINE_SIZE == 0, "buffer pointer is cache-line aligned");

  spsc_destroy(rb);
}

/* ============================================================================
 * Variable Size Element Tests
 * ============================================================================ */

void test_variable_element_size(void) {
  TEST_CASE("Variable Element Size");

  typedef struct {
    uint32_t id;
    uint64_t timestamp;
    uint8_t payload[56];
  } message_t;  /* Total: 128 bytes */

  spsc_ring_buffer_t *rb = spsc_create(256, sizeof(message_t));
  TEST_ASSERT(rb != NULL, "Create buffer with 128-byte elements");

  message_t msg_in = {
    .id = 12345,
    .timestamp = 0x1122334455667788ULL,
    .payload = { 0xAA, 0xBB, 0xCC, 0xDD }
  };

  TEST_ASSERT(spsc_try_enqueue(rb, &msg_in), "Enqueue large element");

  message_t msg_out = {0};
  TEST_ASSERT(spsc_try_dequeue(rb, &msg_out), "Dequeue large element");

  TEST_ASSERT(msg_out.id == msg_in.id, "ID matches");
  TEST_ASSERT(msg_out.timestamp == msg_in.timestamp, "Timestamp matches");
  TEST_ASSERT(memcmp(msg_out.payload, msg_in.payload, 4) == 0, "Payload matches");

  spsc_destroy(rb);
}

/* ============================================================================
 * Memory Size Calculation
 * ============================================================================ */

void test_memory_required(void) {
  TEST_CASE("Memory Size Calculation");

  /* Test various configurations */
  size_t size1 = spsc_memory_required(1024, 64);
  TEST_ASSERT(size1 > 0, "Memory calculation for 1K x 64B");

  size_t size2 = spsc_memory_required(4096, 128);
  TEST_ASSERT(size2 > 0, "Memory calculation for 4K x 128B");

  /* Non-power-of-2 should fail */
  size_t size3 = spsc_memory_required(1000, 64);
  TEST_ASSERT(size3 == 0, "Memory calculation rejects non-power-of-2");

  /* Zero capacity should fail */
  size_t size4 = spsc_memory_required(0, 64);
  TEST_ASSERT(size4 == 0, "Memory calculation rejects zero capacity");

  /* Zero element size should fail */
  size_t size5 = spsc_memory_required(1024, 0);
  TEST_ASSERT(size5 == 0, "Memory calculation rejects zero element size");
}

/* ============================================================================
 * Shared Memory Initialization Test
 * ============================================================================ */

void test_shared_memory_init(void) {
  TEST_CASE("Shared Memory Initialization");

  size_t capacity = 256;
  size_t element_size = 32;
  size_t required = spsc_memory_required(capacity, element_size);

  /* Allocate memory (simulating shared memory) */
  void *buffer = malloc(required);
  TEST_ASSERT(buffer != NULL, "Allocate buffer");

  /* Zero-initialize */
  memset(buffer, 0, required);

  /* Initialize ring buffer in pre-allocated buffer */
  bool success = spsc_init(buffer, required, capacity, element_size);
  TEST_ASSERT(success, "Initialize ring buffer in shared memory");

  /* Use the ring buffer */
  spsc_ring_buffer_t *rb = (spsc_ring_buffer_t *)buffer;

  /* Create element with correct size */
  uint8_t val[32];
  memset(val, 0xAB, sizeof(val));
  TEST_ASSERT(spsc_try_enqueue(rb, val), "Enqueue to shared memory buffer");

  uint8_t result[32] = {0};
  TEST_ASSERT(spsc_try_dequeue(rb, result), "Dequeue from shared memory buffer");
  TEST_ASSERT(memcmp(result, val, sizeof(val)) == 0, "Value preserved in shared memory");

  free(buffer);
}

/* ============================================================================
 * Stress Tests
 * ============================================================================ */

void test_stress_many_operations(void) {
  TEST_CASE("Stress Test - Many Operations");

  spsc_ring_buffer_t *rb = spsc_create(1024, sizeof(uint32_t));

  const int iterations = 10000;

  /* Single-threaded producer/consumer stress test */
  for (int i = 0; i < iterations; i++) {
    uint32_t val = i;

    if (!spsc_try_enqueue(rb, &val)) {
      /* If full, drain some elements */
      uint32_t dummy;
      while (spsc_try_dequeue(rb, &dummy)) {
      }
      /* Retry enqueue */
      if (!spsc_try_enqueue(rb, &val)) {
        TEST_ASSERT(false, "Enqueue failed even after draining");
        break;
      }
    }
  }

  /* Verify all can be consumed */
  int consumed = 0;
  uint32_t dummy;
  while (spsc_try_dequeue(rb, &dummy)) {
    consumed++;
  }

  TEST_ASSERT(consumed > 0, "At least some elements consumed");

  spsc_destroy(rb);
}

/* ============================================================================
 * Count Query Test
 * ============================================================================ */

void test_element_count(void) {
  TEST_CASE("Element Count Query");

  spsc_ring_buffer_t *rb = spsc_create(16, sizeof(uint32_t));

  TEST_ASSERT(spsc_count(rb) == 0, "Count is 0 for empty buffer");

  /* Add 5 elements */
  for (uint32_t i = 0; i < 5; i++) {
    spsc_try_enqueue(rb, &i);
  }

  TEST_ASSERT(spsc_count(rb) == 5, "Count is 5 after 5 enqueues");

  /* Remove 2 elements */
  uint32_t dummy;
  spsc_try_dequeue(rb, &dummy);
  spsc_try_dequeue(rb, &dummy);

  TEST_ASSERT(spsc_count(rb) == 3, "Count is 3 after 2 dequeues");

  spsc_destroy(rb);
}

/* ============================================================================
 * Main Test Runner
 * ============================================================================ */

int main(void) {
  printf("Lock-Free SPSC Ring Buffer Test Suite\n");
  printf("=====================================\n");

  /* Basic functionality */
  test_basic_enqueue_dequeue();
  test_multiple_elements();
  test_capacity_full();
  test_empty_buffer();

  /* Wrapping */
  test_wraparound();

  /* Alignment */
  test_cache_line_alignment();

  /* Variable sizes */
  test_variable_element_size();

  /* Memory management */
  test_memory_required();
  test_shared_memory_init();

  /* Stress */
  test_stress_many_operations();

  /* Query operations */
  test_element_count();

  /* Summary */
  printf("\n");
  printf("=====================================\n");
  printf("Tests Passed: %d\n", tests_passed);
  printf("Tests Failed: %d\n", tests_failed);
  printf("=====================================\n");

  return tests_failed > 0 ? 1 : 0;
}
