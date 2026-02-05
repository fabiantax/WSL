/**
 * Shared Memory IPC Server Entry Point for WSL2 Strix-Turbo
 *
 * Standalone Windows console application that creates a shared memory region
 * and runs the SharedMemoryServer loop to handle file operations from the
 * WSL2 Linux guest.
 *
 * Build (Windows):
 *   cl.exe /O2 /std:c++17 /EHsc shared_memory_ipc_win.cpp shm_server_main.cpp /Fe:shm_server.exe
 *
 * Usage:
 *   shm_server.exe [--name <shm_name>] [--size <mb>]
 *
 * Default:
 *   Name: StrixWSL
 *   Size: 64 MB
 */

#ifdef _WIN32

#include "shared_memory_ipc.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>

using namespace strix::shm;

static SharedMemoryServer* g_server = nullptr;

static void signal_handler(int sig) {
    (void)sig;
    fprintf(stderr, "\n[shm_server] Caught signal, shutting down...\n");
    if (g_server) {
        g_server->shutdown();
    }
}

static void print_usage(const char* argv0) {
    fprintf(stderr,
        "Usage: %s [options]\n"
        "\n"
        "Strix-Turbo Shared Memory IPC Server\n"
        "\n"
        "Options:\n"
        "  --name <name>   Shared memory region name (default: StrixWSL)\n"
        "  --size <mb>     Region size in MB (default: 64)\n"
        "  --help          Show this help\n"
        "\n"
        "The server creates a named shared memory region and processes\n"
        "file operation commands from the WSL2 Linux client.\n",
        argv0);
}

int main(int argc, char* argv[]) {
    const wchar_t* shm_name = L"StrixWSL";
    wchar_t custom_name[256] = {};
    size_t size_mb = 64;

    // Parse arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--name") == 0 && i + 1 < argc) {
            i++;
            MultiByteToWideChar(CP_UTF8, 0, argv[i], -1, custom_name, 256);
            shm_name = custom_name;
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            i++;
            size_mb = static_cast<size_t>(atoi(argv[i]));
            if (size_mb < 2 || size_mb > 4096) {
                fprintf(stderr, "[shm_server] Error: size must be 2-4096 MB\n");
                return 1;
            }
        } else {
            fprintf(stderr, "[shm_server] Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    size_t region_size = size_mb * 1024 * 1024;

    fprintf(stderr, "[shm_server] Creating shared memory region '%ls' (%zu MB)...\n",
            shm_name, size_mb);

    // Create shared memory region
    SharedMemoryRegion shm;
    if (!shm.create(shm_name, region_size)) {
        fprintf(stderr, "[shm_server] Error: Failed to create shared memory region\n");
        return 1;
    }

    // Initialize control block
    ControlBlock* ctrl = shm.control();
    ctrl->initialize(region_size);

    fprintf(stderr, "[shm_server] Region created at %p (%zu bytes)\n",
            shm.base(), shm.size());
    fprintf(stderr, "[shm_server] Magic: 0x%08X, Version: %u\n",
            ctrl->magic, ctrl->version);

    // Create and initialize server
    SharedMemoryServer server(shm);
    g_server = &server;

    if (!server.initialize()) {
        fprintf(stderr, "[shm_server] Error: Failed to initialize server\n");
        return 1;
    }

    // Install signal handlers for graceful shutdown
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    fprintf(stderr, "[shm_server] Server ready. Waiting for client...\n");

    // Wait for client
    while (!ctrl->linux_ready.load(std::memory_order_acquire)) {
        if (ctrl->shutdown.load(std::memory_order_acquire)) {
            fprintf(stderr, "[shm_server] Shutdown before client connected.\n");
            return 0;
        }
        Sleep(10);
    }

    fprintf(stderr, "[shm_server] Client connected. Processing commands...\n");

    // Run server loop (blocks until shutdown)
    server.run();

    // Print stats
    fprintf(stderr, "\n[shm_server] Shutdown complete.\n");
    fprintf(stderr, "[shm_server] Commands processed: %llu\n",
            ctrl->commands_processed.load(std::memory_order_relaxed));
    fprintf(stderr, "[shm_server] Bytes transferred:  %llu\n",
            ctrl->bytes_transferred.load(std::memory_order_relaxed));
    fprintf(stderr, "[shm_server] Cache hits:         %llu\n",
            ctrl->cache_hits.load(std::memory_order_relaxed));
    fprintf(stderr, "[shm_server] Cache misses:       %llu\n",
            ctrl->cache_misses.load(std::memory_order_relaxed));

    g_server = nullptr;
    return 0;
}

#else
// Not a Windows build - print error
#include <cstdio>
int main() {
    fprintf(stderr, "Error: shm_server is a Windows-only application.\n");
    fprintf(stderr, "Build with MSVC: cl.exe /O2 /std:c++17 /EHsc "
                    "shared_memory_ipc_win.cpp shm_server_main.cpp "
                    "/Fe:shm_server.exe\n");
    return 1;
}
#endif
