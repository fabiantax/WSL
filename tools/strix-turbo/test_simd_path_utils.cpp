// Test program for simd_path_utils.h
// Compile with: g++ -std=c++17 -mavx512f -mavx512bw -O3 test_simd_path_utils.cpp -o test_simd_path_utils
// Or with benchmarks: g++ -std=c++17 -mavx512f -mavx512bw -O3 -DSIMD_PATH_UTILS_ENABLE_BENCHMARK test_simd_path_utils.cpp -o test_simd_path_utils

#include "simd_path_utils.h"
#include <iostream>
#include <cstring>
#include <cassert>

void test_find_path_separator() {
    std::cout << "Testing find_path_separator_avx512...\n";

    // Test with forward slash
    const char* path1 = "/usr/bin/bash";
    size_t result = wsl::simd::find_path_separator_avx512(path1, strlen(path1));
    assert(result == 0);
    std::cout << "  ✓ Found first separator at index " << result << " in \"" << path1 << "\"\n";

    // Test with backslash
    const char* path2 = "C:\\Windows\\System32";
    result = wsl::simd::find_path_separator_avx512(path2, strlen(path2));
    assert(result == 2);
    std::cout << "  ✓ Found first separator at index " << result << " in \"" << path2 << "\"\n";

    // Test with no separator
    const char* path3 = "filename.txt";
    result = wsl::simd::find_path_separator_avx512(path3, strlen(path3));
    assert(result == static_cast<size_t>(-1));
    std::cout << "  ✓ No separator found in \"" << path3 << "\"\n";

    // Test long path (>64 bytes for AVX-512 testing)
    const char* path4 = "/very/long/path/with/many/components/to/test/avx512/simd/performance/on/ice/lake/processors/file.txt";
    result = wsl::simd::find_path_separator_avx512(path4, strlen(path4));
    assert(result == 0);
    std::cout << "  ✓ Found separator in long path (len=" << strlen(path4) << ")\n";

    std::cout << "  All tests passed!\n\n";
}

void test_normalize_path_separators() {
    std::cout << "Testing normalize_path_separators_avx512...\n";

    // Test Windows path normalization
    char path1[] = "C:\\Users\\username\\Documents\\file.txt";
    wsl::simd::normalize_path_separators_avx512(path1, strlen(path1));
    std::cout << "  ✓ Normalized: \"" << path1 << "\"\n";
    assert(strcmp(path1, "C:/Users/username/Documents/file.txt") == 0);

    // Test mixed separators
    char path2[] = "C:\\Windows/System32\\drivers/etc";
    wsl::simd::normalize_path_separators_avx512(path2, strlen(path2));
    std::cout << "  ✓ Normalized: \"" << path2 << "\"\n";
    assert(strcmp(path2, "C:/Windows/System32/drivers/etc") == 0);

    // Test long path with backslashes
    char path3[] = "C:\\Program Files\\Microsoft\\Windows\\Start Menu\\Programs\\Accessories\\System Tools\\Computer.lnk";
    wsl::simd::normalize_path_separators_avx512(path3, strlen(path3));
    std::cout << "  ✓ Normalized long path (len=" << strlen(path3) << ")\n";

    std::cout << "  All tests passed!\n\n";
}

void test_count_path_components() {
    std::cout << "Testing count_path_components_avx512...\n";

    // Test simple path
    const char* path1 = "/usr/local/bin";
    size_t count = wsl::simd::count_path_components_avx512(path1, strlen(path1));
    assert(count == 3);
    std::cout << "  ✓ \"" << path1 << "\" has " << count << " components\n";

    // Test path with consecutive separators
    const char* path2 = "/usr//local///bin";
    count = wsl::simd::count_path_components_avx512(path2, strlen(path2));
    assert(count == 3);
    std::cout << "  ✓ \"" << path2 << "\" has " << count << " components\n";

    // Test single component
    const char* path3 = "filename.txt";
    count = wsl::simd::count_path_components_avx512(path3, strlen(path3));
    assert(count == 1);
    std::cout << "  ✓ \"" << path3 << "\" has " << count << " components\n";

    // Test empty path
    const char* path4 = "";
    count = wsl::simd::count_path_components_avx512(path4, strlen(path4));
    assert(count == 0);
    std::cout << "  ✓ Empty path has " << count << " components\n";

    // Test long path
    const char* path5 = "/home/user/projects/wsl2/tools/strix-turbo/simd/optimizations/path/parsing/utils/test/file.cpp";
    count = wsl::simd::count_path_components_avx512(path5, strlen(path5));
    std::cout << "  ✓ Long path has " << count << " components\n";

    std::cout << "  All tests passed!\n\n";
}

