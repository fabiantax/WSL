/**
 * Shared Memory IPC for WSL2 - Linux Client Implementation
 *
 * Provides the Linux (WSL2) side of the shared memory IPC system.
 * The Windows server implementation is in shared_memory_ipc_win.cpp
 *
 * Build: g++ -O3 -std=c++17 shared_memory_ipc.cpp -lpthread -o shm_client
 */

#include "shared_memory_ipc.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <cstring>
#include <chrono>
#include <thread>
#include <algorithm>

namespace strix {
namespace shm {

//==============================================================================
// SharedMemoryRegion Implementation (Linux)
//==============================================================================

#ifndef _WIN32

bool SharedMemoryRegion::map_hyperv(const char* vmbus_device, size_t size) {
    // Try to open VMBus device for Hyper-V shared memory
    // This requires a custom kernel driver or the hv_utils module

    // For now, fall back to /dev/shm for testing
    // In production, this would use the Hyper-V VMBus interface

    char shm_path[256];
    snprintf(shm_path, sizeof(shm_path), "/dev/shm/strix_%s", vmbus_device);

    int fd = open(shm_path, O_RDWR);
    if (fd < 0) {
        // Create if doesn't exist
        fd = open(shm_path, O_RDWR | O_CREAT, 0666);
        if (fd < 0) {
            return false;
        }

        // Set size
        if (ftruncate(fd, size) < 0) {
            close(fd);
            return false;
        }
    }

    return map_fd(fd, size);
}

bool SharedMemoryRegion::map_fd(int fd, size_t size) {
    if (fd < 0 || size == 0) {
        return false;
    }

    // Get actual size if needed
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 0) {
        size = static_cast<size_t>(st.st_size);
    }

    void* ptr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        close(fd);
        return false;
    }

    base_ = ptr;
    size_ = size;
    fd_ = fd;

    return true;
}

#endif // !_WIN32

//==============================================================================
// ResponseRing::wait_for Implementation
//==============================================================================

bool ResponseRing::wait_for(uint32_t request_id, ResponseEntry& out, uint32_t timeout_ms) {
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);

    while (std::chrono::steady_clock::now() < deadline) {
        // Try to consume matching response
        uint32_t head = control_->rsp_head.load(std::memory_order_acquire);
        uint32_t tail = control_->rsp_tail.load(std::memory_order_relaxed);

        // Scan available responses
        uint32_t idx = tail;
        while (idx != head) {
            const ResponseEntry& entry = entries_[idx];
            if (entry.request_id == request_id) {
                out = entry;

                // We found it - we need to consume up to this point
                // For simplicity, just consume one by one until we hit it
                while (tail != idx) {
                    // Skip this entry (lost response)
                    tail = (tail + 1) % RSP_RING_ENTRIES;
                }
                control_->rsp_tail.store((tail + 1) % RSP_RING_ENTRIES,
                                         std::memory_order_release);
                return true;
            }
            idx = (idx + 1) % RSP_RING_ENTRIES;
        }

        // Not found, yield and retry
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }

    return false;  // Timeout
}

//==============================================================================
// SharedMemoryClient Implementation
//==============================================================================

SharedMemoryClient::SharedMemoryClient(SharedMemoryRegion& shm)
    : shm_(shm)
    , cmd_ring_(shm)
    , rsp_ring_(shm) {

    // Initialize file handle table
    for (int i = 0; i < 1024; i++) {
        handles_[i].in_use = false;
    }
}

