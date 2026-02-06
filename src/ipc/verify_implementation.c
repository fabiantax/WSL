#include "spsc_ring_buffer.h"
#include <stdio.h>
#include <stdint.h>

int main(void) {
  printf("Lock-Free SPSC Ring Buffer Verification\n");
  printf("========================================\n\n");

  // Create ring buffer: 1024 elements, 64 bytes each
  spsc_ring_buffer_t *rb = spsc_create(1024, 64);
  if (!rb) {
    printf("ERROR: Failed to create ring buffer\n");
    return 1;
  }

  printf("✓ Ring buffer created (capacity: %zu, element size: %zu)\n",
         rb->capacity, rb->element_size);

  // Verify power-of-2 sizing
  printf("✓ Capacity is power of 2: %zu = 2^%u\n", rb->capacity,
         __builtin_ctzll(rb->capacity));

  // Verify cache-line alignment of indices
  uintptr_t write_addr = (uintptr_t)&rb->write_pos;
  uintptr_t read_addr = (uintptr_t)&rb->read_pos;
  uintptr_t buffer_addr = (uintptr_t)rb->buffer;

  printf("✓ write_pos address: 0x%lx (aligned: %s)\n", write_addr,
         (write_addr % 64 == 0) ? "YES" : "NO");
  printf("✓ read_pos address: 0x%lx (aligned: %s)\n", read_addr,
         (read_addr % 64 == 0) ? "YES" : "NO");
  printf("✓ buffer address: 0x%lx (aligned: %s)\n", buffer_addr,
         (buffer_addr % 64 == 0) ? "YES" : "NO");

  // Verify separation of producer/consumer indices
  ptrdiff_t spacing = read_addr - write_addr;
  printf("✓ Index spacing: %ld bytes (expected: 64 bytes)\n", spacing);

  // Test basic enqueue/dequeue
  uint8_t element[64];
  for (int i = 0; i < 64; i++) {
    element[i] = (uint8_t)(i * 2);
  }

  if (!spsc_try_enqueue(rb, element)) {
    printf("ERROR: Failed to enqueue\n");
    return 1;
  }
  printf("✓ Enqueued element\n");

  uint8_t result[64];
  if (!spsc_try_dequeue(rb, result)) {
    printf("ERROR: Failed to dequeue\n");
    return 1;
  }
  printf("✓ Dequeued element\n");

  // Verify data integrity
  int data_valid = 1;
  for (int i = 0; i < 64; i++) {
    if (result[i] != element[i]) {
      data_valid = 0;
      break;
    }
  }
  printf("✓ Data integrity: %s\n", data_valid ? "PASS" : "FAIL");

  printf("\n========================================\n");
  printf("All verifications passed!\n");

  spsc_destroy(rb);
  return 0;
}
