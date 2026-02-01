# WSL2 Plugin Architecture - Build Configuration
#
# Build Instructions:
#   mkdir build && cd build
#   cmake .. -DCMAKE_BUILD_TYPE=Release
#   cmake --build . --config Release
#
# Options:
#   -DENABLE_SPDK=ON        Build SPDK storage plugin (requires SPDK)
#   -DENABLE_AVX512=ON      Build AVX-512 compute plugin
#   -DENABLE_NPU=ON         Build NPU prefetch plugin (requires ROCm/OpenVINO)
#   -DBUILD_TESTS=ON        Build test suite

cmake_minimum_required(VERSION 3.16)
project(WslPluginArchitecture VERSION 1.0.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Options
option(ENABLE_SPDK "Build SPDK storage plugin" OFF)
option(ENABLE_AVX512 "Build AVX-512 compute plugin" OFF)
option(ENABLE_NPU "Build NPU prefetch plugin" OFF)
option(BUILD_TESTS "Build test suite" ON)

# Compiler flags
if(MSVC)
    add_compile_options(/W4 /WX)
    if(ENABLE_AVX512)
        add_compile_options(/arch:AVX512)
    endif()
else()
    add_compile_options(-Wall -Wextra -Werror)
    if(ENABLE_AVX512)
        add_compile_options(-mavx512f -mavx512bw -mavx512vl)
    endif()
endif()

# Include directories
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../  # For existing strix-turbo headers
)

# =============================================================================
# Core Library (Header-only interfaces + detection utilities)
# =============================================================================

add_library(wsl_plugin_core STATIC
    src/capability_detection.cpp
    src/plugin_host.cpp
    src/fallback_chain.cpp
    src/health_monitor.cpp
    src/config_loader.cpp
)

target_include_directories(wsl_plugin_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# =============================================================================
# Stock Plugins (Always built)
# =============================================================================

# Scalar Compute Plugin (built-in fallback)
add_library(scalar_compute_plugin SHARED
    plugins/scalar-compute/scalar_compute_plugin.cpp
)
target_link_libraries(scalar_compute_plugin PRIVATE wsl_plugin_core)

# Stock 9p IPC Plugin (wrapper around existing 9p)
add_library(stock_9p_plugin SHARED
    plugins/stock-9p/stock_9p_plugin.cpp
)
target_link_libraries(stock_9p_plugin PRIVATE wsl_plugin_core)

# =============================================================================
# Optional Plugins
# =============================================================================

# AVX-512 Compute Plugin
if(ENABLE_AVX512)
    add_library(avx512_compute_plugin SHARED
        plugins/avx512-compute/avx512_compute_plugin.cpp
    )
    target_link_libraries(avx512_compute_plugin PRIVATE wsl_plugin_core)
    target_compile_definitions(avx512_compute_plugin PRIVATE HAVE_AVX512=1)
endif()

# SPDK Storage Plugin
if(ENABLE_SPDK)
    find_package(SPDK REQUIRED)
    add_library(spdk_storage_plugin SHARED
        plugins/spdk-storage/spdk_storage_plugin.cpp
    )
    target_link_libraries(spdk_storage_plugin PRIVATE
        wsl_plugin_core
        SPDK::spdk
    )
endif()

# Shared Memory IPC Plugin
add_library(shm_ipc_plugin SHARED
    plugins/shared-memory-ipc/shm_ipc_plugin.cpp
)
target_link_libraries(shm_ipc_plugin PRIVATE wsl_plugin_core)

# NPU Prefetch Plugin
if(ENABLE_NPU)
    find_package(ONNX REQUIRED)
    add_library(npu_prefetch_plugin SHARED
        plugins/npu-prefetch/npu_prefetch_plugin.cpp
    )
    target_link_libraries(npu_prefetch_plugin PRIVATE
        wsl_plugin_core
        ONNX::onnxruntime
    )
endif()

# =============================================================================
# Tests
# =============================================================================

if(BUILD_TESTS)
    enable_testing()

    # Plugin API tests
    add_executable(test_plugin_api
        tests/test_plugin_api.cpp
        tests/test_capability_detection.cpp
        tests/test_fallback_chain.cpp
    )
    target_link_libraries(test_plugin_api PRIVATE
        wsl_plugin_core
        scalar_compute_plugin
    )
    add_test(NAME plugin_api_tests COMMAND test_plugin_api)

    # Integration tests
    add_executable(test_integration
        tests/test_integration.cpp
    )
    target_link_libraries(test_integration PRIVATE wsl_plugin_core)
    add_test(NAME integration_tests COMMAND test_integration)

    # Benchmark
    add_executable(benchmark_plugins
        tests/benchmark_plugins.cpp
    )
    target_link_libraries(benchmark_plugins PRIVATE
        wsl_plugin_core
        scalar_compute_plugin
    )
    if(ENABLE_AVX512)
        target_link_libraries(benchmark_plugins PRIVATE avx512_compute_plugin)
    endif()
endif()

# =============================================================================
# Installation
# =============================================================================

install(TARGETS wsl_plugin_core scalar_compute_plugin stock_9p_plugin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

install(DIRECTORY include/
    DESTINATION include
    FILES_MATCHING PATTERN "*.h"
)

if(ENABLE_AVX512)
    install(TARGETS avx512_compute_plugin
        LIBRARY DESTINATION lib/plugins
        RUNTIME DESTINATION bin/plugins
    )
endif()

if(ENABLE_SPDK)
    install(TARGETS spdk_storage_plugin
        LIBRARY DESTINATION lib/plugins
        RUNTIME DESTINATION bin/plugins
    )
endif()

# =============================================================================
# Documentation
# =============================================================================

find_package(Doxygen)
if(DOXYGEN_FOUND)
    add_custom_target(docs
        COMMAND ${DOXYGEN_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMENT "Generating API documentation"
    )
endif()
