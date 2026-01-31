// Example integration of SIMD path utilities into WSL2 Plan9 filesystem bridge
// This demonstrates how to use the AVX-512 optimized functions in real WSL scenarios

#include "simd_path_utils.h"
#include <iostream>
#include <string>
#include <vector>
#include <cstring>

// Example 1: Windows to Linux path translation for WSL file access
struct WslPathTranslation {
    std::string windows_path;
    std::string linux_path;
    bool success;
};

WslPathTranslation translate_windows_to_linux_path(const char* windows_path) {
    WslPathTranslation result;
    result.windows_path = windows_path;
    result.success = false;

    size_t len = strlen(windows_path);
    if (len == 0) {
        return result;
    }

    // Allocate buffer for translated path
    char* translated = new char[len + 20]; // Extra space for /mnt/c/ prefix

    // Check if it's a Windows absolute path (e.g., C:\Users\...)
    if (len >= 3 && windows_path[1] == ':' &&
        (windows_path[2] == '\\' || windows_path[2] == '/')) {

        // Convert drive letter to lowercase and create /mnt/X/ prefix
        char drive = tolower(windows_path[0]);
        sprintf(translated, "/mnt/%c", drive);
        size_t prefix_len = strlen(translated);

        // Copy the rest of the path
        strcpy(translated + prefix_len, windows_path + 2);
        len = strlen(translated);

        // Normalize all backslashes to forward slashes
        wsl::simd::normalize_path_separators_avx512(translated, len);

        result.linux_path = translated;
        result.success = true;
    } else {
        // Relative path or already Linux-style
        strcpy(translated, windows_path);
        wsl::simd::normalize_path_separators_avx512(translated, len);
        result.linux_path = translated;
        result.success = true;
    }

    delete[] translated;
    return result;
}

// Example 2: Fast path component extraction for Plan9 protocol
struct PathComponents {
    std::vector<std::string> components;
    size_t count;
};

PathComponents extract_path_components(const char* path) {
    PathComponents result;
    size_t len = strlen(path);

    // Count components using SIMD
    result.count = wsl::simd::count_path_components_avx512(path, len);
    result.components.reserve(result.count);

    if (result.count == 0) {
        return result;
    }

    // Extract each component
    size_t start = 0;
    bool in_component = false;

    for (size_t i = 0; i < len; ++i) {
        bool is_separator = (path[i] == '/' || path[i] == '\\');

        if (!is_separator) {
            if (!in_component) {
                start = i;
                in_component = true;
            }
        } else {
            if (in_component) {
                result.components.emplace_back(path + start, i - start);
                in_component = false;
            }
        }
    }

    // Handle last component
    if (in_component) {
        result.components.emplace_back(path + start, len - start);
    }

    return result;
}

// Example 3: Fast basename/dirname extraction for file operations
struct PathSplit {
    std::string dirname;
    std::string basename;
};

PathSplit split_path(const char* path) {
    PathSplit result;
    size_t len = strlen(path);

    if (len == 0) {
        return result;
    }

    // Find last separator using SIMD
    size_t last_sep = wsl::simd::find_last_separator_avx512(path, len);

    if (last_sep == static_cast<size_t>(-1)) {
        // No separator, entire path is basename
        result.basename = path;
        result.dirname = ".";
    } else {
        // Split at last separator
        result.dirname = std::string(path, last_sep);
        result.basename = std::string(path + last_sep + 1, len - last_sep - 1);

        // Handle root directory case
        if (result.dirname.empty()) {
            result.dirname = "/";
        }
    }

    return result;
}

// Example 4: Path validation for Plan9 protocol
struct PathValidation {
    bool is_valid;
    bool is_absolute;
    size_t depth;
    std::string error_message;
};

PathValidation validate_plan9_path(const char* path, size_t max_depth = 64) {
    PathValidation result;
    result.is_valid = true;

    size_t len = strlen(path);

    if (len == 0) {
        result.is_valid = false;
        result.error_message = "Empty path";
        return result;
    }

    // Check if absolute
    result.is_absolute = wsl::simd::is_absolute_path(path, len);

    // Count depth using SIMD
    result.depth = wsl::simd::count_path_components_avx512(path, len);

    if (result.depth > max_depth) {
        result.is_valid = false;
        result.error_message = "Path too deep (max " + std::to_string(max_depth) + ")";
        return result;
    }

    result.error_message = "OK";
    return result;
}