bool SharedMemoryClient::initialize(uint32_t timeout_ms) {
    if (!shm_.is_mapped()) {
        return false;
    }

    ControlBlock* ctrl = shm_.control();
    if (!ctrl->is_valid()) {
        return false;
    }

    // Signal that Linux client is ready
    ctrl->linux_ready.store(1, std::memory_order_release);

    // Wait for Windows server to be ready
    auto deadline = std::chrono::steady_clock::now() +
                    std::chrono::milliseconds(timeout_ms);

    while (std::chrono::steady_clock::now() < deadline) {
        if (ctrl->windows_ready.load(std::memory_order_acquire)) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    return false;  // Timeout waiting for server
}

int SharedMemoryClient::allocate_fd() {
    // Reserve fd 0-2 for stdin/stdout/stderr
    for (int i = 3; i < 1024; i++) {
        if (!handles_[i].in_use) {
            handles_[i].in_use = true;
            handles_[i].server_handle = 0;
            handles_[i].position = 0;
            handles_[i].path[0] = '\0';
            return i;
        }
    }
    return -1;  // No free handles
}

void SharedMemoryClient::release_fd(int fd) {
    if (fd >= 0 && fd < 1024) {
        handles_[fd].in_use = false;
    }
}

uint32_t SharedMemoryClient::alloc_data(size_t size) {
    ControlBlock* ctrl = shm_.control();

    // Simple bump allocator
    // In production, would need proper free list
    uint64_t offset = ctrl->data_alloc_head.fetch_add(
        size, std::memory_order_relaxed);

    // Check bounds
    if (offset + size > ctrl->region_size) {
        // Wrap around (losing data coherency - for demo only)
        ctrl->data_alloc_head.store(DATA_REGION_OFFSET + size,
                                    std::memory_order_relaxed);
        return DATA_REGION_OFFSET;
    }

    return static_cast<uint32_t>(offset - DATA_REGION_OFFSET);
}

void SharedMemoryClient::free_data(uint32_t offset, size_t size) {
    // No-op for simple bump allocator
    (void)offset;
    (void)size;
}

int SharedMemoryClient::open(const char* path, uint32_t flags, uint32_t mode) {
    if (!path) {
        return -EINVAL;
    }

    int fd = allocate_fd();
    if (fd < 0) {
        return -EMFILE;
    }

    // Encode mode in flags high bits
    uint32_t full_flags = flags | ((mode & 0x1FF) << 16);

    // Submit open command
    uint32_t req_id = cmd_ring_.submit(CommandType::Open, path, full_flags, 0, 0);
    if (req_id == 0) {
        release_fd(fd);
        return -EAGAIN;
    }

    // Wait for response
    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        release_fd(fd);
        return -ETIMEDOUT;
    }

    if (response.error != ErrorCode::Success) {
        release_fd(fd);
        return static_cast<int>(response.error);
    }

    // Store server handle
    handles_[fd].server_handle = response.data_offset;  // Server uses this for handle ID
    strncpy(handles_[fd].path, path, sizeof(handles_[fd].path) - 1);
    handles_[fd].path[sizeof(handles_[fd].path) - 1] = '\0';

    return fd;
}

int SharedMemoryClient::close(int fd) {
    if (fd < 0 || fd >= 1024 || !handles_[fd].in_use) {
        return -EBADF;
    }

    // Submit close command
    uint32_t req_id = cmd_ring_.submit(CommandType::Close, nullptr,
                                       static_cast<uint32_t>(handles_[fd].server_handle), 0, 0);
    if (req_id == 0) {
        return -EAGAIN;
    }

    // Wait for response
    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    release_fd(fd);
    return response.error == ErrorCode::Success ? 0 : static_cast<int>(response.error);
}

ssize_t SharedMemoryClient::read(int fd, void* buf, size_t count) {
    return pread(fd, buf, count, -1);  // -1 means use current position
}

ssize_t SharedMemoryClient::write(int fd, const void* buf, size_t count) {
    return pwrite(fd, buf, count, -1);
}

ssize_t SharedMemoryClient::pread(int fd, void* buf, size_t count, off_t offset) {
    if (fd < 0 || fd >= 1024 || !handles_[fd].in_use) {
        return -EBADF;
    }
    if (!buf || count == 0) {
        return 0;
    }

    // Allocate data region for result
    uint32_t data_offset = alloc_data(count);

    // Encode offset and server handle
    // For simplicity, using flags for server handle, data_offset for read offset
    uint32_t flags = static_cast<uint32_t>(handles_[fd].server_handle);

    // Submit read command
    uint32_t req_id = cmd_ring_.submit(CommandType::Read, nullptr, flags,
                                       data_offset, static_cast<uint32_t>(count));
    if (req_id == 0) {
        return -EAGAIN;
    }

    // Wait for response
    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    if (response.error != ErrorCode::Success) {
        return static_cast<ssize_t>(response.error);
    }

    // Copy data from shared memory
    size_t bytes_read = response.data_len;
    if (bytes_read > count) {
        bytes_read = count;
    }

    void* src = static_cast<char*>(shm_.data_region()) + response.data_offset;
    memcpy(buf, src, bytes_read);

    // Update position if not pread
    if (offset < 0) {
        handles_[fd].position += bytes_read;
    }

    shm_.control()->bytes_transferred.fetch_add(bytes_read, std::memory_order_relaxed);
    return static_cast<ssize_t>(bytes_read);
}

