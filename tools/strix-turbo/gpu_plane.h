/**
 * GPU Plane - DP2 in Axiomatic Design
 * Satisfies: FR2 (GPU Compute with < 5% overhead)
 * Independence: Completely separate from storage, NPU, interop
 *
 * Design Rationale:
 * The current GPU-PV architecture couples:
 *   - Memory transfer (copy overhead)
 *   - Command submission (translation overhead)
 *   - Synchronization (fence overhead)
 *
 * This decoupled design addresses each independently:
 *   - DP2.1: Direct memory sharing (no copies)
 *   - DP2.2: Direct queue submission (no translation)
 *   - DP2.3: Shared fence memory (no roundtrips)
 */

#ifndef STRIX_GPU_PLANE_H
#define STRIX_GPU_PLANE_H

#include <cstdint>
#include <cstddef>
#include <memory>
#include <span>
#include <expected>
#include <functional>

namespace strix {
namespace gpu_plane {

//==============================================================================
// Error Codes
//==============================================================================

enum class GPUError : int32_t {
    Success = 0,
    DeviceNotFound = -1,
    InitFailed = -2,
    OutOfMemory = -3,
    InvalidCommand = -4,
    Timeout = -5,
    DeviceLost = -6,
    FeatureNotSupported = -7
};

template<typename T>
using Result = std::expected<T, GPUError>;

//==============================================================================
// GPU Access Modes (Decoupled from each other)
//==============================================================================

/**
 * Access mode determines how GPU resources are accessed.
 * Each mode is a different DP for the same FR.
 */
enum class AccessMode {
    /**
     * SR-IOV Virtual Function
     * - Best: Native performance, shared with host
     * - Requires: IOMMU, SR-IOV capable GPU
     * - Strix Halo: RDNA 3.5 supports SR-IOV
     */
    SRIOV_VF,

    /**
     * Full GPU Passthrough
     * - Good: Native performance, dedicated to guest
     * - Requires: Separate GPU for host display
     */
    Passthrough,

    /**
     * Enhanced Paravirtualization
     * - Acceptable: ~5-10% overhead
     * - Works everywhere, no special requirements
     */
    EnhancedPV,

    /**
     * Legacy GPU-PV
     * - Fallback: Current WSL2 behavior (~2x overhead)
     */
    LegacyPV
};

//==============================================================================
// GPU Memory (DP2.1)
//==============================================================================

namespace memory {

/**
 * GPU Memory Allocation Type
 */
enum class AllocationType {
    DeviceLocal,        // GPU-only, fastest
    HostVisible,        // CPU can read/write, GPU can access
    HostCached,         // Like HostVisible, but cached on CPU
    Shared              // Shared between host and guest (WSL2 specific)
};

/**
 * Memory Handle (opaque, implementation-specific)
 */
struct Handle {
    uint64_t id;
    size_t size;
    AllocationType type;
    void* host_ptr;     // If HostVisible/Cached/Shared
    uint64_t gpu_addr;  // GPU virtual address
};

/**
 * GPU Memory Interface
 */
class MemoryManager {
public:
    virtual ~MemoryManager() = default;

    /**
     * Allocate GPU memory.
     */
    virtual Result<Handle> allocate(
        size_t size,
        AllocationType type = AllocationType::DeviceLocal,
        size_t alignment = 256
    ) = 0;

    /**
     * Free GPU memory.
     */
    virtual void free(Handle& handle) = 0;

    /**
     * Map GPU memory to host address space.
     * Only works for HostVisible/Cached/Shared.
     */
    virtual Result<void*> map(Handle& handle, size_t offset = 0, size_t size = 0) = 0;

    /**
     * Unmap GPU memory.
     */
    virtual void unmap(Handle& handle) = 0;

    /**
     * Zero-copy import from host memory (DAX-style).
     *
     * This is the KEY DECOUPLING:
     * - No copies between host and GPU
     * - Direct physical page sharing
     * - Works with shared memory from data_plane
     */
    virtual Result<Handle> import_host_memory(
        void* host_ptr,
        size_t size
    ) = 0;

