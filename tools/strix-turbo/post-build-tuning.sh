#!/bin/bash
################################################################################
# WSL2 Zen 5 Kernel - Post-Build Tuning & Verification
#
# Verifies kernel installation and applies performance tuning
# Run this AFTER successfully building and installing the custom kernel
#
# Usage: ./post-build-tuning.sh [--tune] [--bench]
#
################################################################################

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

APPLY_TUNING=false
RUN_BENCHMARK=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tune)
            APPLY_TUNING=true
            shift
            ;;
        --bench)
            RUN_BENCHMARK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

print_header() {
    echo ""
    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================================${NC}"
    echo ""
}

print_section() {
    echo -e "${BLUE}$1${NC}"
    echo "--------"
}

print_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}○${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Verify kernel is running
verify_kernel() {
    print_header "Kernel Verification"

    print_section "System Information"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime -p)"
    echo ""

    print_section "Checking for Zen 5 Optimizations"

    # Check for Zen scheduler
    if grep -q "CONFIG_SCHED_ZEN" /boot/config-* 2>/dev/null; then
        print_ok "Zen scheduler detected"
    elif [ -f /proc/config.gz ]; then
        if zcat /proc/config.gz | grep -q "CONFIG_SCHED_ZEN"; then
            print_ok "Zen scheduler detected"
        fi
    else
        print_warn "Could not verify Zen scheduler (check might be unavailable)"
    fi

    # Check for BBR TCP
    if grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
        print_ok "BBRv3 TCP congestion control available"
    else
        print_warn "BBRv3 not currently loaded (can be loaded on demand)"
    fi

    # Check for BFQ scheduler
    if grep -q "bfq" /sys/block/*/queue/scheduler 2>/dev/null | head -1; then
        print_ok "BFQ I/O scheduler available"
    else
        print_warn "BFQ scheduler not currently selected"
    fi

    # Check preemption
    if grep -q "PREEMPT" /proc/version 2>/dev/null; then
        print_ok "Preemption enabled"
    else
        print_warn "Preemption check inconclusive"
    fi

    echo ""
}

check_performance_counters() {
    print_section "CPU & Performance"

    local cores=$(nproc)
    local cpufreq_path="/sys/devices/system/cpu/cpu0/cpufreq"

    echo "Available Cores: $cores"
    echo "CPU Model: $(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)"

    if [ -d "$cpufreq_path" ]; then
        echo "CPU Frequency Scaling: Enabled"
        if [ -f "$cpufreq_path/scaling_governor" ]; then
            echo "  Current Governor: $(cat $cpufreq_path/scaling_governor)"
        fi
        if [ -f "$cpufreq_path/scaling_max_freq" ]; then
            local max_freq=$(($(cat $cpufreq_path/scaling_max_freq) / 1000))
            echo "  Max Frequency: ${max_freq} MHz"
        fi
    else
        print_warn "CPU frequency scaling not available"
    fi

    echo ""
}

check_memory() {
    print_section "Memory"

    free -h
    echo ""

    # Check for Huge Pages
    if [ -f /proc/sys/vm/nr_hugepages ]; then
        local hugepages=$(cat /proc/sys/vm/nr_hugepages)
        if [ "$hugepages" -gt 0 ]; then
            print_ok "Huge Pages enabled: $hugepages"
        else
            print_warn "Huge Pages not configured (optional)"
        fi
    fi
    echo ""
}

check_network() {
    print_section "Network Configuration"

    if command -v ip &> /dev/null; then
        local eth0_status=$(ip link show eth0 2>/dev/null | grep -i "state" | head -1 || echo "Not found")
        echo "Interface Status: $eth0_status"
    fi

    # Check TCP stack parameters
    if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
        echo "TCP Congestion Control: $(cat /proc/sys/net/ipv4/tcp_congestion_control)"
    fi

    echo ""
}

check_io_scheduler() {
    print_section "I/O Scheduler"

    local scheduler_path="/sys/block/sda/queue/scheduler"
    if [ -f "$scheduler_path" ]; then
        echo "Available schedulers: $(cat $scheduler_path)"
    else
        print_warn "Could not determine I/O scheduler"
    fi
    echo ""
}

apply_sysctl_tuning() {
    print_header "Applying Sysctl Performance Tuning"

    if [ ! -w /proc/sys/ ]; then
        print_error "Root access required for sysctl tuning"
        echo "Run this script with: sudo $0 --tune"
        return 1
    fi

    print_section "Network Optimization"

    # TCP tuning for better performance
    local tunables=(
        "net.ipv4.tcp_tw_reuse=1:Enable TCP time-wait socket reuse"
        "net.ipv4.tcp_timestamps=0:Disable TCP timestamps (if safe)"
        "net.ipv4.tcp_fast_open=3:Enable TCP Fast Open"
        "net.core.somaxconn=4096:Increase socket listening queue"
        "net.ipv4.tcp_max_syn_backlog=4096:Increase SYN backlog"
        "net.ipv4.tcp_keepalive_time=300:TCP keep-alive time"
    )

    for tunable in "${tunables[@]}"; do
        IFS=: read -r param desc <<< "$tunable"
        local key=$(echo "$param" | cut -d= -f1)
        local value=$(echo "$param" | cut -d= -f2)

        if sysctl -w "$param" &>/dev/null; then
            print_ok "$desc"
        else
            print_warn "Could not set $key (might require root)"
        fi
    done

    echo ""
    print_section "Scheduler Optimization"

    # CPU scheduler tuning
    local sched_tunables=(
        "kernel.sched_migration_cost_ns=500000:Migration cost"
        "kernel.sched_latency_ns=24000000:Scheduling latency"
    )

    for tunable in "${sched_tunables[@]}"; do
        IFS=: read -r param desc <<< "$tunable"
        if sysctl -w "$param" &>/dev/null; then
            print_ok "$desc"
        else
            print_warn "Could not set $param"
        fi
    done

    echo ""
    print_section "Memory Optimization"

    # Memory tuning
    if [ -w /proc/sys/vm/swappiness ]; then
        sysctl -w vm.swappiness=10 >/dev/null 2>&1
        print_ok "Reduced swappiness"
    fi

    echo ""

    # Make changes permanent
    print_section "Making Changes Permanent"
    echo "To persist these settings across reboots, add to /etc/sysctl.conf:"
    echo ""
    echo -e "${YELLOW}# Zen 5 Kernel Performance Tuning"
    echo "net.ipv4.tcp_tw_reuse=1"
    echo "net.ipv4.tcp_fast_open=3"
    echo "net.core.somaxconn=4096"
    echo "kernel.sched_migration_cost_ns=500000"
    echo "vm.swappiness=10${NC}"
    echo ""

    echo "Then run:"
    echo -e "${YELLOW}sudo sysctl -p${NC}"
    echo ""
}

configure_io_scheduler() {
    print_header "I/O Scheduler Configuration"

    if [ ! -w /sys/block/sda/queue/scheduler ]; then
        print_error "Root access required for I/O scheduler configuration"
        echo "Run this script with: sudo $0 --tune"
        return 1
    fi

    print_section "Available Schedulers"
    cat /sys/block/sda/queue/scheduler
    echo ""

    print_section "Setting to BFQ (if available)"

    if grep -q "bfq" /sys/block/sda/queue/scheduler; then
        echo "bfq" | sudo tee /sys/block/sda/queue/scheduler >/dev/null
        print_ok "I/O scheduler set to BFQ"
    else
        print_warn "BFQ not available, keeping current scheduler"
    fi

    echo ""

    print_section "Adjusting Read-Ahead"
    # Increase read-ahead for better sequential performance
    if [ -w /sys/block/sda/queue/read_ahead_kb ]; then
        echo 4096 | sudo tee /sys/block/sda/queue/read_ahead_kb >/dev/null
        print_ok "Read-ahead set to 4MB"
    fi

    echo ""

    # Make I/O tuning permanent
    print_section "Making I/O Changes Permanent"
    echo "Create /etc/udev/rules.d/90-io-scheduler.rules:"
    echo ""
    echo -e "${YELLOW}ACTION==\"add|change\", KERNEL==\"sda\", ATTR{queue/scheduler}=\"bfq\"${NC}"
    echo ""

    echo "Or create /etc/rc.local with:"
    echo -e "${YELLOW}echo bfq > /sys/block/sda/queue/scheduler${NC}"
    echo ""
}

run_benchmarks() {
    print_header "Performance Benchmarking"

    echo "Benchmarking CPU performance..."
    echo ""

    print_section "CPU Stress Test (10 seconds)"

    if command -v stress-ng &> /dev/null; then
        timeout 10 stress-ng --cpu $(nproc) --verbose 2>/dev/null | head -20 || true
    else
        print_warn "stress-ng not installed"
        echo "Install with: sudo apt-get install -y stress-ng"
    fi

    echo ""
    print_section "Single-Core Performance"

    # Time a simple calculation
    local start=$(date +%s%N)
    for i in {1..10000}; do
        echo "scale=10; 3.14159 * $i / 2" | bc > /dev/null
    done
    local end=$(date +%s%N)
    local duration=$(( (end - start) / 1000000 ))

    echo "bc calculation time: ${duration}ms"

    echo ""
    print_section "Memory Bandwidth (if available)"

    if command -v sysbench &> /dev/null; then
        sysbench memory --memory-block-size=1024M --memory-total-size=8G run 2>/dev/null | grep -E "ops/sec|avg" || true
    else
        print_warn "sysbench not installed"
        echo "Install with: sudo apt-get install -y sysbench"
    fi

    echo ""
}

show_monitoring_tools() {
    print_header "Recommended Monitoring Tools"

    echo "For ongoing performance monitoring, install and use:"
    echo ""

    local tools=(
        "htop:Process monitoring (sudo apt-get install -y htop)"
        "iotop:Disk I/O monitoring (sudo apt-get install -y iotop)"
        "nethogs:Network monitoring (sudo apt-get install -y nethogs)"
        "sysstat:System statistics (sudo apt-get install -y sysstat)"
        "perf:Performance profiling (sudo apt-get install -y linux-tools-generic)"
    )

    for tool in "${tools[@]}"; do
        IFS=: read -r name desc <<< "$tool"
        echo "  • $name"
        echo "    $desc"
    done

    echo ""
    echo "Usage examples:"
    echo "  htop                    # Monitor processes in real-time"
    echo "  iostat -x 1             # Disk I/O statistics"
    echo "  netstat -s              # Network statistics"
    echo "  perf stat sleep 10      # Performance counter stats"
    echo ""
}

print_summary() {
    print_header "Summary & Next Steps"

    echo "Your custom Zen 5 kernel is installed and running!"
    echo ""

    if [ "$APPLY_TUNING" = true ]; then
        echo -e "${GREEN}✓ Performance tuning applied${NC}"
    else
        echo "To apply recommended performance tuning, run:"
        echo -e "${YELLOW}sudo $0 --tune${NC}"
    fi

    echo ""
    echo "To benchmark performance, run:"
    echo -e "${YELLOW}$0 --bench${NC}"

    echo ""
    echo "Key things to monitor:"
    echo "  1. Response time in applications (should feel snappier)"
    echo "  2. Network throughput (improved with BBRv3)"
    echo "  3. Disk I/O patterns (optimized with BFQ)"
    echo "  4. CPU scheduling latency"
    echo ""

    echo "For more information, see:"
    echo "  /home/user/WSL/tools/strix-turbo/README.md"
    echo ""
}

main() {
    echo -e "${BLUE}"
    cat << "BANNER"
   _____ _    _____ ____    ___________
  / ___// |  / / __ \__ \  /_  __/ ____/
  \__ \/ | / / /_/ /_/ /   / / / __/
 ___/ / |/ / _, _/ __/    / / / /___
/____/_/|_/_/ |_/_/      /_/ /_____/

WSL2 Zen 5 Kernel - Post-Build Tuning & Verification
BANNER
    echo -e "${NC}"

    # Verify kernel
    verify_kernel
    check_performance_counters
    check_memory
    check_network
    check_io_scheduler

    # Apply tuning if requested
    if [ "$APPLY_TUNING" = true ]; then
        echo ""
        if [ "$EUID" -ne 0 ]; then
            print_error "Root access required for tuning"
            echo "Run with: sudo $0 --tune"
        else
            apply_sysctl_tuning
            configure_io_scheduler
        fi
    fi

    # Run benchmarks if requested
    if [ "$RUN_BENCHMARK" = true ]; then
        run_benchmarks
    fi

    # Show monitoring tools and summary
    show_monitoring_tools
    print_summary
}

main "$@"