ssize_t SharedMemoryClient::pwrite(int fd, const void* buf, size_t count, off_t offset) {
    if (fd < 0 || fd >= 1024 || !handles_[fd].in_use) {
        return -EBADF;
    }
    if (!buf || count == 0) {
        return 0;
    }

    // Allocate data region and copy data
    uint32_t data_offset = alloc_data(count);
    void* dest = static_cast<char*>(shm_.data_region()) + data_offset;
    memcpy(dest, buf, count);

    // Submit write command
    uint32_t flags = static_cast<uint32_t>(handles_[fd].server_handle);
    uint32_t req_id = cmd_ring_.submit(CommandType::Write, nullptr, flags,
                                       data_offset, static_cast<uint32_t>(count));
    if (req_id == 0) {
        return -EAGAIN;
    }

    // Wait for response
    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    if (response.error != ErrorCode::Success) {
        return static_cast<ssize_t>(response.error);
    }

    ssize_t bytes_written = static_cast<ssize_t>(response.data_len);

    // Update position if not pwrite
    if (offset < 0) {
        handles_[fd].position += bytes_written;
    }

    shm_.control()->bytes_transferred.fetch_add(bytes_written, std::memory_order_relaxed);
    return bytes_written;
}

int SharedMemoryClient::stat(const char* path, FileMetadata* meta) {
    if (!path || !meta) {
        return -EINVAL;
    }

    // Allocate space for result
    uint32_t data_offset = alloc_data(sizeof(FileMetadata));

    uint32_t req_id = cmd_ring_.submit(CommandType::Stat, path, 0,
                                       data_offset, sizeof(FileMetadata));
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    if (response.error != ErrorCode::Success) {
        return static_cast<int>(response.error);
    }

    // Copy result
    void* src = static_cast<char*>(shm_.data_region()) + response.data_offset;
    memcpy(meta, src, sizeof(FileMetadata));

    return 0;
}

int SharedMemoryClient::fstat(int fd, FileMetadata* meta) {
    if (fd < 0 || fd >= 1024 || !handles_[fd].in_use) {
        return -EBADF;
    }

    // Use stored path for stat
    return stat(handles_[fd].path, meta);
}

int SharedMemoryClient::readdir(const char* path, DirEntry* entries,
                                 size_t max_entries, size_t* out_count) {
    if (!path || !entries || max_entries == 0) {
        return -EINVAL;
    }

    // Allocate space for results
    size_t result_size = max_entries * sizeof(DirEntry);
    uint32_t data_offset = alloc_data(result_size);

    uint32_t req_id = cmd_ring_.submit(CommandType::Readdir, path,
                                       static_cast<uint32_t>(max_entries),
                                       data_offset, static_cast<uint32_t>(result_size));
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    if (response.error != ErrorCode::Success) {
        return static_cast<int>(response.error);
    }

    // Copy entries
    size_t count = response.data_len / sizeof(DirEntry);
    if (count > max_entries) {
        count = max_entries;
    }

    void* src = static_cast<char*>(shm_.data_region()) + response.data_offset;
    memcpy(entries, src, count * sizeof(DirEntry));

    if (out_count) {
        *out_count = count;
    }

    return 0;
}

int SharedMemoryClient::mkdir(const char* path, uint32_t mode) {
    if (!path) {
        return -EINVAL;
    }

    uint32_t req_id = cmd_ring_.submit(CommandType::Mkdir, path, mode, 0, 0);
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    return response.error == ErrorCode::Success ? 0 : static_cast<int>(response.error);
}

int SharedMemoryClient::rmdir(const char* path) {
    if (!path) {
        return -EINVAL;
    }

    uint32_t req_id = cmd_ring_.submit(CommandType::Rmdir, path, 0, 0, 0);
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    return response.error == ErrorCode::Success ? 0 : static_cast<int>(response.error);
}

int SharedMemoryClient::unlink(const char* path) {
    if (!path) {
        return -EINVAL;
    }

    uint32_t req_id = cmd_ring_.submit(CommandType::Unlink, path, 0, 0, 0);
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    return response.error == ErrorCode::Success ? 0 : static_cast<int>(response.error);
}

