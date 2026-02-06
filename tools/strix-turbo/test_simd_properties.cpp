// Property-based tests for SIMD path utils
// Compile: g++ -std=c++17 -mavx512f -mavx512bw -O3 test_simd_properties.cpp -o test_simd_properties

#include "simd_path_utils.h"
#include <iostream>
#include <string>
#include <vector>
#include <random>
#include <cstring>
#include <cassert>
#include <algorithm>

// ============================================================================
// Random Input Generators
// ============================================================================

class PathGenerator {
private:
    std::mt19937 rng;
    std::uniform_int_distribution<> length_dist;
    std::uniform_int_distribution<> char_dist;
    std::uniform_real_distribution<> separator_prob;

public:
    PathGenerator(unsigned seed = 42)
        : rng(seed),
          length_dist(0, 512),
          char_dist(33, 126),  // Printable ASCII
          separator_prob(0.0, 1.0) {}

    // Generate random path with controlled separator density
    std::string generate_path(double sep_probability = 0.1) {
        int len = length_dist(rng);
        std::string path;
        path.reserve(len);

        for (int i = 0; i < len; ++i) {
            if (separator_prob(rng) < sep_probability) {
                // Mix of forward and back slashes
                path += (rng() % 2 == 0) ? '/' : '\\';
            } else {
                // Regular character (excluding separators)
                char c;
                do {
                    c = static_cast<char>(char_dist(rng));
                } while (c == '/' || c == '\\');
                path += c;
            }
        }
        return path;
    }

    // Generate edge cases
    std::vector<std::string> generate_edge_cases() {
        return {
            "",                           // Empty
            "/",                          // Single separator
            "\\",                         // Single backslash
            "a",                          // Single char
            "///",                        // Only separators
            std::string(64, 'a'),        // Exactly 64 bytes (AVX-512 chunk)
            std::string(65, 'a'),        // Just over 64 bytes
            std::string(127, 'a'),       // Just under 128 bytes
            std::string(128, 'a'),       // Exactly 128 bytes
            std::string(1024, 'a'),      // Large path
            "/a/b/c/d/e/f/g/h/i/j",     // Many components
            "a//b///c////d",             // Consecutive separators
            "/start",                     // Leading separator
            "end/",                       // Trailing separator
            "middle/part",                // Middle separator
            std::string(100, '/'),       // All separators
        };
    }
};

// ============================================================================
// Property Tests
// ============================================================================

class PropertyTester {
private:
    PathGenerator gen;
    int tests_run = 0;
    int tests_passed = 0;
    int tests_failed = 0;

public:
    void check(bool condition, const std::string& property_name, const std::string& input) {
        tests_run++;
        if (condition) {
            tests_passed++;
        } else {
            tests_failed++;
            std::cout << "  ✗ FAILED: " << property_name << "\n";
            std::cout << "    Input: \"" << input << "\" (len=" << input.size() << ")\n";
        }
    }

    void print_summary() {
        std::cout << "\n════════════════════════════════════════════════════════════\n";
        std::cout << "  Property Test Summary\n";
        std::cout << "════════════════════════════════════════════════════════════\n";
        std::cout << "Total properties checked: " << tests_run << "\n";
        std::cout << "Passed: " << tests_passed << "\n";
        std::cout << "Failed: " << tests_failed << "\n";
        if (tests_failed == 0) {
            std::cout << "\n✓ All properties satisfied!\n";
        }
    }

    // Property 1: If separator found, it must actually be a separator
    void test_find_separator_validity(int iterations = 1000) {
        std::cout << "Property: find_path_separator returns valid index or -1\n";

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.2);
            size_t result = wsl::simd::find_path_separator_avx512(path.c_str(), path.size());

            if (result != static_cast<size_t>(-1)) {
                // Must be in bounds
                bool in_bounds = result < path.size();
                check(in_bounds, "separator index in bounds", path);

                // Must point to actual separator
                if (in_bounds) {
                    bool is_sep = (path[result] == '/' || path[result] == '\\');
                    check(is_sep, "separator index points to / or \\", path);
                }
            } else {
                // If -1, path should have no separators
                bool has_no_sep = (path.find('/') == std::string::npos &&
                                   path.find('\\') == std::string::npos);
                check(has_no_sep, "no separator found means no separators exist", path);
            }
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 2: Last separator >= First separator
    void test_last_separator_ordering(int iterations = 1000) {
        std::cout << "Property: last_separator >= first_separator\n";

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.2);
            size_t first = wsl::simd::find_path_separator_avx512(path.c_str(), path.size());
            size_t last = wsl::simd::find_last_separator_avx512(path.c_str(), path.size());

            if (first != static_cast<size_t>(-1) && last != static_cast<size_t>(-1)) {
                check(last >= first, "last separator at or after first", path);
            }

            // Both should agree on whether separators exist
            bool both_none = (first == static_cast<size_t>(-1) && last == static_cast<size_t>(-1));
            bool both_exist = (first != static_cast<size_t>(-1) && last != static_cast<size_t>(-1));
            check(both_none || both_exist, "first and last agree on separator existence", path);
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 3: normalize doesn't change length, only characters
    void test_normalize_preserves_length(int iterations = 1000) {
        std::cout << "Property: normalize_path_separators preserves length\n";

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.3);
            std::string normalized = path;
            size_t orig_len = path.size();

            wsl::simd::normalize_path_separators_avx512(&normalized[0], normalized.size());

            check(normalized.size() == orig_len, "length unchanged after normalization", path);

            // All backslashes should be gone
            bool no_backslash = (normalized.find('\\') == std::string::npos);
            check(no_backslash, "no backslashes after normalization", normalized);

