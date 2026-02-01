/*
 * Lock-Free Single-Producer Single-Consumer Ring Buffer
 * Suitable for cross-process shared memory IPC (WSL2↔Windows)
 *
 * Memory ordering: C11 atomics with acquire/release semantics
 * Cache line alignment: 64 bytes (Intel/x86 standard)
 * Power-of-2 sizing: Masking instead of modulo
 *
 * Non-blocking design: Use try_enqueue/try_dequeue
 * No locks or condition variables
 */

#ifndef SPSC_RING_BUFFER_H
#define SPSC_RING_BUFFER_H

#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdalign.h>
#include <string.h>
#include <stdbool.h>
#include <assert.h>

/* ============================================================================
 * Configuration
 * ============================================================================ */

/* Cache line size - Intel/x86 is 64 bytes */
#define CACHE_LINE_SIZE 64

/* Default element size - adjust based on your needs */
#define SPSC_ELEMENT_SIZE 64

/* Default capacity - power of 2 (1024 = 2^10) */
#define SPSC_CAPACITY (1 << 10)

/* Compile-time verification that capacity is power of 2 */
#define IS_POWER_OF_2(x) (((x) & ((x) - 1)) == 0)
#define SPSC_CAPACITY_CHECK \
  _Static_assert(IS_POWER_OF_2(SPSC_CAPACITY), \
                 "SPSC_CAPACITY must be power of 2")

/* ============================================================================
 * Data Structures
 * ============================================================================ */

/*
 * Ring buffer element
 * Flexible: change element_size at runtime or compile-time
 */
typedef struct {
  uint8_t data[SPSC_ELEMENT_SIZE];
} spsc_element_t;

/*
 * Lock-free SPSC ring buffer
 *
 * Memory layout (for cache efficiency):
 * - Consumer index (64-byte aligned, producer never writes)
 * - 64-byte padding
 * - Producer index (64-byte aligned, consumer never writes)
 * - 64-byte padding
 * - Configuration
 * - Ring buffer data pointer (64-byte aligned)
 *
 * The buffer itself is allocated separately to ensure proper alignment.
 */
typedef struct {
  /* Consumer-owned data (head pointer) */
  _Alignas(CACHE_LINE_SIZE) atomic_size_t write_pos;
  char _pad1[CACHE_LINE_SIZE - sizeof(atomic_size_t)];

  /* Producer-owned data (tail pointer) */
  _Alignas(CACHE_LINE_SIZE) atomic_size_t read_pos;
  char _pad2[CACHE_LINE_SIZE - sizeof(atomic_size_t)];

  /* Configuration (read-only after init) */
  size_t capacity;
  size_t mask;  /* capacity - 1, for fast modulo */
  size_t element_size;

  /* Ring buffer data storage pointer (allocated separately) */
  uint8_t *buffer;
} spsc_ring_buffer_t;

/* ============================================================================
 * API - Initialization
 * ============================================================================ */

/*
 * Create a new SPSC ring buffer
 *
 * Args:
 *   capacity:     Number of elements (must be power of 2)
 *   element_size: Size of each element in bytes
 *
 * Returns:
 *   Pointer to allocated ring buffer, or NULL on error
 *
 * Notes:
 *   - Allocates from heap
 *   - For shared memory: use mmap/MapViewOfFile instead
 *   - Returned buffer is zero-initialized
 */
spsc_ring_buffer_t *spsc_create(size_t capacity, size_t element_size);

/*
 * Initialize a pre-allocated ring buffer (for shared memory)
 *
 * Args:
 *   buffer:       Pre-allocated memory region
 *   buffer_size:  Size of allocated buffer in bytes
 *   capacity:     Number of elements (must be power of 2)
 *   element_size: Size of each element in bytes
 *
 * Returns:
 *   true on success, false if buffer too small
 *
 * Notes:
 *   - For shared memory (WSL2 IPC): caller provides backing memory
 *   - Buffer must be zero-initialized before first use
 */
bool spsc_init(void *buffer, size_t buffer_size,
               size_t capacity, size_t element_size);

/*
 * Get required memory size for ring buffer
 *
 * Args:
 *   capacity:     Number of elements
 *   element_size: Size of each element
 *
 * Returns:
 *   Bytes needed (including padding for cache alignment)
 */
size_t spsc_memory_required(size_t capacity, size_t element_size);

/*
 * Destroy a ring buffer (free heap memory)
 */
void spsc_destroy(spsc_ring_buffer_t *rb);

/* ============================================================================
 * API - Core Operations
 * ============================================================================ */

/*
 * Try to enqueue an element (non-blocking)
 *
 * Args:
 *   rb:       Ring buffer
 *   element:  Pointer to element data (element_size bytes)
 *
 * Returns:
 *   true if enqueued successfully
 *   false if buffer is full (doesn't block)
 *
 * Notes:
 *   - PRODUCER ONLY
 *   - Copies element_size bytes from element
 *   - Non-blocking: returns immediately
 *   - Memory ordering: release semantics on success
 */
bool spsc_try_enqueue(spsc_ring_buffer_t *rb, const void *element);

/*
 * Try to dequeue an element (non-blocking)
 *
 * Args:
 *   rb:       Ring buffer
 *   element:  Pointer to buffer (element_size bytes)
 *
 * Returns:
 *   true if dequeued successfully
 *   false if buffer is empty (doesn't block)
 *
 * Notes:
 *   - CONSUMER ONLY
 *   - Copies element into provided buffer
 *   - Non-blocking: returns immediately
 *   - Memory ordering: acquire semantics
 */
bool spsc_try_dequeue(spsc_ring_buffer_t *rb, void *element);

/* ============================================================================
 * API - Query Operations
 * ============================================================================ */

/*
 * Check if buffer is empty
 *
 * Notes:
 *   - May race with concurrent operations
 *   - Intended as hint, not strict guarantee
 */
bool spsc_is_empty(spsc_ring_buffer_t *rb);

/*
 * Check if buffer is full
 *
 * Notes:
 *   - May race with concurrent operations
 *   - Intended as hint, not strict guarantee
 */
bool spsc_is_full(spsc_ring_buffer_t *rb);

/*
 * Get number of elements currently in buffer
 *
 * Notes:
 *   - Approximate: may race with concurrent operations
 *   - Conservative estimate (undershoots rather than overshoots)
 */
size_t spsc_count(spsc_ring_buffer_t *rb);

/* ============================================================================
 * Memory Ordering Reference
 * ============================================================================
 *
 * This implementation uses C11 atomics with:
 *
 * PRODUCER SIDE (enqueue):
 *   1. Write element to buffer (normal store)
 *   2. atomic_store_explicit(...write_pos, memory_order_release)
 *      ↓ Release barrier ensures (1) happens-before consumer reads
 *
 * CONSUMER SIDE (dequeue):
 *   1. atomic_load_explicit(...read_pos, memory_order_acquire)
 *      ↓ Acquire barrier ensures we see all producer writes before (1)
 *   2. Read element from buffer (normal load)
 *
 * Guarantee:
 *   If consumer sees a new write_pos, it will see all element data
 *   that producer wrote before updating write_pos.
 * ============================================================================ */

#endif /* SPSC_RING_BUFFER_H */
