#!/bin/bash
# Test write batching on Plan9 filesystem (/mnt/c)

set -e

echo "Testing parasitic batching on Plan9 filesystem (/mnt/c)"
echo "======================================================="
echo ""

# Setup
TEST_DIR="/mnt/c/Users/fabia/Projects/wsl/WSL/tools/strix-turbo/parasitic_batch/test_output"
mkdir -p ""

# Clean previous test files
rm -f ""/*.txt

echo "Test 1: Write 50 small files with batching"
echo "-------------------------------------------"

cat > /tmp/write_test.c << "EOPROG"
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char** argv) {
    const char* dir = argv[1];
    
    for (int i = 0; i < 50; i++) {
        char fname[256];
        snprintf(fname, sizeof(fname), "%s/file_%03d.txt", dir, i);
        
        int fd = open(fname, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd < 0) {
            perror("open");
            return 1;
        }
        
        char data[100];
        snprintf(data, sizeof(data), "File %d data\n", i);
        write(fd, data, strlen(data));
        close(fd);
    }
    
    return 0;
}
EOPROG

gcc -o /tmp/write_test /tmp/write_test.c

echo ""
echo "Running WITHOUT batching..."
time /tmp/write_test ""
rm -f ""/*.txt

echo ""
echo "Running WITH batching (batch_size=16)..."
STRIX_BATCH_DEBUG=1 STRIX_BATCH_SIZE=16   LD_PRELOAD=./libparasitic_batch.so   time /tmp/write_test ""

echo ""
echo "Files created: 0"
echo ""
echo "Test complete!"
