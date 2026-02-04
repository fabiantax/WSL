// Property-based tests for io_uring batch framework
// Compile: g++ -std=c++17 -O2 test_uring_properties.cpp uring_batch.cpp -luring -o test_uring_properties

#include "uring_batch.h"

using namespace strix::uring;
#include <iostream>
#include <random>
#include <vector>
#include <string>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

// ============================================================================
// Random Data Generator
// ============================================================================

class DataGenerator {
private:
    std::mt19937 rng;
    std::uniform_int_distribution<> byte_dist;
    std::uniform_int_distribution<> size_dist;

public:
    DataGenerator(unsigned seed = 42)
        : rng(seed), byte_dist(0, 255), size_dist(1, 4096) {}

    std::vector<uint8_t> generate_data(size_t size = 0) {
        if (size == 0) {
            size = size_dist(rng);
        }
        std::vector<uint8_t> data(size);
        for (auto& b : data) {
            b = static_cast<uint8_t>(byte_dist(rng));
        }
        return data;
    }

    std::vector<off_t> generate_offsets(int count, off_t max_offset = 1024 * 1024) {
        std::uniform_int_distribution<off_t> offset_dist(0, max_offset);
        std::vector<off_t> offsets;
        for (int i = 0; i < count; ++i) {
            offsets.push_back(offset_dist(rng));
        }
        return offsets;
    }
};

// ============================================================================
// Property Tester
// ============================================================================

class PropertyTester {
private:
    DataGenerator gen;
    int tests_run = 0;
    int tests_passed = 0;
    int tests_failed = 0;
    std::string test_dir = "/tmp/uring_property_tests";

public:
    PropertyTester() {
        // Create test directory
        mkdir(test_dir.c_str(), 0755);
    }

    ~PropertyTester() {
        // Cleanup
        system(("rm -rf " + test_dir).c_str());
    }

    void check(bool condition, const std::string& property_name, const std::string& details = "") {
        tests_run++;
        if (condition) {
            tests_passed++;
        } else {
            tests_failed++;
            std::cout << "  ✗ FAILED: " << property_name << "\n";
            if (!details.empty()) {
                std::cout << "    " << details << "\n";
            }
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

    // Property 1: Write + Read = Identity (data integrity)
    void test_write_read_identity(int iterations = 100) {
        std::cout << "Property: write(data) -> read() = data\n";

        for (int i = 0; i < iterations; ++i) {
            std::string filepath = test_dir + "/identity_" + std::to_string(i);
            auto data = gen.generate_data();

            // Write using io_uring batch
            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                if (!file.open(filepath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644)) {
                    check(false, "file open for write", filepath);
                    continue;
                }

                ssize_t written = file.write(data.data(), data.size(), 0);
                check(written == static_cast<ssize_t>(data.size()),
                      "write returns correct size",
                      "wrote " + std::to_string(written) + " expected " + std::to_string(data.size()));
            }

            // Read back using io_uring batch
            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                if (!file.open(filepath.c_str(), O_RDONLY, 0)) {
                    check(false, "file open for read", filepath);
                    continue;
                }

                std::vector<uint8_t> read_data(data.size());
                ssize_t nread = file.read(read_data.data(), read_data.size(), 0);

                check(nread == static_cast<ssize_t>(data.size()),
                      "read returns correct size",
                      "read " + std::to_string(nread) + " expected " + std::to_string(data.size()));

                if (nread == static_cast<ssize_t>(data.size())) {
                    bool data_matches = (std::memcmp(data.data(), read_data.data(), data.size()) == 0);
                    check(data_matches, "read data matches written data", filepath);
                }
            }

            unlink(filepath.c_str());
        }
        std::cout << "  ✓ Tested " << iterations << " random data blobs\n\n";
    }

    // Property 2: Batched operations produce same result as sequential
    void test_batch_equivalence(int iterations = 50) {
        std::cout << "Property: batch(ops) ≡ sequential(ops)\n";

        for (int i = 0; i < iterations; ++i) {
            std::string filepath = test_dir + "/batch_equiv_" + std::to_string(i);

            // Generate multiple write operations
            std::vector<std::vector<uint8_t>> data_chunks;
            std::vector<off_t> offsets;
            for (int j = 0; j < 5; ++j) {
                data_chunks.push_back(gen.generate_data(256));
                offsets.push_back(j * 512);  // Non-overlapping
            }

            // Sequential writes (reference)
            {
                int fd = open(filepath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
                for (size_t j = 0; j < data_chunks.size(); ++j) {
                    pwrite(fd, data_chunks[j].data(), data_chunks[j].size(), offsets[j]);
                }
                close(fd);
            }

            // Read back sequential result
            std::vector<uint8_t> seq_result(10240, 0);
            {
                int fd = open(filepath.c_str(), O_RDONLY, 0);
                read(fd, seq_result.data(), seq_result.size());
                close(fd);
            }

            // Batched writes using io_uring
            unlink(filepath.c_str());
            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                file.open(filepath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);

                for (size_t j = 0; j < data_chunks.size(); ++j) {
                    file.write(data_chunks[j].data(), data_chunks[j].size(), offsets[j]);
                }
                // Writes are batched and submitted together
            }

            // Read back batched result
            std::vector<uint8_t> batch_result(10240, 0);
            {
                int fd = open(filepath.c_str(), O_RDONLY, 0);
                read(fd, batch_result.data(), batch_result.size());
                close(fd);
            }

            bool results_match = (seq_result == batch_result);
            check(results_match, "batched operations produce same result as sequential", filepath);

            unlink(filepath.c_str());
        }
        std::cout << "  ✓ Tested " << iterations << " batch scenarios\n\n";
    }

