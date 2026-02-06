# Performance Validation Action Items

**Date**: 2026-02-05
**Priority**: HIGH
**Status**: URGENT CORRECTIONS REQUIRED

## Critical Findings

Validation of performance optimization claims reveals **significant discrepancies**:

1. ❌ VirtioFS performance: Claimed 668-787 MB/s, Measured 339-400 MB/s (~50% of claim)
2. ❌ Block size optimization: Claimed 256K optimal, Verified 64K remains optimal
3. ❌ Parasitic batching: Claimed 10-64 ops/batch, Measured 1 op/batch (no batching)
4. ❌ Performance improvement: Claimed faster, Measured 23.7x **slower**

## Immediate Actions Required

### 1. Fix Parasitic Batching Library (CRITICAL)

**Issue**: Library does NOT batch operations - submits 1 op per batch instead of 10-64.

**Impact**: 23.7x performance degradation instead of improvement.

**Action**:
```bash
cd tools/strix-turbo/parasitic_batch
# Review batch_queue.c - batching logic is broken
# Need to implement proper queue with:
# - Collect operations up to batch size (32-64)
# - Submit only when queue full or timeout
# - Track actual batch sizes in stats
```

**Files to Fix**:
- `batch_queue.c` - Core batching logic
- `uring_backend.c` - io_uring submission
- `config.c` - Batch size configuration

**Test Criteria**:
```bash
# After fix, this should show batch sizes 10-64:
STRIX_BATCH_DEBUG=1 STRIX_BATCH_SIZE=32 \
  LD_PRELOAD=./libparasitic_batch.so \
  bash -c 'for i in {1..100}; do cat /etc/hosts > /dev/null; done' 2>&1 | \
  grep "batch of"

# Expected output:
# "Submitted batch of 32 operations"
# NOT: "Submitted batch of 1 operations"
```

### 2. Correct Performance Documentation (HIGH)

**Issue**: Claims of 668-787 MB/s are not reproducible.

**Action**: Update all documentation with verified metrics.

**Files to Update**:

1. **CLAUDE.md**
   - Remove claims of 668-787 MB/s
   - Document verified: 339-400 MB/s @ 64K blocks
   - Keep block size recommendation at 64K

2. **BENCHMARK_GUIDE.md**
   - Revert to 64K blocks (line 119-136)
   - Remove any 256K claims
   - Update expected results table

3. **README.md** (if performance claims exist)
   - Use conservative verified numbers
   - Add "measured on AMD Strix Halo" disclaimer

4. **PERFORMANCE_TUNING.md**
   - Verify all claimed improvements
   - Add validation evidence

### 3. Remove/Warn About Parasitic Batching (HIGH)

**Issue**: Library causes severe performance regression.

**Action**: Disable or warn users until fixed.

**Changes**:

1. **Add warning to README**:
```markdown
## ⚠️ KNOWN ISSUE: Parasitic Batching

The parasitic batching library (`tools/strix-turbo/parasitic_batch/`) is
currently non-functional and causes 23.7x performance degradation.

**DO NOT USE** until issue is resolved.

Status: Under investigation (2026-02-05)
```

2. **Update installation scripts**:
```bash
# In install-strix-turbo.ps1, comment out batching installation
# Add warning message
```

### 4. Block Size Investigation (MEDIUM)

**Issue**: Discrepancy between 64K (documented) and 256K (claimed) optimal.

**Action**: Thorough block size testing with multiple runs.

**Test Plan**:
```bash
# Run 5 iterations for each block size
for bs in 4K 16K 32K 64K 128K 256K 512K 1M 2M 4M; do
  echo "Testing $bs (5 iterations):"
  for i in {1..5}; do
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    dd if=/dev/zero of=/mnt/c/temp/test256mb.dat bs=$bs count=... conv=fsync 2>&1 |
      grep -oP '\d+(\.\d+)? MB/s'
  done | awk '{sum+=$1; count++} END {print "Average:", sum/count, "MB/s"}'
done
```

**Expected Outcome**: Confirm 64K is optimal, document variance.

### 5. Review Optimization Cycle Methodology (MEDIUM)

**Issue**: Claims made without proper validation.

**Action**: Implement validation requirements for future optimizations.

**Process**:
1. ✅ Make optimization
2. ✅ Run benchmarks (3+ iterations)
3. ✅ **NEW**: Run validation suite
4. ✅ **NEW**: Require reproducible results
5. ✅ Document only verified improvements
6. ✅ Include variance/confidence intervals

**Template for Claims**:
```markdown
## Performance Improvement: [Name]

**Claimed**: X MB/s → Y MB/s (+Z%)
**Measured**: A MB/s → B MB/s (+C%)
**Variance**: ±D%
**Test Runs**: N iterations
**Reproducible**: YES/NO
**Validation Date**: YYYY-MM-DD
```

## Verification Checklist

### Pre-Commit
- [ ] Fix parasitic batching library (1:1 → 10-64 ratio)
- [ ] Update CLAUDE.md with verified metrics
- [ ] Update BENCHMARK_GUIDE.md to 64K blocks
- [ ] Add warning about parasitic batching issues
- [ ] Remove all 256K claims until verified

### Testing
- [ ] Run block size comparison (5 iterations each)
- [ ] Verify parasitic batching shows proper batch sizes
- [ ] Confirm no performance regressions
- [ ] Run full benchmark suite 3 times
- [ ] Calculate averages and variance

### Documentation
- [ ] Update VALIDATION_REPORT.md with final results
- [ ] Create PERFORMANCE_CLAIMS.md with verified metrics only
- [ ] Add "Last Validated" dates to all performance docs
- [ ] Include test methodology in docs

## Timeline

| Action | Priority | ETA | Owner |
|--------|----------|-----|-------|
| Add warnings about batching | URGENT | Immediate | - |
| Fix parasitic batching code | CRITICAL | 1-2 days | - |
| Update documentation (remove false claims) | HIGH | 1 day | - |
| Block size investigation | MEDIUM | 2-3 days | - |
| Implement validation requirements | MEDIUM | 1 week | - |

## Success Criteria

1. ✅ Parasitic batching shows 10-64 ops per batch
2. ✅ Performance improvement (not regression) from batching
3. ✅ All documentation reflects verified metrics only
4. ✅ Block size recommendation backed by evidence
5. ✅ Validation suite runs successfully
6. ✅ No false claims remain in any documentation

## Notes

- **Do not make new performance claims** until validation process is fixed
- **Be conservative** with estimates - under-promise, over-deliver
- **Include evidence** - link to benchmark results, test outputs
- **Show variance** - performance varies between runs
- **Reproducibility matters** - one good run is not enough

---

**Created**: 2026-02-05
**Status**: ACTIVE - CORRECTIONS IN PROGRESS
**Related**: VALIDATION_REPORT.md
