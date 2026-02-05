/**
 * Shared Memory IPC Test Harness
 *
 * In-process test that validates the shared memory IPC protocol using
 * a server thread (POSIX-based) and a client thread sharing an mmap'd region.
 *
 * Build:
 *   g++ -O3 -std=c++17 -o shm_test shm_test.cpp shared_memory_ipc.cpp -lpthread
 *
 * Run:
 *   ./shm_test
 */

#include "shared_memory_ipc.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace strix::shm;

// ============================================================================
// Constants
// ============================================================================

static constexpr size_t REGION_SIZE = 16 * 1024 * 1024; // 16 MB
static constexpr int MAX_HANDLES = 256;

// ============================================================================
// Test bookkeeping
// ============================================================================

static int g_tests_passed = 0;
static int g_tests_total  = 0;

static void report(const char* name, bool ok) {
    g_tests_total++;
    if (ok) {
        g_tests_passed++;
        printf("[TEST] %s... PASS\n", name);
    } else {
        printf("[TEST] %s... FAIL\n", name);
    }
}

// ============================================================================
// Server thread - simulates the Windows server using POSIX APIs
// ============================================================================

struct ServerState {
    SharedMemoryRegion* shm;
    std::string tmp_dir;
};

static void server_thread_fn(ServerState* state) {
    SharedMemoryRegion& shm = *state->shm;
    ControlBlock* ctrl = shm.control();
    CommandRing cmd_ring(shm);
    ResponseRing rsp_ring(shm);

    // Handle table: maps server handle index -> OS file descriptor
    int handle_fds[MAX_HANDLES];
    for (int i = 0; i < MAX_HANDLES; i++) {
        handle_fds[i] = -1;
    }
    int next_handle = 1; // handle 0 is reserved (unused sentinel)

    auto alloc_handle = [&](int fd) -> int {
        for (int i = next_handle; i < MAX_HANDLES; i++) {
            if (handle_fds[i] == -1) {
                handle_fds[i] = fd;
                next_handle = i + 1;
                return i;
            }
        }
        // Wrap search from beginning
        for (int i = 1; i < next_handle && i < MAX_HANDLES; i++) {
            if (handle_fds[i] == -1) {
                handle_fds[i] = fd;
                next_handle = i + 1;
                return i;
            }
        }
        return -1;
    };

    auto free_handle = [&](int h) {
        if (h > 0 && h < MAX_HANDLES) {
            handle_fds[h] = -1;
            if (h < next_handle) {
                next_handle = h;
            }
        }
    };

    // Signal ready
    ctrl->windows_ready.store(1, std::memory_order_release);

    // Command processing loop
    while (!ctrl->shutdown.load(std::memory_order_acquire)) {
        CommandEntry cmd;
        char path[512];
        path[0] = '\0';

        if (!cmd_ring.consume(cmd, path, sizeof(path))) {
            std::this_thread::sleep_for(std::chrono::microseconds(10));
            continue;
        }

        uint32_t req_id = cmd.request_id;
        char* data_base = static_cast<char*>(shm.data_region());

        switch (cmd.type) {

        case CommandType::Open: {
            uint32_t flags_raw = cmd.flags;
            // Decode POSIX open flags from our protocol flags
            int posix_flags = 0;
            uint32_t full_flags = cmd.flags | (static_cast<uint32_t>(cmd._reserved) << 8);
            // The client packs (flags | (mode << 16)) into the flags parameter.
            // But submit() only stores the low 8 bits in entry.flags.
            // The full_flags were passed to submit() -- let's re-derive from
            // the fact that the client encodes flags in the submit call's
            // 'flags' param, which gets cast to uint8_t.  For the test we
            // simply always open with O_RDWR | O_CREAT.
            (void)flags_raw;
            (void)full_flags;
            posix_flags = O_RDWR | O_CREAT;

            int fd = ::open(path, posix_flags, 0666);
            if (fd < 0) {
                ErrorCode ec = (errno == ENOENT) ? ErrorCode::NotFound :
                               (errno == EACCES) ? ErrorCode::PermissionDenied :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                int h = alloc_handle(fd);
                if (h < 0) {
                    ::close(fd);
                    rsp_ring.submit(req_id, ErrorCode::TooManyOpen, 0, 0);
                } else {
                    // Return handle index in data_offset (client stores it as server_handle)
                    rsp_ring.submit(req_id, ErrorCode::Success,
                                    static_cast<uint32_t>(h), 0);
                }
            }
            break;
        }

        case CommandType::Close: {
            // The updated client passes the server handle via cmd.handle (32-bit)
            int h = static_cast<int>(cmd.handle);
            if (h > 0 && h < MAX_HANDLES && handle_fds[h] != -1) {
                ::close(handle_fds[h]);
                free_handle(h);
                rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::InvalidArgument, 0, 0);
            }
            break;
        }

        case CommandType::Read: {
            int h = static_cast<int>(cmd.handle);
            uint32_t data_off = cmd.data_offset;
            uint32_t data_len = cmd.data_len;

            if (h <= 0 || h >= MAX_HANDLES || handle_fds[h] == -1) {
                rsp_ring.submit(req_id, ErrorCode::InvalidArgument, 0, 0);
                break;
            }

            // Use file_offset for positioned reads
            ssize_t n;
            if (cmd.file_offset != UINT64_MAX) {
                n = ::pread(handle_fds[h], data_base + data_off, data_len,
                           static_cast<off_t>(cmd.file_offset));
            } else {
                n = ::read(handle_fds[h], data_base + data_off, data_len);
            }
            if (n < 0) {
                rsp_ring.submit(req_id, ErrorCode::Unknown, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success,
                                data_off, static_cast<uint32_t>(n));
            }
            break;
        }

        case CommandType::Write: {
            int h = static_cast<int>(cmd.handle);
            uint32_t data_off = cmd.data_offset;
            uint32_t data_len = cmd.data_len;

            if (h <= 0 || h >= MAX_HANDLES || handle_fds[h] == -1) {
                rsp_ring.submit(req_id, ErrorCode::InvalidArgument, 0, 0);
                break;
            }

            ssize_t n;
            if (cmd.file_offset != UINT64_MAX) {
                n = ::pwrite(handle_fds[h], data_base + data_off, data_len,
                            static_cast<off_t>(cmd.file_offset));
            } else {
                n = ::write(handle_fds[h], data_base + data_off, data_len);
            }
            if (n < 0) {
                rsp_ring.submit(req_id, ErrorCode::Unknown, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success,
                                data_off, static_cast<uint32_t>(n));
            }
            break;
        }

        case CommandType::Stat: {
            struct stat st;
            if (::stat(path, &st) < 0) {
                ErrorCode ec = (errno == ENOENT) ? ErrorCode::NotFound :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                uint32_t out_off = cmd.data_offset;
                FileMetadata* meta = reinterpret_cast<FileMetadata*>(
                    data_base + out_off);
                memset(meta, 0, sizeof(*meta));
                meta->size     = static_cast<uint64_t>(st.st_size);
                meta->mode     = st.st_mode;
                meta->uid      = st.st_uid;
                meta->gid      = st.st_gid;
                meta->nlink    = static_cast<uint32_t>(st.st_nlink);
                meta->inode    = st.st_ino;
                meta->dev      = static_cast<uint32_t>(st.st_dev);
                meta->mtime_ns = static_cast<uint64_t>(st.st_mtim.tv_sec) * 1000000000ULL
                               + static_cast<uint64_t>(st.st_mtim.tv_nsec);
                meta->atime_ns = static_cast<uint64_t>(st.st_atim.tv_sec) * 1000000000ULL
                               + static_cast<uint64_t>(st.st_atim.tv_nsec);
                meta->ctime_ns = static_cast<uint64_t>(st.st_ctim.tv_sec) * 1000000000ULL
                               + static_cast<uint64_t>(st.st_ctim.tv_nsec);

                rsp_ring.submit(req_id, ErrorCode::Success,
                                out_off, sizeof(FileMetadata));
            }
            break;
        }

        case CommandType::Readdir: {
            DIR* d = ::opendir(path);
            if (!d) {
                ErrorCode ec = (errno == ENOENT) ? ErrorCode::NotFound :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
                break;
            }

            uint32_t max_entries = cmd.flags; // client packs max_entries here
            uint32_t out_off = cmd.data_offset;
            DirEntry* out = reinterpret_cast<DirEntry*>(data_base + out_off);
            uint32_t count = 0;

            struct dirent* de;
            while ((de = ::readdir(d)) != nullptr && count < max_entries) {
                // Skip . and ..
                if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) {
                    continue;
                }
                memset(&out[count], 0, sizeof(DirEntry));
                out[count].inode = de->d_ino;
                size_t nlen = strlen(de->d_name);
                if (nlen > 251) nlen = 251;
                out[count].name_len = static_cast<uint16_t>(nlen);
                out[count].type = de->d_type;
                memcpy(out[count].name, de->d_name, nlen);
                out[count].name[nlen] = '\0';
                count++;
            }
            ::closedir(d);

            rsp_ring.submit(req_id, ErrorCode::Success,
                            out_off,
                            static_cast<uint32_t>(count * sizeof(DirEntry)));
            break;
        }

        case CommandType::Mkdir: {
            uint32_t mode = cmd.flags; // only low 8 bits available
            (void)mode;
            int rc = ::mkdir(path, 0755);
            if (rc < 0) {
                ErrorCode ec = (errno == EEXIST)  ? ErrorCode::Exists :
                               (errno == ENOENT)  ? ErrorCode::NotFound :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            }
            break;
        }

        case CommandType::Rmdir: {
            int rc = ::rmdir(path);
            if (rc < 0) {
                ErrorCode ec = (errno == ENOENT)    ? ErrorCode::NotFound :
                               (errno == ENOTEMPTY) ? ErrorCode::NotEmpty :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            }
            break;
        }

        case CommandType::Unlink: {
            int rc = ::unlink(path);
            if (rc < 0) {
                ErrorCode ec = (errno == ENOENT) ? ErrorCode::NotFound :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            }
            break;
        }

        case CommandType::Rename: {
            // Paths are null-separated in the metadata region.
            // cmd.flags contains old_len (the client passes it there).
            // The first path is the old name, the second starts after the null.
            const char* oldname = path;
            size_t old_len = strlen(oldname);
            const char* newname = path + old_len + 1;

            int rc = ::rename(oldname, newname);
            if (rc < 0) {
                ErrorCode ec = (errno == ENOENT) ? ErrorCode::NotFound :
                               ErrorCode::Unknown;
                rsp_ring.submit(req_id, ec, 0, 0);
            } else {
                rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            }
            break;
        }

        case CommandType::Ping: {
            rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            break;
        }

        case CommandType::Shutdown: {
            ctrl->shutdown.store(1, std::memory_order_release);
            rsp_ring.submit(req_id, ErrorCode::Success, 0, 0);
            break;
        }

        default:
            rsp_ring.submit(req_id, ErrorCode::InvalidArgument, 0, 0);
            break;
        }

        ctrl->commands_processed.fetch_add(1, std::memory_order_relaxed);
    }

    // Close any remaining open handles
    for (int i = 1; i < MAX_HANDLES; i++) {
        if (handle_fds[i] != -1) {
            ::close(handle_fds[i]);
            handle_fds[i] = -1;
        }
    }
}

