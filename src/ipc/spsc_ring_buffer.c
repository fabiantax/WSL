/*
 * Lock-Free SPSC Ring Buffer Implementation
 *
 * Key Properties:
 * - No locks or atomics in hot path (except position updates)
 * - Cache-line aligned to prevent false sharing
 * - Power-of-2 sized for fast modulo (masking)
 * - C11 atomics with acquire/release for memory ordering
 * - Non-blocking design for IPC scenarios
 */

#include "spsc_ring_buffer.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ============================================================================
 * Initialization
 * ============================================================================ */

size_t spsc_memory_required(size_t capacity, size_t element_size) {
  if (capacity == 0 || element_size == 0) {
    return 0;
  }

  if (!IS_POWER_OF_2(capacity)) {
    return 0;  /* Capacity must be power of 2 */
  }

  /* Structure size + buffer size (with cache-line alignment) */
  size_t struct_size = sizeof(spsc_ring_buffer_t);
  size_t buffer_size = capacity * element_size;

  /* Ensure buffer is cache-line aligned */
  return struct_size + CACHE_LINE_SIZE + buffer_size;
}

spsc_ring_buffer_t *spsc_create(size_t capacity, size_t element_size) {
  size_t total_size = spsc_memory_required(capacity, element_size);

  if (total_size == 0) {
    return NULL;
  }

  void *memory = malloc(total_size);
  if (!memory) {
    return NULL;
  }

  memset(memory, 0, total_size);

  if (!spsc_init(memory, total_size, capacity, element_size)) {
    free(memory);
    return NULL;
  }

  return (spsc_ring_buffer_t *)memory;
}

bool spsc_init(void *buffer, size_t buffer_size,
               size_t capacity, size_t element_size) {
  if (!buffer || capacity == 0 || element_size == 0) {
    return false;
  }

  if (!IS_POWER_OF_2(capacity)) {
    return false;  /* Capacity must be power of 2 */
  }

  size_t required = spsc_memory_required(capacity, element_size);
  if (buffer_size < required) {
    return false;
  }

  spsc_ring_buffer_t *rb = (spsc_ring_buffer_t *)buffer;

  /* Initialize atomic positions to 0 */
  atomic_store_explicit(&rb->write_pos, 0, memory_order_relaxed);
  atomic_store_explicit(&rb->read_pos, 0, memory_order_relaxed);

  /* Store configuration (read-only after init) */
  rb->capacity = capacity;
  rb->mask = capacity - 1;
  rb->element_size = element_size;

  /* Set up buffer pointer with cache-line alignment
   * Buffer starts after the header structure, aligned to cache line
   */
  uintptr_t header_end = (uintptr_t)rb + sizeof(spsc_ring_buffer_t);
  uintptr_t aligned_buffer = (header_end + CACHE_LINE_SIZE - 1) & ~(CACHE_LINE_SIZE - 1);
  rb->buffer = (uint8_t *)aligned_buffer;

  return true;
}

void spsc_destroy(spsc_ring_buffer_t *rb) {
  if (rb) {
    free(rb);
  }
}

/* ============================================================================
 * Core Operations
 * ============================================================================ */

bool spsc_try_enqueue(spsc_ring_buffer_t *rb, const void *element) {
  if (!rb || !element) {
    return false;
  }

  /* Load current read position (consumer's position) */
  size_t read_pos = atomic_load_explicit(&rb->read_pos,
                                         memory_order_acquire);

  /* Calculate next write position */
  size_t write_pos = atomic_load_explicit(&rb->write_pos,
                                          memory_order_relaxed);
  size_t next_write = (write_pos + 1) & rb->mask;

  /* Check if full (next write would overwrite unread element) */
  if (next_write == read_pos) {
    return false;  /* Buffer full */
  }

  /* Copy element to buffer */
  uint8_t *slot = &rb->buffer[write_pos * rb->element_size];
  memcpy(slot, element, rb->element_size);

  /* Update write position with release semantics
     This ensures:
     1. The memcpy above happens-before the store
     2. Consumer will see new data when it reads write_pos
     3. All prior stores are visible before this store
  */
  atomic_store_explicit(&rb->write_pos, next_write, memory_order_release);

  return true;
}

bool spsc_try_dequeue(spsc_ring_buffer_t *rb, void *element) {
  if (!rb || !element) {
    return false;
  }

  /* Load current write position (producer's position)
     Use acquire semantics to ensure we see all producer writes
     that happened before it updated write_pos
  */
  size_t write_pos = atomic_load_explicit(&rb->write_pos,
                                          memory_order_acquire);

  /* Load current read position */
  size_t read_pos = atomic_load_explicit(&rb->read_pos,
                                         memory_order_relaxed);

  /* Check if empty */
  if (read_pos == write_pos) {
    return false;  /* Buffer empty */
  }

  /* Copy element from buffer */
  uint8_t *slot = &rb->buffer[read_pos * rb->element_size];
  memcpy(element, slot, rb->element_size);

  /* Update read position (consumer-owned, no atomic needed) */
  rb->read_pos = (read_pos + 1) & rb->mask;

  return true;
}

/* ============================================================================
 * Query Operations
 * ============================================================================ */

bool spsc_is_empty(spsc_ring_buffer_t *rb) {
  if (!rb) {
    return true;
  }

  size_t write_pos = atomic_load_explicit(&rb->write_pos,
                                          memory_order_acquire);
  size_t read_pos = atomic_load_explicit(&rb->read_pos,
                                         memory_order_relaxed);

  return write_pos == read_pos;
}

bool spsc_is_full(spsc_ring_buffer_t *rb) {
  if (!rb) {
    return false;
  }

  size_t write_pos = atomic_load_explicit(&rb->write_pos,
                                          memory_order_relaxed);
  size_t read_pos = atomic_load_explicit(&rb->read_pos,
                                         memory_order_acquire);

  size_t next_write = (write_pos + 1) & rb->mask;
  return next_write == read_pos;
}

size_t spsc_count(spsc_ring_buffer_t *rb) {
  if (!rb) {
    return 0;
  }

  size_t write_pos = atomic_load_explicit(&rb->write_pos,
                                          memory_order_acquire);
  size_t read_pos = atomic_load_explicit(&rb->read_pos,
                                         memory_order_relaxed);

  if (write_pos >= read_pos) {
    return write_pos - read_pos;
  } else {
    return rb->capacity - (read_pos - write_pos);
  }
}
