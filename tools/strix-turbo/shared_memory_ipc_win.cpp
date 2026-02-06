/**
 * Shared Memory IPC for WSL2 - Windows Server Implementation
 *
 * Provides the Windows (host) side of the shared memory IPC system.
 * Handles file operations on behalf of the Linux guest, translating
 * WSL /mnt/X paths to native Windows paths and serving data through
 * the shared memory region.
 *
 * Build: cl /O2 /std:c++17 shared_memory_ipc_win.cpp /link /out:shm_server.exe
 */

#ifdef _WIN32

#include "shared_memory_ipc.h"

#include <windows.h>
#include <cstring>
#include <cstdio>
#include <thread>
#include <chrono>

namespace strix {
namespace shm {

//==============================================================================
// Constants
//==============================================================================

// Sentinel value for an unused slot in the handle cache
static constexpr HANDLE INVALID_CACHED_HANDLE = INVALID_HANDLE_VALUE;

// Maximum number of cached file handles
static constexpr size_t MAX_CACHED_HANDLES = 256;

// Windows epoch offset: 100-nanosecond intervals between
// January 1, 1601 (Windows epoch) and January 1, 1970 (Unix epoch)
static constexpr uint64_t WINDOWS_EPOCH_OFFSET = 116444736000000000ULL;

//==============================================================================
// SharedMemoryRegion Implementation (Windows)
//==============================================================================

bool SharedMemoryRegion::create(const wchar_t* name, size_t size) {
    if (!name || size == 0) {
        return false;
    }

    // Create named file mapping backed by the system paging file
    DWORD size_high = static_cast<DWORD>(size >> 32);
    DWORD size_low = static_cast<DWORD>(size & 0xFFFFFFFF);

    mapping_ = CreateFileMappingW(
        INVALID_HANDLE_VALUE,   // Backed by paging file
        nullptr,                // Default security
        PAGE_READWRITE,         // Read/write access
        size_high,
        size_low,
        name);

    if (!mapping_) {
        return false;
    }

    base_ = MapViewOfFile(
        mapping_,
        FILE_MAP_ALL_ACCESS,
        0, 0,
        size);

    if (!base_) {
        CloseHandle(mapping_);
        mapping_ = nullptr;
        return false;
    }

    size_ = size;
    return true;
}

bool SharedMemoryRegion::open(const wchar_t* name) {
    if (!name) {
        return false;
    }

    mapping_ = OpenFileMappingW(
        FILE_MAP_ALL_ACCESS,
        FALSE,
        name);

    if (!mapping_) {
        return false;
    }

    base_ = MapViewOfFile(
        mapping_,
        FILE_MAP_ALL_ACCESS,
        0, 0,
        0);  // Map entire section

    if (!base_) {
        CloseHandle(mapping_);
        mapping_ = nullptr;
        return false;
    }

    // Determine size from control block if available
    auto* ctrl = reinterpret_cast<ControlBlock*>(base_);
    if (ctrl->magic == MAGIC_NUMBER) {
        size_ = static_cast<size_t>(ctrl->region_size);
    }

    return true;
}

//==============================================================================
// Utility Functions
//==============================================================================

/**
 * Convert Windows FILETIME (100-nanosecond intervals since 1601-01-01)
 * to nanoseconds since Unix epoch (1970-01-01).
 */
static uint64_t filetime_to_ns(FILETIME ft) {
    uint64_t ticks = (static_cast<uint64_t>(ft.dwHighDateTime) << 32) |
                     static_cast<uint64_t>(ft.dwLowDateTime);

    if (ticks < WINDOWS_EPOCH_OFFSET) {
        return 0;
    }

    // Convert from 100ns intervals to nanoseconds
    return (ticks - WINDOWS_EPOCH_OFFSET) * 100ULL;
}

/**
 * Map a Win32 error code to our ErrorCode enum.
 */
static ErrorCode map_win32_error(DWORD err) {
    switch (err) {
    case ERROR_FILE_NOT_FOUND:
    case ERROR_PATH_NOT_FOUND:
        return ErrorCode::NotFound;
    case ERROR_ACCESS_DENIED:
        return ErrorCode::PermissionDenied;
    case ERROR_ALREADY_EXISTS:
    case ERROR_FILE_EXISTS:
        return ErrorCode::Exists;
    case ERROR_DIRECTORY:
        return ErrorCode::NotDirectory;
    case ERROR_DIR_NOT_EMPTY:
        return ErrorCode::NotEmpty;
    case ERROR_INVALID_PARAMETER:
    case ERROR_INVALID_NAME:
    case ERROR_BAD_PATHNAME:
        return ErrorCode::InvalidArgument;
    case ERROR_TOO_MANY_OPEN_FILES:
        return ErrorCode::TooManyOpen;
    case ERROR_DISK_FULL:
    case ERROR_HANDLE_DISK_FULL:
        return ErrorCode::NoSpace;
    case ERROR_WRITE_PROTECT:
        return ErrorCode::ReadOnly;
    case ERROR_FILENAME_EXCED_RANGE:
    case ERROR_BUFFER_OVERFLOW:
        return ErrorCode::NameTooLong;
    case ERROR_SHARING_VIOLATION:
    case ERROR_LOCK_VIOLATION:
        return ErrorCode::PermissionDenied;
    default:
        return ErrorCode::Unknown;
    }
}

/**
 * Translate a WSL /mnt/X path to a Windows path with \\?\ prefix.
 *
 * Example: /mnt/c/Users/foo -> \\?\C:\Users\foo
 *          /mnt/d/data      -> \\?\D:\data
 *
 * Returns false if the path does not start with /mnt/.
 */
static bool translate_path(const char* wsl_path, wchar_t* win_path, size_t win_path_len) {
    if (!wsl_path || !win_path || win_path_len < 8) {
        return false;
    }

    // Must start with /mnt/
    if (strncmp(wsl_path, "/mnt/", 5) != 0) {
        return false;
    }

    // Extract drive letter
    char drive = wsl_path[5];
    if (drive == '\0' || (wsl_path[6] != '/' && wsl_path[6] != '\0')) {
        return false;
    }

    // Build \\?\X:\ prefix
    win_path[0] = L'\\';
    win_path[1] = L'\\';
    win_path[2] = L'?';
    win_path[3] = L'\\';

    // Drive letter uppercase
    if (drive >= 'a' && drive <= 'z') {
        win_path[4] = static_cast<wchar_t>(drive - 'a' + 'A');
    } else if (drive >= 'A' && drive <= 'Z') {
        win_path[4] = static_cast<wchar_t>(drive);
    } else {
        return false;
    }

    win_path[5] = L':';
    win_path[6] = L'\\';

    // Convert rest of path, replacing / with backslash
    const char* src = wsl_path + 6;  // Skip /mnt/X
    size_t dst_idx = 7;

    // If path is just /mnt/c, we already have \\?\C:\ which is correct
    if (*src == '/') {
        src++;  // Skip the / after drive letter
    }

    while (*src != '\0' && dst_idx < win_path_len - 1) {
        if (*src == '/') {
            win_path[dst_idx] = L'\\';
        } else {
            // Simple ASCII conversion for path characters
            win_path[dst_idx] = static_cast<wchar_t>(static_cast<unsigned char>(*src));
        }
        src++;
        dst_idx++;
    }

    // Remove trailing backslash unless it is the root
    if (dst_idx > 7 && win_path[dst_idx - 1] == L'\\') {
        dst_idx--;
    }

    win_path[dst_idx] = L'\0';
    return true;
}

//==============================================================================
// SharedMemoryServer Implementation
//==============================================================================

SharedMemoryServer::SharedMemoryServer(SharedMemoryRegion& shm)
    : shm_(shm)
    , cmd_ring_(shm)
    , rsp_ring_(shm)
    , running_(false) {

    // Initialize handle cache - mark all slots as free
    for (size_t i = 0; i < MAX_CACHED_HANDLES; i++) {
        handle_cache_[i].handle = INVALID_CACHED_HANDLE;
        handle_cache_[i].path[0] = L'\0';
        handle_cache_[i].last_access = {};
    }
}

bool SharedMemoryServer::initialize() {
    if (!shm_.is_mapped()) {
        return false;
    }

    ControlBlock* ctrl = shm_.control();
    if (!ctrl->is_valid()) {
        return false;
    }

    // Signal that the Windows server is ready
    ctrl->windows_ready.store(1, std::memory_order_release);
    return true;
}

uint32_t SharedMemoryServer::process(uint32_t max_commands) {
    uint32_t count = 0;

    while (max_commands == 0 || count < max_commands) {
        CommandEntry cmd;
        char path[512];
        path[0] = '\0';

        if (!cmd_ring_.consume(cmd, path, sizeof(path))) {
            break;  // No more commands
        }

        switch (cmd.type) {
        case CommandType::Open:
            handle_open(cmd, path);
            break;
        case CommandType::Close:
            handle_close(cmd);
            break;
        case CommandType::Read:
            handle_read(cmd);
            break;
        case CommandType::Write:
            handle_write(cmd);
            break;
        case CommandType::Stat:
            handle_stat(cmd, path);
            break;
        case CommandType::Readdir:
            handle_readdir(cmd, path);
            break;
        case CommandType::Mkdir: {
            wchar_t win_path[MAX_PATH];
            if (!translate_path(path, win_path, MAX_PATH)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
            } else if (CreateDirectoryW(win_path, nullptr)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::Rmdir: {
            wchar_t win_path[MAX_PATH];
            if (!translate_path(path, win_path, MAX_PATH)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
            } else if (RemoveDirectoryW(win_path)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::Unlink: {
            wchar_t win_path[MAX_PATH];
            if (!translate_path(path, win_path, MAX_PATH)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
            } else if (DeleteFileW(win_path)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::Rename: {
            // Path contains old\0new (null-separated)
            const char* old_path = path;
            size_t old_len = strlen(old_path);
            const char* new_path = path + old_len + 1;

            wchar_t win_old[MAX_PATH];
            wchar_t win_new[MAX_PATH];
            if (!translate_path(old_path, win_old, MAX_PATH) ||
                !translate_path(new_path, win_new, MAX_PATH)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
            } else if (MoveFileExW(win_old, win_new, MOVEFILE_REPLACE_EXISTING)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::Truncate: {
            wchar_t win_path[MAX_PATH];
            if (!translate_path(path, win_path, MAX_PATH)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
                break;
            }

            HANDLE hFile = CreateFileW(
                win_path,
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                nullptr,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                nullptr);

            if (hFile == INVALID_HANDLE_VALUE) {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
                break;
            }

            LARGE_INTEGER li;
            li.QuadPart = static_cast<LONGLONG>(cmd.file_offset);
            BOOL ok = SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN);
            if (ok) {
                ok = SetEndOfFile(hFile);
            }

            CloseHandle(hFile);

            if (ok) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::Fsync: {
            if (cmd.handle >= MAX_CACHED_HANDLES ||
                handle_cache_[cmd.handle].handle == INVALID_CACHED_HANDLE) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
                break;
            }

            if (FlushFileBuffers(handle_cache_[cmd.handle].handle)) {
                rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            }
            break;
        }
        case CommandType::BatchRead:
            handle_batch_read(cmd);
            break;
        case CommandType::Prefetch:
            handle_prefetch(cmd);
            break;
        case CommandType::Ping:
            rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            break;
        case CommandType::Shutdown: {
            ControlBlock* ctrl = shm_.control();
            ctrl->shutdown.store(1, std::memory_order_release);
            rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
            running_.store(false, std::memory_order_release);
            break;
        }
        default:
            // Unknown command type
            rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
            break;
        }

        count++;
        shm_.control()->commands_processed.fetch_add(1, std::memory_order_relaxed);
    }

    return count;
}

void SharedMemoryServer::run() {
    running_.store(true, std::memory_order_release);

    ControlBlock* ctrl = shm_.control();
    uint32_t idle_spins = 0;

    while (running_.load(std::memory_order_acquire)) {
        // Check for external shutdown request
        if (ctrl->shutdown.load(std::memory_order_acquire)) {
            break;
        }

        uint32_t processed = process(0);

        if (processed > 0) {
            idle_spins = 0;
        } else {
            idle_spins++;

            if (idle_spins < 100) {
                // Busy spin for first 100 idle iterations (lowest latency)
                // Compiler barrier to prevent the loop from being optimized out
                _ReadWriteBarrier();
            } else if (idle_spins < 1000) {
                // Short sleep: 50 microseconds
                std::this_thread::sleep_for(std::chrono::microseconds(50));
            } else {
                // Longer sleep: 1 millisecond (save CPU when truly idle)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }

    running_.store(false, std::memory_order_release);
}

void SharedMemoryServer::shutdown() {
    running_.store(false, std::memory_order_release);

    ControlBlock* ctrl = shm_.control();
    ctrl->shutdown.store(1, std::memory_order_release);

    // Close all cached handles
    for (size_t i = 0; i < MAX_CACHED_HANDLES; i++) {
        if (handle_cache_[i].handle != INVALID_CACHED_HANDLE) {
            CloseHandle(handle_cache_[i].handle);
            handle_cache_[i].handle = INVALID_CACHED_HANDLE;
            handle_cache_[i].path[0] = L'\0';
        }
    }
}

//==============================================================================
// Command Handlers
//==============================================================================

void SharedMemoryServer::handle_open(const CommandEntry& cmd, const char* path) {
    wchar_t win_path[MAX_PATH];
    if (!translate_path(path, win_path, MAX_PATH)) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    // Convert OpenFlags to Win32 access flags
    uint32_t flags = cmd.flags;
    DWORD desired_access = 0;
    uint32_t access_mode = flags & 0x03;  // Lower 2 bits: RDONLY/WRONLY/RDWR

    if (access_mode == OpenFlags::RDONLY) {
        desired_access = GENERIC_READ;
    } else if (access_mode == OpenFlags::WRONLY) {
        desired_access = GENERIC_WRITE;
    } else if (access_mode == OpenFlags::RDWR) {
        desired_access = GENERIC_READ | GENERIC_WRITE;
    } else {
        desired_access = GENERIC_READ;
    }

    // Convert creation disposition
    DWORD creation_disposition = OPEN_EXISTING;
    bool has_creat = (flags & OpenFlags::CREAT) != 0;
    bool has_excl  = (flags & OpenFlags::EXCL) != 0;
    bool has_trunc = (flags & OpenFlags::TRUNC) != 0;

    if (has_creat && has_excl) {
        creation_disposition = CREATE_NEW;
    } else if (has_creat && has_trunc) {
        creation_disposition = CREATE_ALWAYS;
    } else if (has_creat) {
        creation_disposition = OPEN_ALWAYS;
    } else if (has_trunc) {
        creation_disposition = TRUNCATE_EXISTING;
    }

    // File attributes and flags
    DWORD file_flags = FILE_ATTRIBUTE_NORMAL;
    bool is_directory = (flags & OpenFlags::DIRECTORY) != 0;
    if (is_directory) {
        file_flags = FILE_FLAG_BACKUP_SEMANTICS;
    }

    HANDLE hFile = CreateFileW(
        win_path,
        desired_access,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        creation_disposition,
        file_flags,
        nullptr);

    if (hFile == INVALID_HANDLE_VALUE) {
        rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
        return;
    }

    // If APPEND mode, seek to end
    if (flags & OpenFlags::APPEND) {
        LARGE_INTEGER li;
        li.QuadPart = 0;
        SetFilePointerEx(hFile, li, nullptr, FILE_END);
    }

    // Find a free slot in the handle cache
    uint32_t slot = UINT32_MAX;
    for (uint32_t i = 0; i < MAX_CACHED_HANDLES; i++) {
        if (handle_cache_[i].handle == INVALID_CACHED_HANDLE) {
            slot = i;
            break;
        }
    }

    if (slot == UINT32_MAX) {
        // No free slots - close the handle and report error
        CloseHandle(hFile);
        rsp_ring_.submit(cmd.request_id, ErrorCode::TooManyOpen, 0, 0);
        return;
    }

    // Store in cache
    handle_cache_[slot].handle = hFile;
    wcsncpy(handle_cache_[slot].path, win_path, MAX_PATH - 1);
    handle_cache_[slot].path[MAX_PATH - 1] = L'\0';
    GetSystemTimeAsFileTime(&handle_cache_[slot].last_access);

    // Return the slot index as data_offset so the client can reference it
    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, slot, 0);
}

void SharedMemoryServer::handle_close(const CommandEntry& cmd) {
    uint32_t slot = cmd.handle;

    if (slot >= MAX_CACHED_HANDLES ||
        handle_cache_[slot].handle == INVALID_CACHED_HANDLE) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    CloseHandle(handle_cache_[slot].handle);
    handle_cache_[slot].handle = INVALID_CACHED_HANDLE;
    handle_cache_[slot].path[0] = L'\0';

    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
}

void SharedMemoryServer::handle_read(const CommandEntry& cmd) {
    uint32_t slot = cmd.handle;

    if (slot >= MAX_CACHED_HANDLES ||
        handle_cache_[slot].handle == INVALID_CACHED_HANDLE) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    HANDLE hFile = handle_cache_[slot].handle;

    // Seek if a specific offset was requested
    if (cmd.file_offset != UINT64_MAX) {
        LARGE_INTEGER li;
        li.QuadPart = static_cast<LONGLONG>(cmd.file_offset);
        if (!SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN)) {
            rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            return;
        }
    }

    // Read into the data region at the specified offset
    char* data_base = static_cast<char*>(shm_.data_region());
    char* dest = data_base + cmd.data_offset;

    DWORD bytes_read = 0;
    BOOL ok = ReadFile(hFile, dest, cmd.data_len, &bytes_read, nullptr);

    if (!ok && GetLastError() != ERROR_HANDLE_EOF) {
        rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
        return;
    }

    // Update access time
    GetSystemTimeAsFileTime(&handle_cache_[slot].last_access);

    // Update bytes transferred statistic
    shm_.control()->bytes_transferred.fetch_add(bytes_read, std::memory_order_relaxed);

    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, cmd.data_offset, bytes_read);
}

void SharedMemoryServer::handle_write(const CommandEntry& cmd) {
    uint32_t slot = cmd.handle;

    if (slot >= MAX_CACHED_HANDLES ||
        handle_cache_[slot].handle == INVALID_CACHED_HANDLE) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    HANDLE hFile = handle_cache_[slot].handle;

    // Seek if a specific offset was requested
    if (cmd.file_offset != UINT64_MAX) {
        LARGE_INTEGER li;
        li.QuadPart = static_cast<LONGLONG>(cmd.file_offset);
        if (!SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN)) {
            rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
            return;
        }
    }

    // Write from the data region at the specified offset
    const char* data_base = static_cast<const char*>(shm_.data_region());
    const char* src = data_base + cmd.data_offset;

    DWORD bytes_written = 0;
    BOOL ok = WriteFile(hFile, src, cmd.data_len, &bytes_written, nullptr);

    if (!ok) {
        rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
        return;
    }

    // Update access time
    GetSystemTimeAsFileTime(&handle_cache_[slot].last_access);

    // Update bytes transferred statistic
    shm_.control()->bytes_transferred.fetch_add(bytes_written, std::memory_order_relaxed);

    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, cmd.data_offset, bytes_written);
}

void SharedMemoryServer::handle_stat(const CommandEntry& cmd, const char* path) {
    wchar_t win_path[MAX_PATH];
    if (!translate_path(path, win_path, MAX_PATH)) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    WIN32_FILE_ATTRIBUTE_DATA attr_data;
    if (!GetFileAttributesExW(win_path, GetFileExInfoStandard, &attr_data)) {
        rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
        return;
    }

    // Build FileMetadata in the data region
    char* data_base = static_cast<char*>(shm_.data_region());
    auto* meta = reinterpret_cast<FileMetadata*>(data_base + cmd.data_offset);

    meta->size = (static_cast<uint64_t>(attr_data.nFileSizeHigh) << 32) |
                 static_cast<uint64_t>(attr_data.nFileSizeLow);

    meta->mtime_ns = filetime_to_ns(attr_data.ftLastWriteTime);
    meta->atime_ns = filetime_to_ns(attr_data.ftLastAccessTime);
    meta->ctime_ns = filetime_to_ns(attr_data.ftCreationTime);

    // Derive Unix-like mode from Windows attributes
    uint32_t mode = 0;
    if (attr_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        mode = 0040755;  // drwxr-xr-x
    } else if (attr_data.dwFileAttributes & FILE_ATTRIBUTE_READONLY) {
        mode = 0100444;  // -r--r--r--
    } else {
        mode = 0100644;  // -rw-r--r--
    }

    // Mark executables based on common extensions (heuristic)
    // A full implementation would check file content or extension mapping
    if (!(attr_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        size_t path_len = wcslen(win_path);
        if (path_len >= 4) {
            const wchar_t* ext = win_path + path_len - 4;
            if (_wcsicmp(ext, L".exe") == 0 ||
                _wcsicmp(ext, L".bat") == 0 ||
                _wcsicmp(ext, L".cmd") == 0 ||
                _wcsicmp(ext, L".com") == 0) {
                mode = 0100755;  // -rwxr-xr-x
            }
        }
    }

    meta->mode = mode;
    meta->uid = 1000;   // Default WSL uid
    meta->gid = 1000;   // Default WSL gid
    meta->nlink = 1;
    meta->inode = 0;    // Windows does not expose a stable inode
    meta->dev = 0;
    meta->_pad = 0;

    rsp_ring_.submit(cmd.request_id, ErrorCode::Success,
                     cmd.data_offset, static_cast<uint32_t>(sizeof(FileMetadata)));
}

void SharedMemoryServer::handle_readdir(const CommandEntry& cmd, const char* path) {
    wchar_t win_path[MAX_PATH];
    if (!translate_path(path, win_path, MAX_PATH)) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
        return;
    }

    // Append \* for FindFirstFile wildcard search
    size_t len = wcslen(win_path);
    if (len + 3 >= MAX_PATH) {
        rsp_ring_.submit(cmd.request_id, ErrorCode::NameTooLong, 0, 0);
        return;
    }
    win_path[len] = L'\\';
    win_path[len + 1] = L'*';
    win_path[len + 2] = L'\0';

    WIN32_FIND_DATAW find_data;
    HANDLE hFind = FindFirstFileW(win_path, &find_data);
    if (hFind == INVALID_HANDLE_VALUE) {
        rsp_ring_.submit(cmd.request_id, map_win32_error(GetLastError()), 0, 0);
        return;
    }

    char* data_base = static_cast<char*>(shm_.data_region());
    auto* entries = reinterpret_cast<DirEntry*>(data_base + cmd.data_offset);

    // Calculate maximum entries that fit in the allocated data region
    uint32_t max_entries = cmd.data_len / static_cast<uint32_t>(sizeof(DirEntry));
    uint32_t count = 0;

    do {
        if (count >= max_entries) {
            break;
        }

        DirEntry& entry = entries[count];
        memset(&entry, 0, sizeof(DirEntry));

        // Convert wide filename to narrow (ASCII subset)
        size_t name_len = 0;
        for (size_t i = 0; i < 251 && find_data.cFileName[i] != L'\0'; i++) {
            entry.name[i] = static_cast<char>(find_data.cFileName[i] & 0x7F);
            name_len++;
        }
        entry.name[name_len] = '\0';
        entry.name_len = static_cast<uint16_t>(name_len);

        // Set type: DT_DIR=4, DT_REG=8
        if (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            entry.type = 4;  // DT_DIR
        } else {
            entry.type = 8;  // DT_REG
        }

        entry.inode = 0;  // No stable inode on Windows

        count++;
    } while (FindNextFileW(hFind, &find_data));

    FindClose(hFind);

    uint32_t result_len = count * static_cast<uint32_t>(sizeof(DirEntry));
    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, cmd.data_offset, result_len);
}

void SharedMemoryServer::handle_batch_read(const CommandEntry& cmd) {
    // Batch read is not yet implemented. Return an error to the client
    // so it can fall back to individual read operations.
    rsp_ring_.submit(cmd.request_id, ErrorCode::InvalidArgument, 0, 0);
}

void SharedMemoryServer::handle_prefetch(const CommandEntry& cmd) {
    // Prefetch is a hint only. Acknowledge success without doing work.
    // A future implementation could use ReadFileScatter or preload file
    // metadata into the handle cache to accelerate subsequent accesses.
    rsp_ring_.submit(cmd.request_id, ErrorCode::Success, 0, 0);
}

} // namespace shm
} // namespace strix

#endif // _WIN32