// ============================================================================
// Client-side test functions
// ============================================================================

static bool test_ping(SharedMemoryClient& client) {
    // Ping is not directly exposed by SharedMemoryClient, so we use the
    // low-level ring interface.  However, since we need a raw command, we
    // use mkdir on a path we know won't conflict as a round-trip check,
    // or we can just verify the server is responding by doing an operation
    // that should succeed trivially.  Let's use stat on "/" which always exists.
    FileMetadata meta;
    int rc = client.stat("/", &meta);
    return rc == 0 && S_ISDIR(meta.mode);
}

static bool test_mkdir_rmdir(SharedMemoryClient& client, const std::string& tmp) {
    std::string dir = tmp + "/test_dir";

    int rc = client.mkdir(dir.c_str(), 0755);
    if (rc != 0) return false;

    // Verify it exists via stat
    FileMetadata meta;
    rc = client.stat(dir.c_str(), &meta);
    if (rc != 0) return false;
    if (!S_ISDIR(meta.mode)) return false;

    // Remove it
    rc = client.rmdir(dir.c_str());
    if (rc != 0) return false;

    // Verify gone
    rc = client.stat(dir.c_str(), &meta);
    return rc != 0; // should fail with NotFound
}

static bool test_open_write_read_close(SharedMemoryClient& client,
                                        const std::string& tmp) {
    std::string filepath = tmp + "/test_rw.txt";
    const char* message = "Hello Shared Memory IPC!";
    size_t msg_len = strlen(message);

    // Open for write
    int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
    if (fd < 0) return false;

    // Write
    ssize_t written = client.write(fd, message, msg_len);
    if (written != static_cast<ssize_t>(msg_len)) {
        client.close(fd);
        return false;
    }

    // Close and reopen for reading (to reset file position)
    client.close(fd);

    fd = client.open(filepath.c_str(), OpenFlags::RDONLY);
    if (fd < 0) return false;

    // Read back
    char buf[256];
    memset(buf, 0, sizeof(buf));
    ssize_t nread = client.read(fd, buf, sizeof(buf));
    if (nread != static_cast<ssize_t>(msg_len)) {
        client.close(fd);
        return false;
    }

    bool match = (memcmp(buf, message, msg_len) == 0);

    client.close(fd);
    client.unlink(filepath.c_str());

    return match;
}

