#include "simd_path_utils.h"
#include <iostream>
#include <cstring>

int main() {
    const char* path = "/gS0";
    size_t len = strlen(path);
    
    size_t basename_len;
    const char* basename = wsl::simd::get_basename(path, len, &basename_len);
    size_t dirname_len = wsl::simd::get_dirname_length(path, len);
    size_t last_sep = wsl::simd::find_last_separator_avx512(path, len);
    
    std::cout << "Path: \"" << path << "\" (len=" << len << ")\n";
    std::cout << "Last separator at: " << last_sep << "\n";
    std::cout << "Dirname length: " << dirname_len << "\n";
    std::cout << "Basename: \"" << std::string(basename, basename_len) << "\" (len=" << basename_len << ")\n";
    std::cout << "\nExpected for path \"/gS0\":\n";
    std::cout << "  dirname = \"/\" (length 1) OR \"\" (length 0, ambiguous)\n";
    std::cout << "  basename = \"gS0\" (length 3)\n";
    
    return 0;
}