    // Property 3: File size consistency after operations
    void test_file_size_consistency(int iterations = 100) {
        std::cout << "Property: file operations maintain correct size\n";

        for (int i = 0; i < iterations; ++i) {
            std::string filepath = test_dir + "/size_test_" + std::to_string(i);
            auto data = gen.generate_data();

            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                file.open(filepath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
                file.write(data.data(), data.size(), 0);
            }

            // Check file size matches what we wrote
            struct stat st;
            stat(filepath.c_str(), &st);
            check(st.st_size == static_cast<off_t>(data.size()),
                  "file size matches written size",
                  "size=" + std::to_string(st.st_size) + " expected=" + std::to_string(data.size()));

            unlink(filepath.c_str());
        }
        std::cout << "  ✓ Tested " << iterations << " file size checks\n\n";
    }

    // Property 4: Idempotency - writing same data twice produces same result
    void test_write_idempotency(int iterations = 50) {
        std::cout << "Property: write(data); write(data) ≡ write(data)\n";

        for (int i = 0; i < iterations; ++i) {
            std::string filepath = test_dir + "/idempotent_" + std::to_string(i);
            auto data = gen.generate_data();

            // Write once
            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                file.open(filepath.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
                file.write(data.data(), data.size(), 0);
            }

            std::vector<uint8_t> after_first(data.size());
            {
                int fd = open(filepath.c_str(), O_RDONLY, 0);
                read(fd, after_first.data(), after_first.size());
                close(fd);
            }

            // Write again (overwrite)
            {
                UringContext ctx(32);
                AsyncFile file(ctx);
                file.open(filepath.c_str(), O_WRONLY, 0);
                file.write(data.data(), data.size(), 0);
            }

            std::vector<uint8_t> after_second(data.size());
            {
                int fd = open(filepath.c_str(), O_RDONLY, 0);
                read(fd, after_second.data(), after_second.size());
                close(fd);
            }

            check(after_first == after_second,
                  "writing same data twice produces same result",
                  filepath);

            unlink(filepath.c_str());
        }
        std::cout << "  ✓ Tested " << iterations << " idempotency checks\n\n";
    }

    // Property 5: Statistics accuracy
    void test_statistics_accuracy(int iterations = 50) {
        std::cout << "Property: statistics accurately reflect operations\n";

        for (int i = 0; i < iterations; ++i) {
            UringContext ctx(32);
            std::string filepath = test_dir + "/stats_test_" + std::to_string(i);

            size_t total_written = 0;
            size_t total_read = 0;
            int num_ops = 5;

            AsyncFile file(ctx);
            file.open(filepath.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0644);

            // Write operations
            for (int j = 0; j < num_ops; ++j) {
                auto data = gen.generate_data(512);
                file.write(data.data(), data.size(), j * 512);
                total_written += data.size();
            }

            // Read operations
            for (int j = 0; j < num_ops; ++j) {
                std::vector<uint8_t> buffer(512);
                file.read(buffer.data(), buffer.size(), j * 512);
                total_read += buffer.size();
            }

            auto stats = ctx.get_stats();

            check(stats.sqe_submitted >= num_ops * 2,
                  "submitted count reflects operations",
                  "submitted=" + std::to_string(stats.sqe_submitted));

            check(stats.cqe_processed >= num_ops * 2,
                  "processed count reflects operations",
                  "processed=" + std::to_string(stats.cqe_processed));

            unlink(filepath.c_str());
        }
        std::cout << "  ✓ Tested " << iterations << " statistics checks\n\n";
    }

    void run_all_properties(int iterations = 100) {
        std::cout << "════════════════════════════════════════════════════════════\n";
        std::cout << "  io_uring Batch - Property-Based Tests\n";
        std::cout << "  Running up to " << iterations << " iterations per property\n";
        std::cout << "════════════════════════════════════════════════════════════\n\n";

        test_write_read_identity(iterations);
        test_batch_equivalence(iterations / 2);
        test_file_size_consistency(iterations);
        test_write_idempotency(iterations / 2);
        test_statistics_accuracy(iterations / 2);

        print_summary();
    }
};

int main(int argc, char** argv) {
    int iterations = 100;
    if (argc > 1) {
        iterations = std::atoi(argv[1]);
    }

    PropertyTester tester;
    tester.run_all_properties(iterations);

    return 0;
}
