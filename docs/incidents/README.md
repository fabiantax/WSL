# WSL2 Incident Reports and Fixes

This directory contains detailed documentation of issues encountered and resolved in the WSL2 project.

## Incidents

### Active Fixes

1. **[WSL2 Tray Monitor - PipelineStoppedException Fix](wsl-tray-monitor-pipelinestoppedexception-fix.md)**
   - **Date**: 2026-02-05
   - **Component**: `tools/monitoring/WSL2-TrayMonitor.ps1`
   - **Severity**: Critical (application crash)
   - **Status**: ✅ Fixed
   - **Summary**: Timer event handler exceptions causing PipelineStoppedException in Windows PowerShell 5.1. Fixed with comprehensive error handling, StrictMode disabling, and null checks throughout timer code path.

2. **[WSL VirtioFS Troubleshooting Guide](../wsl-virtiofs-troubleshooting.md)**
   - **Component**: WSL2 filesystem performance
   - **Status**: ✅ Documented
   - **Summary**: Comprehensive guide for diagnosing and fixing VirtioFS issues, including kernel compatibility, driver problems, and configuration errors.

## Incident Report Template

When documenting new incidents, use this structure:

```markdown
# Component - Issue Title

## Incident Summary

**Date**: YYYY-MM-DD
**Component**: Path to component
**Issue**: Brief description
**Root Cause**: Technical explanation
**Status**: 🔴 Active / 🟡 In Progress / ✅ Fixed

## Problem Description

Detailed description with:
- Symptoms observed
- Error messages
- Reproduction steps
- User impact

## Root Cause Analysis

Technical analysis:
- What failed
- Why it failed
- When it fails
- Under what conditions

## Solution Implemented

Detailed fix with:
- Code changes
- Configuration changes
- Testing approach
- Verification steps

## Files Modified

List all changed files with summary of changes

## Testing Recommendations

Test cases to verify fix

## Performance Impact

Any overhead or improvements

## Related Issues

Links to related problems or fixes

## Verification

Checklist of expected behavior after fix

## Lessons Learned

Key takeaways for future development

## Future Improvements

Potential enhancements

## References

- Links to documentation
- Related issues
- External references
```

## Best Practices

### When to Create an Incident Report

Create an incident report when:

1. **Critical bugs**: Application crashes, data loss, security issues
2. **Performance regressions**: Significant slowdowns or resource usage
3. **Integration failures**: Breaking changes in dependencies
4. **User-impacting issues**: Problems affecting user experience
5. **Complex fixes**: Solutions requiring detailed explanation

### When NOT to Create an Incident Report

Skip incident reports for:

- Typos and minor documentation fixes
- Simple one-line bug fixes
- Code style updates
- Routine dependency updates
- Features (use standard commit messages)

### Naming Convention

Use this format for incident report filenames:

```
<component>-<short-description>-<type>.md

Examples:
- wsl-tray-monitor-pipelinestoppedexception-fix.md
- kernel-build-timeout-issue.md
- virtiofs-mount-failure-workaround.md
```

## Directory Structure

```
docs/incidents/
├── README.md                                           # This file
├── wsl-tray-monitor-pipelinestoppedexception-fix.md   # Tray monitor crash fix
└── [future incidents]
```

## Related Documentation

- [WSL VirtioFS Troubleshooting](../wsl-virtiofs-troubleshooting.md) - VirtioFS issues and fixes
- [Strix-Turbo Architecture](../../tools/strix-turbo/ARCHITECTURE_10X.md) - Performance optimizations
- [Benchmark Guide](../../tools/strix-turbo/BENCHMARK_GUIDE.md) - Testing methodology

## Contributing

When fixing bugs:

1. **Document first**: Create incident report before fixing (if critical)
2. **Fix thoroughly**: Address root cause, not just symptoms
3. **Test completely**: Verify fix under all conditions
4. **Update docs**: Keep incident report current with resolution
5. **Share learnings**: Document what you learned for future reference

## Issue Tracking

For tracking active issues:

- **Critical**: System crashes, data loss, security vulnerabilities
- **High**: Major functionality broken, performance regressions
- **Medium**: Features not working as expected, minor bugs
- **Low**: Cosmetic issues, nice-to-have improvements

---

**Maintained by**: WSL Development Team
**Last Updated**: 2026-02-05
