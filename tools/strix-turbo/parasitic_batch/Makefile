# Strix-Turbo Parasitic Batch Library Makefile

CC ?= gcc
CFLAGS = -Wall -Wextra -O3 -fPIC -pthread
CFLAGS += -march=native -mtune=native
CFLAGS += -D_GNU_SOURCE
LDFLAGS = -shared -ldl -luring -lpthread

# Debug build
ifdef DEBUG
CFLAGS += -g -DDEBUG -O0
endif

# Source files
LIB_SRCS = libparasitic_batch.c batch_queue.c uring_backend.c config.c
LIB_OBJS = $(LIB_SRCS:.c=.o)

# Output
LIB_NAME = libparasitic_batch.so
TEST_NAME = test_parasitic
BENCH_NAME = bench_parasitic

.PHONY: all clean install test bench

all: $(LIB_NAME)

$(LIB_NAME): $(LIB_OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Built $(LIB_NAME)"
	@echo ""
	@echo "Usage:"
	@echo "  LD_PRELOAD=$(PWD)/$(LIB_NAME) your_program"
	@echo ""
	@echo "Environment variables:"
	@echo "  STRIX_BATCH_ENABLE=1       Enable batching (default)"
	@echo "  STRIX_BATCH_SIZE=64        Operations per batch"
	@echo "  STRIX_BATCH_TIMEOUT=1000   Flush timeout (microseconds)"
	@echo "  STRIX_BATCH_DEBUG=1        Enable debug logging"

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Test program
test_parasitic: test_parasitic.c
	$(CC) $(CFLAGS) -o $@ $< -ldl

test: $(LIB_NAME) test_parasitic
	@echo "Running tests without batching..."
	./test_parasitic
	@echo ""
	@echo "Running tests with batching..."
	LD_PRELOAD=./$(LIB_NAME) STRIX_BATCH_DEBUG=1 ./test_parasitic
	@echo ""
	@echo "Tests complete."

# Benchmark
bench_parasitic: bench_parasitic.c
	$(CC) $(CFLAGS) -o $@ $<

bench: $(LIB_NAME) bench_parasitic
	@echo "=== Benchmark WITHOUT batching ==="
	./bench_parasitic
	@echo ""
	@echo "=== Benchmark WITH batching ==="
	LD_PRELOAD=./$(LIB_NAME) ./bench_parasitic
	@echo ""
	@echo "Benchmark complete."

# Install to /usr/local/lib
install: $(LIB_NAME)
	install -D -m 755 $(LIB_NAME) /usr/local/lib/$(LIB_NAME)
	ldconfig
	@echo "Installed to /usr/local/lib/$(LIB_NAME)"

# Uninstall
uninstall:
	rm -f /usr/local/lib/$(LIB_NAME)
	ldconfig

clean:
	rm -f $(LIB_OBJS) $(LIB_NAME) $(TEST_NAME) $(BENCH_NAME)

# Dependencies
libparasitic_batch.o: libparasitic_batch.c config.h batch_queue.h
batch_queue.o: batch_queue.c batch_queue.h uring_backend.h config.h
uring_backend.o: uring_backend.c uring_backend.h batch_queue.h config.h
config.o: config.c config.h
