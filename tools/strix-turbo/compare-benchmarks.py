#!/usr/bin/env python3
"""
Compare two kernel benchmark results and show performance improvements
Usage: ./compare-benchmarks.py baseline.json optimized.json
"""

import json
import sys
from typing import Dict, Any

# ANSI colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
BLUE = '\033[0;34m'
CYAN = '\033[0;36m'
YELLOW = '\033[1;33m'
BOLD = '\033[1m'
NC = '\033[0m'  # No Color


def load_benchmark(filename: str) -> Dict[str, Any]:
    """Load benchmark JSON file"""
    with open(filename, 'r') as f:
        return json.load(f)


def calculate_improvement(baseline: float, optimized: float, lower_is_better: bool = True) -> float:
    """Calculate percentage improvement"""
    if lower_is_better:
        # For metrics where lower is better (time, latency)
        improvement = ((baseline - optimized) / baseline) * 100
    else:
        # For metrics where higher is better (bandwidth, throughput)
        improvement = ((optimized - baseline) / baseline) * 100
    return improvement


def format_improvement(improvement: float) -> str:
    """Format improvement with color coding"""
    if improvement > 0:
        return f"{GREEN}+{improvement:.1f}%{NC}"
    elif improvement < 0:
        return f"{RED}{improvement:.1f}%{NC}"
    else:
        return f"{YELLOW}0.0%{NC}"


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <baseline.json> <optimized.json>")
        sys.exit(1)

    baseline_file = sys.argv[1]
    optimized_file = sys.argv[2]

    # Load benchmarks
    try:
        baseline = load_benchmark(baseline_file)
        optimized = load_benchmark(optimized_file)
    except FileNotFoundError as e:
        print(f"{RED}Error: {e}{NC}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"{RED}Error parsing JSON: {e}{NC}")
        sys.exit(1)

    # Print header
    print(f"\n{CYAN}{'═' * 80}{NC}")
    print(f"{CYAN}  Zen 5 Kernel Performance Comparison{NC}")
    print(f"{CYAN}{'═' * 80}{NC}\n")

    print(f"{BLUE}Baseline:{NC}")
    print(f"  Kernel: {baseline['kernel_version']}")
    print(f"  Date: {baseline['timestamp']}")
    print()

    print(f"{BLUE}Optimized:{NC}")
    print(f"  Kernel: {optimized['kernel_version']}")
    print(f"  Date: {optimized['timestamp']}")
    print()

    # Define which metrics are "lower is better"
    lower_is_better = {
        'cpu_parallel_compilation': True,
        'cpu_gzip_compression': True,
        'cpu_pigz_compression_parallel': True,
        'memory_bandwidth': False,  # Higher is better
        'io_sequential_write': False,  # Higher is better
        'io_sequential_read': False,  # Higher is better
        'io_small_files_create': True,
        'syscall_overhead': True,
        'context_switch': True,
        'workflow_simulation': True,
    }

    # Benchmark descriptions
    descriptions = {
        'cpu_parallel_compilation': 'Parallel Compilation',
        'cpu_gzip_compression': 'gzip Compression',
        'cpu_pigz_compression_parallel': 'pigz Compression (parallel)',
        'memory_bandwidth': 'Memory Bandwidth',
        'io_sequential_write': 'Sequential Write',
        'io_sequential_read': 'Sequential Read',
        'io_small_files_create': 'Small Files Creation',
        'syscall_overhead': 'Syscall Overhead',
        'context_switch': 'Context Switch',
        'workflow_simulation': 'Dev Workflow',
    }

    # Compare benchmarks
    print(f"{CYAN}{'─' * 80}{NC}")
    print(f"{BOLD}{'Benchmark':<35} {'Baseline':<15} {'Optimized':<15} {'Improvement':>10}{NC}")
    print(f"{CYAN}{'─' * 80}{NC}")

    baseline_benchmarks = baseline['benchmarks']
    optimized_benchmarks = optimized['benchmarks']

    improvements = []

    for key in baseline_benchmarks.keys():
        if key not in optimized_benchmarks:
            continue

        baseline_val = float(baseline_benchmarks[key]['value'])
        optimized_val = float(optimized_benchmarks[key]['value'])
        unit = baseline_benchmarks[key]['unit']

        is_lower_better = lower_is_better.get(key, True)
        improvement = calculate_improvement(baseline_val, optimized_val, is_lower_better)
        improvements.append(improvement)

        desc = descriptions.get(key, key)
        baseline_str = f"{baseline_val:.2f} {unit}"
        optimized_str = f"{optimized_val:.2f} {unit}"
        improvement_str = format_improvement(improvement)

        print(f"{desc:<35} {baseline_str:<15} {optimized_str:<15} {improvement_str:>20}")

    print(f"{CYAN}{'─' * 80}{NC}\n")

    # Calculate average improvement
    avg_improvement = sum(improvements) / len(improvements) if improvements else 0

    print(f"{BOLD}Overall Performance:{NC}")
    if avg_improvement > 0:
        print(f"  {GREEN}✓ Average improvement: {avg_improvement:.1f}%{NC}")
        if avg_improvement >= 25:
            print(f"  {GREEN}✓ Target of 25-35% improvement: ACHIEVED!{NC}")
        else:
            print(f"  {YELLOW}⚠ Target of 25-35% improvement: In progress ({avg_improvement:.1f}% so far){NC}")
    else:
        print(f"  {RED}✗ Performance regression: {avg_improvement:.1f}%{NC}")

    # Highlight best improvements
    print(f"\n{BOLD}Top Improvements:{NC}")
    sorted_improvements = sorted(enumerate(improvements), key=lambda x: x[1], reverse=True)[:3]

    benchmark_names = list(baseline_benchmarks.keys())
    for idx, (bench_idx, improvement) in enumerate(sorted_improvements, 1):
        bench_name = descriptions.get(benchmark_names[bench_idx], benchmark_names[bench_idx])
        improvement_str = format_improvement(improvement)
        print(f"  {idx}. {bench_name}: {improvement_str}")

    print()


if __name__ == '__main__':
    main()