// Example 5: Batch path normalization for directory listings
void normalize_path_batch(std::vector<std::string>& paths) {
    for (auto& path : paths) {
        // Normalize in-place using SIMD
        wsl::simd::normalize_path_separators_avx512(&path[0], path.length());
    }
}

// ============================================================================
// Demo main function
// ============================================================================

int main() {
    std::cout << "=== WSL2 SIMD Path Utils Integration Examples ===\n\n";

    // Example 1: Windows to Linux path translation
    std::cout << "Example 1: Windows to Linux Path Translation\n";
    std::cout << "---------------------------------------------\n";

    const char* win_paths[] = {
        "C:\\Users\\username\\Documents\\file.txt",
        "D:\\Projects\\WSL2\\src\\main.cpp",
        "\\\\wsl$\\Ubuntu\\home\\user\\test.sh"
    };

    for (const char* wp : win_paths) {
        auto result = translate_windows_to_linux_path(wp);
        std::cout << "Windows: " << result.windows_path << "\n";
        std::cout << "Linux:   " << result.linux_path << "\n";
        std::cout << "Success: " << (result.success ? "Yes" : "No") << "\n\n";
    }

    // Example 2: Path component extraction
    std::cout << "Example 2: Path Component Extraction\n";
    std::cout << "-------------------------------------\n";

    const char* paths[] = {
        "/mnt/c/Users/username/Documents",
        "/usr/local/bin/python3",
        "relative/path/to/file"
    };

    for (const char* p : paths) {
        auto comps = extract_path_components(p);
        std::cout << "Path: " << p << "\n";
        std::cout << "Components (" << comps.count << "): ";
        for (size_t i = 0; i < comps.components.size(); ++i) {
            if (i > 0) std::cout << " / ";
            std::cout << comps.components[i];
        }
        std::cout << "\n\n";
    }

    // Example 3: Basename/Dirname extraction
    std::cout << "Example 3: Basename/Dirname Split\n";
    std::cout << "----------------------------------\n";

    const char* file_paths[] = {
        "/mnt/c/Users/username/Documents/report.pdf",
        "/usr/local/bin/bash",
        "relative_file.txt"
    };

    for (const char* fp : file_paths) {
        auto split = split_path(fp);
        std::cout << "Path:     " << fp << "\n";
        std::cout << "Dirname:  " << split.dirname << "\n";
        std::cout << "Basename: " << split.basename << "\n\n";
    }

    // Example 4: Path validation
    std::cout << "Example 4: Path Validation\n";
    std::cout << "--------------------------\n";

    const char* test_paths[] = {
        "/mnt/c/valid/path",
        "",
        "/very/deep/path/with/many/levels/component1/component2/component3"
    };

    for (const char* tp : test_paths) {
        auto validation = validate_plan9_path(tp, 10);
        std::cout << "Path:     \"" << tp << "\"\n";
        std::cout << "Valid:    " << (validation.is_valid ? "Yes" : "No") << "\n";
        std::cout << "Absolute: " << (validation.is_absolute ? "Yes" : "No") << "\n";
        std::cout << "Depth:    " << validation.depth << "\n";
        std::cout << "Status:   " << validation.error_message << "\n\n";
    }

    // Example 5: Batch normalization
    std::cout << "Example 5: Batch Path Normalization\n";
    std::cout << "------------------------------------\n";

    std::vector<std::string> batch_paths = {
        "C:\\Windows\\System32\\drivers",
        "D:\\Program Files\\Application\\bin",
        "E:\\Data\\Users\\Public\\Documents"
    };

    std::cout << "Before normalization:\n";
    for (const auto& p : batch_paths) {
        std::cout << "  " << p << "\n";
    }

    normalize_path_batch(batch_paths);

    std::cout << "\nAfter normalization:\n";
    for (const auto& p : batch_paths) {
        std::cout << "  " << p << "\n";
    }

    std::cout << "\n=== All examples completed ===\n";
    return 0;
}
