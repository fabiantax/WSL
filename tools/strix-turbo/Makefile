# Makefile for SIMD Path Utils
# AVX-512 optimized path parsing for WSL2 Plan9 filesystem bridge

CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -O3
AVX512_FLAGS := -mavx512f -mavx512bw
BENCHMARK_FLAGS := -DSIMD_PATH_UTILS_ENABLE_BENCHMARK

TARGET := test_simd_path_utils
TARGET_BENCH := test_simd_path_utils_bench
TARGET_EXAMPLE := example_wsl_integration
SOURCE := test_simd_path_utils.cpp
SOURCE_EXAMPLE := example_wsl_integration.cpp
HEADER := simd_path_utils.h

.PHONY: all test benchmark example clean help

all: $(TARGET) $(TARGET_EXAMPLE)

# Build test program
$(TARGET): $(SOURCE) $(HEADER)
	$(CXX) $(CXXFLAGS) $(AVX512_FLAGS) $(SOURCE) -o $(TARGET)
	@echo "✓ Built $(TARGET)"
	@echo "  Run with: ./$(TARGET)"

# Build test program with benchmarks
$(TARGET_BENCH): $(SOURCE) $(HEADER)
	$(CXX) $(CXXFLAGS) $(AVX512_FLAGS) $(BENCHMARK_FLAGS) $(SOURCE) -o $(TARGET_BENCH)
	@echo "✓ Built $(TARGET_BENCH) with benchmarks enabled"
	@echo "  Run with: ./$(TARGET_BENCH)"

# Build WSL integration example
$(TARGET_EXAMPLE): $(SOURCE_EXAMPLE) $(HEADER)
	$(CXX) $(CXXFLAGS) $(AVX512_FLAGS) $(SOURCE_EXAMPLE) -o $(TARGET_EXAMPLE)
	@echo "✓ Built $(TARGET_EXAMPLE)"
	@echo "  Run with: ./$(TARGET_EXAMPLE)"

# Build and run tests
test: $(TARGET)
	@echo "Running tests..."
	./$(TARGET)

# Build and run benchmarks
benchmark: $(TARGET_BENCH)
	@echo "Running benchmarks..."
	./$(TARGET_BENCH)

# Build and run example
example: $(TARGET_EXAMPLE)
	@echo "Running WSL integration example..."
	./$(TARGET_EXAMPLE)

# Clean build artifacts
clean:
	rm -f $(TARGET) $(TARGET_BENCH) $(TARGET_EXAMPLE)
	@echo "✓ Cleaned build artifacts"

# Check CPU AVX-512 support
check-cpu:
	@echo "Checking CPU capabilities..."
	@if grep -q avx512f /proc/cpuinfo && grep -q avx512bw /proc/cpuinfo; then \
		echo "✓ AVX-512F and AVX-512BW support detected"; \
	else \
		echo "✗ AVX-512 not supported on this CPU"; \
		echo "  The library will use scalar fallback"; \
	fi

# Display help
help:
	@echo "SIMD Path Utils - Makefile targets:"
	@echo ""
	@echo "  make              Build test program and WSL example"
	@echo "  make test         Build and run tests"
	@echo "  make benchmark    Build and run benchmarks"
	@echo "  make example      Build and run WSL integration example"
	@echo "  make check-cpu    Check if CPU supports AVX-512"
	@echo "  make clean        Remove build artifacts"
	@echo "  make help         Display this help message"
	@echo ""
	@echo "Compilation flags:"
	@echo "  -mavx512f         AVX-512 Foundation instructions"
	@echo "  -mavx512bw        AVX-512 Byte/Word instructions"
	@echo "  -O3               Maximum optimization"
	@echo ""