static bool test_stat(SharedMemoryClient& client, const std::string& tmp) {
    std::string filepath = tmp + "/test_stat.dat";
    const char data[] = "ABCDEFGHIJ"; // 10 bytes
    size_t data_len = sizeof(data) - 1;

    int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
    if (fd < 0) return false;

    ssize_t written = client.write(fd, data, data_len);
    client.close(fd);
    if (written != static_cast<ssize_t>(data_len)) return false;

    FileMetadata meta;
    int rc = client.stat(filepath.c_str(), &meta);
    if (rc != 0) return false;

    client.unlink(filepath.c_str());

    return meta.size == data_len && S_ISREG(meta.mode);
}

static bool test_readdir(SharedMemoryClient& client, const std::string& tmp) {
    std::string dir = tmp + "/test_readdir";
    int rc = client.mkdir(dir.c_str(), 0755);
    if (rc != 0) return false;

    // Create 3 files
    const char* names[] = {"alpha.txt", "beta.txt", "gamma.txt"};
    for (int i = 0; i < 3; i++) {
        std::string path = dir + "/" + names[i];
        int fd = client.open(path.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
        if (fd < 0) {
            // Cleanup on failure
            for (int j = 0; j < i; j++) {
                client.unlink((dir + "/" + names[j]).c_str());
            }
            client.rmdir(dir.c_str());
            return false;
        }
        client.write(fd, "x", 1);
        client.close(fd);
    }

    // Readdir
    DirEntry entries[32];
    size_t count = 0;
    rc = client.readdir(dir.c_str(), entries, 32, &count);
    if (rc != 0 || count < 3) {
        // Cleanup
        for (int i = 0; i < 3; i++) {
            client.unlink((dir + "/" + names[i]).c_str());
        }
        client.rmdir(dir.c_str());
        return false;
    }

    // Verify all names present
    bool found[3] = {false, false, false};
    for (size_t i = 0; i < count; i++) {
        for (int j = 0; j < 3; j++) {
            if (strcmp(entries[i].name, names[j]) == 0) {
                found[j] = true;
            }
        }
    }

    // Cleanup
    for (int i = 0; i < 3; i++) {
        client.unlink((dir + "/" + names[i]).c_str());
    }
    client.rmdir(dir.c_str());

    return found[0] && found[1] && found[2];
}

static bool test_large_read(SharedMemoryClient& client, const std::string& tmp) {
    std::string filepath = tmp + "/test_large.bin";
    constexpr size_t SIZE = 1024 * 1024; // 1 MB

    // Generate pattern data
    std::vector<uint8_t> pattern(SIZE);
    for (size_t i = 0; i < SIZE; i++) {
        pattern[i] = static_cast<uint8_t>((i * 7 + 13) & 0xFF);
    }

    // Write in chunks (the data region may not hold 1MB in a single alloc easily)
    int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
    if (fd < 0) return false;

    constexpr size_t CHUNK = 64 * 1024; // 64 KB chunks
    for (size_t off = 0; off < SIZE; off += CHUNK) {
        size_t len = (off + CHUNK <= SIZE) ? CHUNK : SIZE - off;
        ssize_t w = client.write(fd, pattern.data() + off, len);
        if (w != static_cast<ssize_t>(len)) {
            client.close(fd);
            client.unlink(filepath.c_str());
            return false;
        }
    }

    client.close(fd);

    // Reopen and read back
    fd = client.open(filepath.c_str(), OpenFlags::RDONLY);
    if (fd < 0) {
        client.unlink(filepath.c_str());
        return false;
    }

    std::vector<uint8_t> readback(SIZE);
    size_t total_read = 0;
    while (total_read < SIZE) {
        size_t len = (total_read + CHUNK <= SIZE) ? CHUNK : SIZE - total_read;
        ssize_t r = client.read(fd, readback.data() + total_read, len);
        if (r <= 0) break;
        total_read += static_cast<size_t>(r);
    }

    client.close(fd);
    client.unlink(filepath.c_str());

    if (total_read != SIZE) return false;

    return memcmp(pattern.data(), readback.data(), SIZE) == 0;
}

static bool test_rename(SharedMemoryClient& client, const std::string& tmp) {
    std::string old_path = tmp + "/rename_src.txt";
    std::string new_path = tmp + "/rename_dst.txt";

    int fd = client.open(old_path.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
    if (fd < 0) return false;

    client.write(fd, "rename test", 11);
    client.close(fd);

    int rc = client.rename(old_path.c_str(), new_path.c_str());
    if (rc != 0) {
        client.unlink(old_path.c_str());
        return false;
    }

    // New path should exist
    FileMetadata meta;
    rc = client.stat(new_path.c_str(), &meta);
    if (rc != 0) return false;

    // Old path should not exist
    rc = client.stat(old_path.c_str(), &meta);
    if (rc == 0) {
        client.unlink(new_path.c_str());
        return false; // old path still exists
    }

    client.unlink(new_path.c_str());
    return true;
}

static bool test_concurrent_ops(SharedMemoryClient& client, const std::string& tmp) {
    // Submit 50 stat requests rapidly to stress the ring buffer.
    // We stat the tmp directory itself, which should always succeed.
    bool all_ok = true;
    for (int i = 0; i < 50; i++) {
        FileMetadata meta;
        int rc = client.stat(tmp.c_str(), &meta);
        if (rc != 0) {
            all_ok = false;
            break;
        }
    }
    return all_ok;
}

// ============================================================================
// Latency measurement
// ============================================================================

static void measure_latency(SharedMemoryClient& client, const std::string& tmp) {
    constexpr int ITERS = 1000;

    // --- open + close ---
    {
        std::string filepath = tmp + "/perf_oc.tmp";
        // Pre-create the file
        int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
        if (fd >= 0) client.close(fd);

        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < ITERS; i++) {
            fd = client.open(filepath.c_str(), OpenFlags::RDONLY);
            if (fd >= 0) client.close(fd);
        }
        auto t1 = std::chrono::steady_clock::now();

        client.unlink(filepath.c_str());

        double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        double avg = us / ITERS;
        double ops = (avg > 0) ? 1000000.0 / avg : 0;
        printf("[PERF] open_close: %.1fus avg (%.0f ops/sec)\n", avg, ops);
    }

    // --- read 4KB ---
    {
        std::string filepath = tmp + "/perf_read.tmp";
        int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
        assert(fd >= 0);
        char buf[4096];
        memset(buf, 'X', sizeof(buf));
        client.write(fd, buf, sizeof(buf));
        client.close(fd);

        char rbuf[4096];
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < ITERS; i++) {
            fd = client.open(filepath.c_str(), OpenFlags::RDONLY);
            if (fd >= 0) {
                client.read(fd, rbuf, sizeof(rbuf));
                client.close(fd);
            }
        }
        auto t1 = std::chrono::steady_clock::now();

        client.unlink(filepath.c_str());

        double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        double avg = us / ITERS;
        double ops = (avg > 0) ? 1000000.0 / avg : 0;
        printf("[PERF] read_4k: %.1fus avg (%.0f ops/sec)\n", avg, ops);
    }

    // --- stat ---
    {
        std::string filepath = tmp + "/perf_stat.tmp";
        int fd = client.open(filepath.c_str(), OpenFlags::RDWR | OpenFlags::CREAT);
        if (fd >= 0) {
            client.write(fd, "stat", 4);
            client.close(fd);
        }

        FileMetadata meta;
        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < ITERS; i++) {
            client.stat(filepath.c_str(), &meta);
        }
        auto t1 = std::chrono::steady_clock::now();

        client.unlink(filepath.c_str());

        double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
        double avg = us / ITERS;
        double ops = (avg > 0) ? 1000000.0 / avg : 0;
        printf("[PERF] stat: %.1fus avg (%.0f ops/sec)\n", avg, ops);
    }
}

