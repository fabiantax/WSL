# Strix-Turbo NPU Client - C Library Makefile

CC ?= gcc
CFLAGS = -Wall -Wextra -O2 -fPIC
CFLAGS += -D_GNU_SOURCE
LDFLAGS = -shared

ifdef DEBUG
CFLAGS += -g -DDEBUG -O0
endif

# Source files
LIB_SRCS = strix_npu.c
LIB_OBJS = $(LIB_SRCS:.c=.o)

# Output
LIB_STATIC = libstrix_npu.a
LIB_SHARED = libstrix_npu.so
TEST_NAME = test_npu

.PHONY: all clean install test

all: $(LIB_STATIC) $(LIB_SHARED)

$(LIB_STATIC): $(LIB_OBJS)
	ar rcs $@ $^

$(LIB_SHARED): $(LIB_OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Test program
test_npu: test_npu.c $(LIB_STATIC)
	$(CC) $(CFLAGS) -o $@ $< -L. -lstrix_npu

test: test_npu
	@echo "Running tests (requires NPU bridge running on localhost:9999)..."
	./test_npu

# Install
PREFIX ?= /usr/local

install: $(LIB_STATIC) $(LIB_SHARED)
	install -d $(PREFIX)/lib
	install -d $(PREFIX)/include
	install -m 644 $(LIB_STATIC) $(PREFIX)/lib/
	install -m 755 $(LIB_SHARED) $(PREFIX)/lib/
	install -m 644 strix_npu.h $(PREFIX)/include/
	ldconfig || true

uninstall:
	rm -f $(PREFIX)/lib/$(LIB_STATIC)
	rm -f $(PREFIX)/lib/$(LIB_SHARED)
	rm -f $(PREFIX)/include/strix_npu.h
	ldconfig || true

clean:
	rm -f $(LIB_OBJS) $(LIB_STATIC) $(LIB_SHARED) $(TEST_NAME)

# Dependencies
strix_npu.o: strix_npu.c strix_npu.h