int SharedMemoryClient::rename(const char* oldpath, const char* newpath) {
    if (!oldpath || !newpath) {
        return -EINVAL;
    }

    // For rename, we concatenate paths with null separator
    char combined[512];
    size_t old_len = strlen(oldpath);
    size_t new_len = strlen(newpath);

    if (old_len + new_len + 2 > sizeof(combined)) {
        return -ENAMETOOLONG;
    }

    memcpy(combined, oldpath, old_len + 1);
    memcpy(combined + old_len + 1, newpath, new_len + 1);

    uint32_t req_id = cmd_ring_.submit(CommandType::Rename, combined,
                                       static_cast<uint32_t>(old_len), 0,
                                       static_cast<uint32_t>(old_len + new_len + 2));
    if (req_id == 0) {
        return -EAGAIN;
    }

    ResponseEntry response;
    if (!rsp_ring_.wait_for(req_id, response)) {
        return -ETIMEDOUT;
    }

    return response.error == ErrorCode::Success ? 0 : static_cast<int>(response.error);
}

int SharedMemoryClient::batch_read(BatchReadRequest* requests, size_t count) {
    if (!requests || count == 0) {
        return -EINVAL;
    }

    // Submit all read requests
    std::vector<uint32_t> request_ids(count);
    std::vector<uint32_t> data_offsets(count);

    for (size_t i = 0; i < count; i++) {
        data_offsets[i] = alloc_data(requests[i].size);

        // For batch read, we pack info differently
        request_ids[i] = cmd_ring_.submit(CommandType::Read, requests[i].path, 0,
                                          data_offsets[i],
                                          static_cast<uint32_t>(requests[i].size));
        if (request_ids[i] == 0) {
            // Queue full, process what we have so far
            count = i;
            break;
        }
    }

    // Wait for all responses
    for (size_t i = 0; i < count; i++) {
        ResponseEntry response;
        if (rsp_ring_.wait_for(request_ids[i], response)) {
            if (response.error == ErrorCode::Success) {
                void* src = static_cast<char*>(shm_.data_region()) + response.data_offset;
                size_t bytes = std::min(static_cast<size_t>(response.data_len), requests[i].size);
                memcpy(requests[i].buffer, src, bytes);
                requests[i].result = static_cast<ssize_t>(bytes);
            } else {
                requests[i].result = static_cast<ssize_t>(response.error);
            }
        } else {
            requests[i].result = -ETIMEDOUT;
        }
    }

    return static_cast<int>(count);
}

int SharedMemoryClient::batch_stat(BatchStatRequest* requests, size_t count) {
    if (!requests || count == 0) {
        return -EINVAL;
    }

    std::vector<uint32_t> request_ids(count);
    std::vector<uint32_t> data_offsets(count);

    for (size_t i = 0; i < count; i++) {
        data_offsets[i] = alloc_data(sizeof(FileMetadata));
        request_ids[i] = cmd_ring_.submit(CommandType::Stat, requests[i].path, 0,
                                          data_offsets[i], sizeof(FileMetadata));
        if (request_ids[i] == 0) {
            count = i;
            break;
        }
    }

    for (size_t i = 0; i < count; i++) {
        ResponseEntry response;
        if (rsp_ring_.wait_for(request_ids[i], response)) {
            if (response.error == ErrorCode::Success) {
                void* src = static_cast<char*>(shm_.data_region()) + response.data_offset;
                memcpy(&requests[i].meta, src, sizeof(FileMetadata));
                requests[i].result = 0;
            } else {
                requests[i].result = static_cast<int>(response.error);
            }
        } else {
            requests[i].result = -ETIMEDOUT;
        }
    }

    return static_cast<int>(count);
}

void SharedMemoryClient::prefetch(const char** paths, size_t count) {
    if (!paths || count == 0) {
        return;
    }

    // Submit prefetch hints (non-blocking, no response expected)
    for (size_t i = 0; i < count; i++) {
        if (paths[i]) {
            cmd_ring_.submit(CommandType::Prefetch, paths[i], 0, 0, 0);
        }
    }

    // Don't wait for responses - this is a hint
}

} // namespace shm
} // namespace strix