    /**
     * Export to host memory (for sharing with other processes).
     */
    virtual Result<void*> export_to_host(Handle& handle) = 0;
};

} // namespace memory

//==============================================================================
// Command Submission (DP2.2)
//==============================================================================

namespace command {

/**
 * Queue types
 */
enum class QueueType {
    Graphics,
    Compute,
    Transfer,
    Sparse
};

/**
 * Command type
 */
enum class CommandType {
    Copy,
    Dispatch,
    Draw,
    Barrier,
    Timestamp,
    Custom
};

/**
 * Command entry for queue submission
 */
struct Command {
    CommandType type;
    uint32_t flags;

    // Type-specific data
    union {
        struct {
            memory::Handle* src;
            memory::Handle* dst;
            size_t src_offset;
            size_t dst_offset;
            size_t size;
        } copy;

        struct {
            uint64_t shader_id;
            uint32_t group_count_x;
            uint32_t group_count_y;
            uint32_t group_count_z;
            void* push_constants;
            size_t push_size;
        } dispatch;

        struct {
            // Draw parameters
            uint32_t vertex_count;
            uint32_t instance_count;
            uint32_t first_vertex;
            uint32_t first_instance;
        } draw;

        struct {
            // Barrier parameters
            memory::Handle* buffer;
            uint32_t src_stage;
            uint32_t dst_stage;
        } barrier;

        struct {
            memory::Handle* buffer;
            size_t offset;
        } timestamp;
    };
};

/**
 * Command Queue Interface
 */
class Queue {
public:
    virtual ~Queue() = default;

    /**
     * Submit commands to queue.
     *
     * With SR-IOV/Passthrough: Direct hardware submission
     * With PV: Minimal translation
     */
    virtual Result<uint64_t> submit(std::span<const Command> commands) = 0;

    /**
     * Submit with fence for synchronization.
     */
    virtual Result<uint64_t> submit_with_fence(
        std::span<const Command> commands,
        uint64_t fence_value
    ) = 0;

    /**
     * Wait for submission to complete.
     */
    virtual GPUError wait(uint64_t submission_id, uint64_t timeout_ns = UINT64_MAX) = 0;

    /**
     * Check if submission completed (non-blocking).
     */
    virtual bool is_complete(uint64_t submission_id) = 0;
};

/**
 * Command Queue Manager
 */
class QueueManager {
public:
    virtual ~QueueManager() = default;

    /**
     * Get a queue of specified type.
     */
    virtual Queue* get_queue(QueueType type, uint32_t index = 0) = 0;

    /**
     * Get number of queues of given type.
     */
    virtual uint32_t queue_count(QueueType type) = 0;
};

} // namespace command

//==============================================================================
// Synchronization (DP2.3)
//==============================================================================

namespace sync {

/**
 * Fence for GPU-CPU synchronization.
 *
 * KEY INSIGHT:
 * Current GPU-PV uses hypercalls for fence signaling.
 * This design uses SHARED MEMORY for fences - no VM exits.
 *
 * The fence value is written directly to shared memory
 * by the GPU, and read by the CPU without any kernel
 * or hypervisor involvement.
 */
struct alignas(64) Fence {
    std::atomic<uint64_t> value;      // Current fence value
    std::atomic<uint64_t> signaled;   // Last signaled value
    uint64_t _pad[6];                 // Pad to cache line
};

static_assert(sizeof(Fence) == 64, "Fence must be cache-line sized");

/**
 * Fence Manager
 */
class FenceManager {
public:
    virtual ~FenceManager() = default;

    /**
     * Create a fence in shared memory.
     */
    virtual Result<Fence*> create_fence() = 0;

    /**
     * Destroy a fence.
     */
    virtual void destroy_fence(Fence* fence) = 0;

    /**
     * Signal fence (GPU side).
     * This is a DIRECT MEMORY WRITE - no VM exit.
     */
    virtual void signal(Fence* fence, uint64_t value) = 0;

    /**
     * Wait for fence (CPU side).
     * This POLLS SHARED MEMORY - no VM exit.
     */
    virtual GPUError wait(
        Fence* fence,
        uint64_t value,
        uint64_t timeout_ns = UINT64_MAX
    ) = 0;