void test_find_last_separator() {
    std::cout << "Testing find_last_separator_avx512...\n";

    // Test simple path
    const char* path1 = "/usr/local/bin/bash";
    size_t result = wsl::simd::find_last_separator_avx512(path1, strlen(path1));
    assert(result == 15);
    std::cout << "  ✓ Last separator at index " << result << " in \"" << path1 << "\"\n";

    // Test Windows path
    const char* path2 = "C:\\Windows\\System32\\cmd.exe";
    result = wsl::simd::find_last_separator_avx512(path2, strlen(path2));
    assert(result == 18);
    std::cout << "  ✓ Last separator at index " << result << " in \"" << path2 << "\"\n";

    // Test no separator
    const char* path3 = "filename.txt";
    result = wsl::simd::find_last_separator_avx512(path3, strlen(path3));
    assert(result == static_cast<size_t>(-1));
    std::cout << "  ✓ No separator in \"" << path3 << "\"\n";

    // Test trailing separator
    const char* path4 = "/usr/local/bin/";
    result = wsl::simd::find_last_separator_avx512(path4, strlen(path4));
    assert(result == strlen(path4) - 1);
    std::cout << "  ✓ Trailing separator at index " << result << "\n";

    std::cout << "  All tests passed!\n\n";
}

void test_helper_functions() {
    std::cout << "Testing helper functions...\n";

    // Test get_basename
    const char* path1 = "/usr/local/bin/bash";
    size_t basename_len;
    const char* basename = wsl::simd::get_basename(path1, strlen(path1), &basename_len);
    std::cout << "  ✓ Basename of \"" << path1 << "\" is \""
              << std::string(basename, basename_len) << "\"\n";
    assert(strncmp(basename, "bash", basename_len) == 0);

    // Test get_dirname_length
    size_t dirname_len = wsl::simd::get_dirname_length(path1, strlen(path1));
    std::cout << "  ✓ Dirname of \"" << path1 << "\" is \""
              << std::string(path1, dirname_len) << "\"\n";
    assert(dirname_len == 15);

    // Test is_absolute_path
    bool is_abs = wsl::simd::is_absolute_path("/usr/bin", 8);
    assert(is_abs == true);
    std::cout << "  ✓ \"/usr/bin\" is absolute\n";

    is_abs = wsl::simd::is_absolute_path("relative/path", 13);
    assert(is_abs == false);
    std::cout << "  ✓ \"relative/path\" is not absolute\n";

    std::cout << "  All tests passed!\n\n";
}

int main() {
    std::cout << "=== SIMD Path Utils Test Suite ===\n";
    std::cout << "AVX-512 support: "
              << (wsl::simd::detail::detect_avx512_support() ? "YES" : "NO")
              << "\n\n";

    test_find_path_separator();
    test_normalize_path_separators();
    test_count_path_components();
    test_find_last_separator();
    test_helper_functions();

#ifdef SIMD_PATH_UTILS_ENABLE_BENCHMARK
    wsl::simd::benchmark::run_path_benchmarks();
#else
    std::cout << "Tip: Recompile with -DSIMD_PATH_UTILS_ENABLE_BENCHMARK to run benchmarks\n";
#endif

    std::cout << "\n=== All tests passed! ===\n";
    return 0;
}