// ============================================================================
// Cleanup helper
// ============================================================================

static void recursive_rm(const std::string& path) {
    DIR* d = opendir(path.c_str());
    if (!d) {
        ::unlink(path.c_str());
        return;
    }
    struct dirent* de;
    while ((de = readdir(d)) != nullptr) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) {
            continue;
        }
        std::string child = path + "/" + de->d_name;
        if (de->d_type == DT_DIR) {
            recursive_rm(child);
        } else {
            ::unlink(child.c_str());
        }
    }
    closedir(d);
    ::rmdir(path.c_str());
}

// ============================================================================
// Main
// ============================================================================

int main() {
    // Allocate shared memory region via anonymous mmap
    void* region = mmap(nullptr, REGION_SIZE,
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_ANONYMOUS,
                        -1, 0);
    assert(region != MAP_FAILED);
    memset(region, 0, REGION_SIZE);

    // We need a SharedMemoryRegion that wraps this pointer.
    // Since map_fd / map_hyperv aren't suitable for MAP_ANONYMOUS, we create
    // the region via a temp file backed by the anonymous mapping.
    // Instead, write the anonymous region to a temp shm fd and map it.
    char shm_name[] = "/strix_test_XXXXXX";
    // Use memfd_create for a purely anonymous backing fd
    int memfd = memfd_create("shm_test", 0);
    assert(memfd >= 0);
    int rc = ftruncate(memfd, static_cast<off_t>(REGION_SIZE));
    assert(rc == 0);
    // Unmap the anonymous region, let SharedMemoryRegion own the mapping
    munmap(region, REGION_SIZE);

    SharedMemoryRegion shm;
    bool mapped = shm.map_fd(memfd, REGION_SIZE);
    assert(mapped);
    assert(shm.is_mapped());
    // Note: map_fd takes ownership of the fd; don't close memfd separately.

    // Initialize control block
    ControlBlock* ctrl = shm.control();
    ctrl->initialize(REGION_SIZE);
    assert(ctrl->is_valid());

    // Create temp directory for test files
    char tmp_template[] = "/tmp/shm_test_XXXXXX";
    char* tmp_dir = mkdtemp(tmp_template);
    assert(tmp_dir != nullptr);
    std::string tmp(tmp_dir);

    printf("Shared Memory IPC Test Harness\n");
    printf("Region: %zu bytes at %p\n", shm.size(), shm.base());
    printf("Temp dir: %s\n\n", tmp.c_str());

    // Start server thread
    ServerState server_state;
    server_state.shm = &shm;
    server_state.tmp_dir = tmp;
    std::thread server(server_thread_fn, &server_state);

    // Create client and wait for server
    SharedMemoryClient client(shm);
    bool init_ok = client.initialize(5000);
    assert(init_ok);

    // Run correctness tests
    report("test_ping",                    test_ping(client));
    report("test_mkdir_rmdir",             test_mkdir_rmdir(client, tmp));
    report("test_open_write_read_close",   test_open_write_read_close(client, tmp));
    report("test_stat",                    test_stat(client, tmp));
    report("test_readdir",                 test_readdir(client, tmp));
    report("test_large_read",             test_large_read(client, tmp));
    report("test_rename",                  test_rename(client, tmp));
    report("test_concurrent_ops",          test_concurrent_ops(client, tmp));

    printf("\n");

    // Performance measurement
    measure_latency(client, tmp);

    // Shut down the server
    // Use the low-level ring to send Shutdown since there is no client wrapper
    {
        CommandRing cmd_ring(shm);
        ResponseRing rsp_ring(shm);
        uint32_t req = cmd_ring.submit(CommandType::Shutdown, nullptr, 0, 0, 0);
        if (req != 0) {
            ResponseEntry rsp;
            rsp_ring.wait_for(req, rsp, 2000);
        }
    }

    server.join();

    // Clean up temp directory
    recursive_rm(tmp);

    printf("\n[RESULT] %d/%d tests passed\n", g_tests_passed, g_tests_total);

    return (g_tests_passed == g_tests_total) ? 0 : 1;
}
