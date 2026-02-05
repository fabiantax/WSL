# Performance Validation Summary

**Date**: 2026-02-05
**System**: AMD Strix Halo WSL2 (Zen 5 kernel)
**Status**: ❌ **CLAIMS NOT VERIFIED**

## Results at a Glance

| Claim | Target | Measured | Status |
|-------|--------|----------|--------|
| VirtioFS Write (256K) | 668 MB/s | 339 MB/s @ 64K | ❌ 51% of claim |
| VirtioFS Read (256K) | 787 MB/s | ~400 MB/s @ 64K | ❌ 51% of claim |
| Optimal Block Size | 256K | 64K | ❌ Wrong size |
| Parasitic Batching | 10-64 ops/batch | 1 op/batch | ❌ No batching |
| Performance Gain | Faster | 23.7x slower | ❌ Severe regression |

## Key Findings

### 1. VirtioFS Performance Overclaimed (50% Discrepancy)

**Claimed**: 668 MB/s write, 787 MB/s read with 256K blocks
**Measured**: 339 MB/s write, ~400 MB/s read with 64K blocks
**Evidence**:
- Latest benchmark (2026-02-05 14:28): 339 MB/s @ 64K
- Earlier benchmarks: 178-199 MB/s (varying performance)
- Historical docs: 429 MB/s @ 64K maximum

**Conclusion**: Claims are approximately 2x higher than reality.

### 2. Block Size Optimization Unverified

**Claimed**: 256K is optimal
**Documented**: 64K is optimal (VIRTIOFS_READ_INVESTIGATION.md)
**Tested**: 64K verified at 339 MB/s, 256K tests timeout

**Conclusion**: 64K remains verified optimal. No evidence for 256K superiority.

### 3. Parasitic Batching Broken (Critical Issue)

**Claimed**: Batches 10-64 operations per io_uring submission
**Measured**: 1 operation per submission (no batching)
**Impact**: 23.7x performance **degradation** instead of improvement

**Evidence from TEST_RESULTS.md**:
```
ops_submitted:     362
batches_submitted: 362
Ratio: 1:1 (should be 10-64:1)

Performance: 7.02ms → 166.40ms (-23.7x)
```

**Conclusion**: Library is fundamentally broken and should not be used.

### 4. Verification Testing Issues

- `validate-performance.sh`: Timeout after 600 seconds
- `test-claims.sh`: Tests incomplete after 2+ minutes
- `dd` operations on /mnt/c: Extremely slow

**Implication**: The slow test execution itself indicates poor performance, contradicting high-performance claims.

## What Actually Works

✅ **VirtioFS vs 1M blocks**: 64K is 1.7-1.9x faster (339 vs 178-199 MB/s)
✅ **Build System**: All components build successfully
✅ **Unit Tests**: All 8 functional tests pass
✅ **Documentation**: VIRTIOFS_READ_INVESTIGATION.md has accurate 64K data

## Critical Actions Required

1. **URGENT**: Add warning about parasitic batching (causes 23.7x slowdown)
2. **HIGH**: Fix parasitic batching library (implement actual batching)
3. **HIGH**: Update all docs to remove false 668-787 MB/s claims
4. **MEDIUM**: Revert block size recommendations to 64K
5. **MEDIUM**: Investigate why optimization cycles produced false claims

## Documentation Updates Needed

| File | Current Claim | Should Be |
|------|---------------|-----------|
| CLAUDE.md | 256K optimal? | 64K optimal (verified) |
| BENCHMARK_GUIDE.md | Mixed (64K and 256K) | 64K only |
| Any README | 668-787 MB/s | 339-400 MB/s (conservative) |
| Optimization docs | Various claims | Add validation evidence |

## Lessons Learned

1. **Always validate before claiming**: Claims were made without proper verification
2. **Multiple test runs required**: Single good result is not sufficient
3. **Watch for regressions**: Batching library degrades performance
4. **Test methodology matters**: Need proper baseline comparisons
5. **Document variance**: Performance varies between runs (178-339 MB/s)

## Next Steps

See `VALIDATION_ACTION_ITEMS.md` for detailed action plan including:
- Fix parasitic batching library
- Correct all documentation
- Implement validation requirements for future optimizations
- Establish testing standards

## Files Created

- `C:\Users\fabia\Projects\wsl\WSL\docs\VALIDATION_REPORT.md` - Full detailed report
- `C:\Users\fabia\Projects\wsl\WSL\docs\VALIDATION_ACTION_ITEMS.md` - Action items
- `C:\Users\fabia\Projects\wsl\WSL\docs\VALIDATION_SUMMARY.md` - This summary
- `C:\Users\fabia\Projects\wsl\WSL\tools\strix-turbo\validate-performance.sh` - Comprehensive test
- `C:\Users\fabia\Projects\wsl\WSL\tools\strix-turbo\validate-quick.sh` - Quick test
- `C:\Users\fabia\Projects\wsl\WSL\tools\strix-turbo\test-claims.sh` - Direct claims test

---

**Conclusion**: The claimed performance improvements from optimization cycles are **not reproducible**. Measured performance is approximately **50% of claimed values**, and the parasitic batching system **causes severe regressions** instead of improvements. Immediate corrective action is required before any further optimization work.

**Report Status**: COMPLETE
**Validation**: FAILED
**Recommended Action**: HALT new optimization claims until validation process is fixed