            // Character count should be same, just / instead of backslash
            if (path.size() == normalized.size()) {
                int orig_seps = std::count(path.begin(), path.end(), '/') +
                               std::count(path.begin(), path.end(), '\\');
                int norm_seps = std::count(normalized.begin(), normalized.end(), '/');
                check(orig_seps == norm_seps, "separator count preserved", path);
            }
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 4: Component count matches manual count
    void test_component_count_accuracy(int iterations = 1000) {
        std::cout << "Property: count_path_components matches reference implementation\n";

        auto reference_count = [](const std::string& path) -> size_t {
            if (path.empty()) return 0;
            size_t count = 0;
            bool in_component = false;
            for (char c : path) {
                bool is_sep = (c == '/' || c == '\\');
                if (!is_sep) {
                    if (!in_component) {
                        count++;
                        in_component = true;
                    }
                } else {
                    in_component = false;
                }
            }
            return count;
        };

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.15);
            size_t simd_count = wsl::simd::count_path_components_avx512(path.c_str(), path.size());
            size_t ref_count = reference_count(path);

            check(simd_count == ref_count, "component count matches reference", path);
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 5: basename + dirname reconstruction
    void test_basename_dirname_consistency(int iterations = 1000) {
        std::cout << "Property: dirname + basename reconstruction\n";

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.15);
            if (path.empty()) continue;

            size_t basename_len;
            const char* basename = wsl::simd::get_basename(path.c_str(), path.size(), &basename_len);
            size_t dirname_len = wsl::simd::get_dirname_length(path.c_str(), path.size());

            // Basename should be within path bounds
            bool basename_valid = (basename >= path.c_str() &&
                                  basename <= path.c_str() + path.size());
            check(basename_valid, "basename pointer within path", path);

            // If there's a dirname, basename should start after last separator
            if (dirname_len > 0) {
                size_t last_sep = wsl::simd::find_last_separator_avx512(path.c_str(), path.size());
                if (last_sep != static_cast<size_t>(-1)) {
                    // dirname_len should equal position of last separator
                    check(dirname_len == last_sep, "dirname length equals last separator position", path);

                    // basename should start after separator
                    size_t basename_offset = basename - path.c_str();
                    check(basename_offset == last_sep + 1, "basename starts after last separator", path);
                }
            }

            // dirname + basename lengths should account for full path
            // Note: dirname_len is the INDEX of last separator, not length
            size_t last_sep = wsl::simd::find_last_separator_avx512(path.c_str(), path.size());

            if (last_sep == static_cast<size_t>(-1)) {
                // No separator: basename should be entire path
                check(basename_len == path.size(), "basename is entire path when no separator", path);
                check(dirname_len == 0, "dirname_len is 0 when no separator", path);
            } else {
                // Separator exists: dirname + "/" + basename = path
                size_t total = last_sep + 1 + basename_len; // last_sep + 1 for separator
                check(total == path.size(), "dirname + sep + basename = path length", path);
                check(dirname_len == last_sep, "dirname_len equals separator position", path);
            }
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 6: is_absolute consistency
    void test_absolute_path_property(int iterations = 1000) {
        std::cout << "Property: is_absolute_path matches first character check\n";

        for (int i = 0; i < iterations; ++i) {
            std::string path = gen.generate_path(0.1);
            if (path.empty()) continue;

            bool is_abs = wsl::simd::is_absolute_path(path.c_str(), path.size());
            bool starts_with_sep = (path[0] == '/' || path[0] == '\\');

            check(is_abs == starts_with_sep, "is_absolute matches first char check", path);
        }
        std::cout << "  ✓ Tested " << iterations << " random paths\n\n";
    }

    // Property 7: Edge case robustness
    void test_edge_cases() {
        std::cout << "Property: Edge cases handled correctly\n";

        auto edge_cases = gen.generate_edge_cases();
        for (const auto& path : edge_cases) {
            // Should not crash or access out of bounds
            size_t first_sep = wsl::simd::find_path_separator_avx512(path.c_str(), path.size());
            size_t last_sep = wsl::simd::find_last_separator_avx512(path.c_str(), path.size());
            size_t count = wsl::simd::count_path_components_avx512(path.c_str(), path.size());

            // Basic sanity
            check(first_sep == static_cast<size_t>(-1) || first_sep < path.size(),
                  "first_sep in bounds", path);
            check(last_sep == static_cast<size_t>(-1) || last_sep < path.size(),
                  "last_sep in bounds", path);

            // Empty path has 0 components
            if (path.empty()) {
                check(count == 0, "empty path has 0 components", path);
            }
        }
        std::cout << "  ✓ Tested " << edge_cases.size() << " edge cases\n\n";
    }

    void run_all_properties(int iterations = 1000) {
        std::cout << "════════════════════════════════════════════════════════════\n";
        std::cout << "  SIMD Path Utils - Property-Based Tests\n";
        std::cout << "  Running " << iterations << " iterations per property\n";
        std::cout << "════════════════════════════════════════════════════════════\n\n";

        test_find_separator_validity(iterations);
        test_last_separator_ordering(iterations);
        test_normalize_preserves_length(iterations);
        test_component_count_accuracy(iterations);
        test_basename_dirname_consistency(iterations);
        test_absolute_path_property(iterations);
        test_edge_cases();

        print_summary();
    }
};

// ============================================================================
// Main
// ============================================================================

int main(int argc, char** argv) {
    int iterations = 1000;
    if (argc > 1) {
        iterations = std::atoi(argv[1]);
    }

    std::cout << "AVX-512 support: "
              << (wsl::simd::detail::detect_avx512_support() ? "YES" : "NO")
              << "\n\n";

    PropertyTester tester;
    tester.run_all_properties(iterations);

    return 0;
}