    /**
     * Check fence status (non-blocking).
     * Just a memory read - no syscall.
     */
    virtual bool is_signaled(Fence* fence, uint64_t value) = 0;
};

/**
 * Semaphore for GPU-GPU synchronization.
 */
class Semaphore {
public:
    virtual ~Semaphore() = default;

    /**
     * Signal semaphore (from GPU queue).
     */
    virtual void signal(command::Queue& queue) = 0;

    /**
     * Wait on semaphore (from GPU queue).
     */
    virtual void wait(command::Queue& queue) = 0;
};

} // namespace sync

//==============================================================================
// GPU Plane Interface
//==============================================================================

/**
 * GPU Device Information
 */
struct DeviceInfo {
    char name[128];
    uint32_t vendor_id;
    uint32_t device_id;

    // Capabilities
    uint64_t vram_size;
    uint64_t shared_memory_size;
    uint32_t compute_units;
    uint32_t max_clock_mhz;

    // Features
    bool supports_sriov;
    bool supports_passthrough;
    bool supports_shared_memory;

    // AMD Strix Halo specific
    bool is_rdna35;
    uint32_t xdna_version;  // 0 if no NPU
};

/**
 * GPU Plane - Main interface
 *
 * This is COMPLETELY INDEPENDENT from:
 * - DataPlane (storage I/O)
 * - NPUPlane (AI acceleration)
 * - CommandPlane (process interop)
 * - BatchingEngine (syscall batching)
 *
 * The only "coupling" is optional integration with
 * DataPlane's shared memory for zero-copy data transfer.
 */
class GPUPlane {
public:
    virtual ~GPUPlane() = default;

    /**
     * Initialize GPU plane with specified access mode.
     */
    virtual Result<void> initialize(AccessMode mode = AccessMode::SRIOV_VF) = 0;

    /**
     * Shutdown GPU plane.
     */
    virtual void shutdown() = 0;

    /**
     * Get device information.
     */
    virtual const DeviceInfo& device_info() const = 0;

    /**
     * Get current access mode.
     */
    virtual AccessMode access_mode() const = 0;

    //--------------------------------------------------------------------------
    // Component Access
    //--------------------------------------------------------------------------

    virtual memory::MemoryManager& memory() = 0;
    virtual command::QueueManager& queues() = 0;
    virtual sync::FenceManager& fences() = 0;

    //--------------------------------------------------------------------------
    // High-Level Compute API
    //--------------------------------------------------------------------------

    /**
     * Load a compute shader.
     */
    virtual Result<uint64_t> load_shader(
        std::span<const uint8_t> spirv_or_dxil
    ) = 0;

    /**
     * Unload a compute shader.
     */
    virtual void unload_shader(uint64_t shader_id) = 0;

    /**
     * Dispatch compute work (synchronous).
     */
    virtual Result<void> dispatch(
        uint64_t shader_id,
        uint32_t group_x, uint32_t group_y, uint32_t group_z,
        std::span<memory::Handle*> buffers,
        std::span<const uint8_t> push_constants = {}
    ) = 0;

    /**
     * Dispatch compute work (asynchronous).
     */
    virtual Result<sync::Fence*> dispatch_async(
        uint64_t shader_id,
        uint32_t group_x, uint32_t group_y, uint32_t group_z,
        std::span<memory::Handle*> buffers,
        std::span<const uint8_t> push_constants = {}
    ) = 0;

    //--------------------------------------------------------------------------
    // Integration with Data Plane (Optional, Zero-Copy)
    //--------------------------------------------------------------------------

    /**
     * Import buffer from data plane shared memory.
     *
     * This enables ZERO-COPY between:
     * - Windows file → GPU compute → Linux process
     * - Linux file → GPU compute → Windows process
     *
     * Data never leaves the shared memory region.
     */
    virtual Result<memory::Handle> import_from_data_plane(
        void* shared_memory_ptr,
        size_t size
    ) = 0;
};

/**
 * Create GPU plane for current platform.
 */
std::unique_ptr<GPUPlane> create_gpu_plane();

/**
 * Query available GPUs.
 */
std::vector<DeviceInfo> enumerate_gpus();

/**
 * Check if specific access mode is available.
 */
bool is_access_mode_available(AccessMode mode);

} // namespace gpu_plane
} // namespace strix

#endif // STRIX_GPU_PLANE_H
