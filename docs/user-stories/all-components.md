# WSL2 Strix Halo Performance Optimization - User Stories

**Project:** WSL2 Performance Optimization for AMD Strix Halo
**Date:** 2026-02-05
**Branch:** `claude/optimize-wsl2-performance-IZSfc`
**Target System:** AMD Ryzen AI MAX+ PRO 395 (32 cores, 94GB RAM)

---

## Table of Contents

1. [Epic 1: VirtioFS Performance Investigation and Optimization](#epic-1-virtiofs-performance-investigation--optimization)
2. [Epic 2: Benchmarking Suite](#epic-2-benchmarking-suite)
3. [Epic 3: Parasitic Batch Queue (io_uring Syscall Batching)](#epic-3-parasitic-batch-queue-io_uring-syscall-batching)
4. [Epic 4: WSL2 Service Death Spiral Incident Response](#epic-4-wsl2-service-death-spiral-incident-response)
5. [Epic 5: WSL2 Monitoring and Dashboard](#epic-5-wsl2-monitoring--dashboard)
6. [Epic 6: Docker/Service Fix Scripts and Research](#epic-6-dockerservice-fix-scripts--research)
7. [Summary Table](#summary-table)

---

## Epic 1: VirtioFS Performance Investigation and Optimization

### US-VFS-001: As a performance engineer, I want a root cause analysis of VirtioFS read performance anomalies so that I understand why large block sizes (1M+) perform worse than smaller ones (64K)
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Investigation identifies that VirtioFS lacks DAX (Direct Access) capability in the Windows WSL2 host
- Kernel messages (`virtio_fs_setup_dax: No cache capability`) are captured and documented
- 5 Whys methodology traces from symptom (slow 1M reads) to root cause (Microsoft VirtioFS implementation does not expose DAX)
- Performance data for block sizes 4K, 64K, 512K, 1M, and 4M is collected and tabulated
- Optimal block size of 64K is identified with measured throughput of 429 MB/s for sequential reads
- Comparison against tmpfs baseline (6.6 GB/s) quantifies the 15x overhead of VirtioFS without DAX

**Files:** `docs/VIRTIOFS_READ_INVESTIGATION.md`

---

### US-VFS-002: As a developer, I want documented final performance numbers after all optimization cycles so that I have a single source of truth for achieved throughput
**Priority:** Critical | **Points:** 5

**Acceptance Criteria:**
- Final report covers all 10 optimization cycles with per-cycle results
- Write performance baseline (382 MB/s) and optimized value (654 MB/s) are documented with methodology
- Read performance baseline (~400 MB/s) and optimized value (796 MB/s) are documented
- Block size comparison table covers 4K through 4M with both read and write speeds
- Each optimization cycle lists status (pass/fail), time spent, and key finding
- Local filesystem baselines (1.3 GB/s write, 9.3 GB/s read) are included as upper bounds

**Files:** `docs/PERFORMANCE_FINAL.md`

---

### US-VFS-003: As a performance engineer, I want independent validation of all performance claims so that overstated metrics are corrected before publication
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Validation tests reproduce each claimed metric with fresh dd/fio runs
- Discrepancies between claimed (668-787 MB/s) and measured (339-400 MB/s) are documented
- Block size optimality claim (256K vs verified 64K) is evaluated with timeout-resistant tests
- Parasitic batching claim (10-64 ops/batch vs measured 1 op/batch) is verified independently
- Each claim receives a pass/fail status with measured values and percentage deviation
- Validation report is usable as a gating checklist before merging performance documentation

**Files:** `docs/PERFORMANCE_VALIDATION.md`, `docs/VALIDATION_REPORT.md`

---

### US-VFS-004: As a developer, I want a summary of validation findings with clear pass/fail status so that I can quickly assess which claims are trustworthy
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Summary table lists every performance claim with target, measured, and status columns
- Four critical findings are highlighted: VirtioFS overclaimed by ~50%, block size unverified at 256K, parasitic batching broken, and 23.7x regression measured
- Document is concise (under 100 lines) and links to the full validation report for details

**Files:** `docs/VALIDATION_SUMMARY.md`

---

### US-VFS-005: As a developer, I want actionable items from the validation report so that each discrepancy has a clear owner and resolution path
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Action items cover: fix parasitic batching library, correct performance documentation, update CLAUDE.md with verified metrics, and re-run validation suite
- Each action item specifies affected files, test criteria with exact commands, and expected outputs
- Priority levels (CRITICAL, HIGH, MEDIUM) are assigned to each action item
- Parasitic batching fix action includes specific code changes needed in `batch_queue.c`

**Files:** `docs/VALIDATION_ACTION_ITEMS.md`

---

### US-VFS-006: As a performance engineer, I want a log of each optimization cycle with parameters and results so that I can reproduce any individual experiment
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Each of the 10 cycles documents: hypothesis, test commands, raw output, and conclusion
- System configuration (wslconfig, kernel parameters, VirtioFS state) is captured at cycle start
- Cycle 3 (block size optimization) includes the full block size sweep data
- Cycle 4 (parasitic batching) documents why the library was rejected with measured regression
- Cycle 9 (concurrent I/O) documents that single-stream outperforms multi-stream on VirtioFS
- Total elapsed time (43 minutes) and per-cycle timings are recorded

**Files:** `docs/OPTIMIZATION_CYCLES.md`

---

### US-VFS-007: As a developer, I want a consolidated optimization summary so that stakeholders can review improvements without reading individual cycle reports
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Before/after table covers VirtioFS write, VirtioFS read, local write, local read, and small file operations
- Optimization cycle table lists all 10 cycles with focus area, result, and time
- Key discovery section explains why 256K (or 64K per validation) block size is optimal
- Document is self-contained and does not require reading other optimization documents

**Files:** `docs/OPTIMIZATION_SUMMARY.md`

---

### US-VFS-008: As a developer, I want a user-facing performance tuning guide so that WSL2 users on Strix Halo can apply optimizations without understanding internals
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Quick start section provides a single copy-paste command for optimal block size
- Covers dd, rsync, tar, and mysqldump with correct block size flags
- I/O flags section explains oflag=direct vs oflag=sync vs buffered with use cases
- Development workflow section recommends keeping active work on Linux filesystem
- Performance summary table shows before/after for each operation type
- All commands are tested and produce the documented output on the target system

**Files:** `tools/strix-turbo/PERFORMANCE_TUNING.md`

---

### US-VFS-009: As a developer, I want a quick reference card for common VirtioFS operations so that I do not need to consult the full tuning guide during daily work
**Priority:** Low | **Points:** 2

**Acceptance Criteria:**
- Fits on a single printed page (under 60 lines of content)
- Covers: optimal block size, dd syntax, rsync syntax, file copy best practices
- Includes a "do / do not" section with common mistakes (e.g., using 1M blocks)
- No explanatory text -- command examples only with brief annotations

**Files:** `tools/strix-turbo/QUICK_REFERENCE.md`

---

### US-VFS-010: As a performance engineer, I want a VirtioFS-specific benchmark script so that I can measure filesystem throughput in isolation from other system components
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script tests sequential read, sequential write, random read, and metadata operations on VirtioFS mount
- Block size sweep covers 4K, 16K, 64K, 128K, 256K, 512K, 1M, and 4M
- Results are written to a timestamped output file in a consistent parseable format
- Script validates that /mnt/c is a VirtioFS mount before running (fails gracefully on 9p)
- Cleanup removes temporary test files after completion
- Script runs without root privileges for standard tests

**Files:** `tools/strix-turbo/virtiofs-benchmark.sh`

---

### US-VFS-011: As a developer, I want CLAUDE.md updated with verified VirtioFS performance data so that AI assistants receive accurate context about block size optimization
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- VirtioFS performance section documents 64K as optimal block size with 429 MB/s measured throughput
- DAX limitation is noted with kernel log evidence
- Performance summary table includes sequential read at 4K, 64K, and 1M block sizes
- Native tmpfs baseline (6.6 GB/s) is included for context
- Block size recommendation is consistent with VIRTIOFS_READ_INVESTIGATION.md findings

**Files:** `CLAUDE.md`

---

### US-VFS-012: As a developer, I want README.md to reflect Strix Halo performance edition branding so that the repository purpose is clear to new contributors
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- Performance table in README matches verified metrics from validation report
- Architecture diagram accurately represents the WSL2 process model
- Strix-Turbo component list is current with all tools in `tools/strix-turbo/`
- No unverified performance claims appear in the README

**Files:** `README.md`

---

## Epic 2: Benchmarking Suite

### US-BM-001: As a performance engineer, I want a comprehensive benchmark suite that tests all WSL2 performance dimensions so that I can assess system health in a single run
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Suite covers: VirtioFS throughput (read/write), local filesystem throughput, network latency, process creation time, and memory allocation speed
- Each test has a configurable iteration count and warm-up phase
- Results are written to `~/wsl-benchmark-results/benchmark-TIMESTAMP.txt` in a diff-friendly format
- Suite completes within 10 minutes on the target system with default settings
- Exit code is 0 on success, non-zero if any test fails to execute
- Script is executable without root for standard tests

**Files:** `tools/strix-turbo/benchmark-suite.sh`

---

### US-BM-002: As a performance engineer, I want a validation script that compares measured performance against documented baselines so that regressions are caught automatically
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script reads baseline values from a configuration section or file
- Each metric is compared with a configurable tolerance (default 10%)
- Output clearly marks each check as PASS or FAIL with measured vs expected values
- Script returns non-zero exit code if any critical metric fails
- Timeout handling prevents the script from hanging on slow VirtioFS operations (configurable, default 600s)

**Files:** `tools/strix-turbo/validate-performance.sh`

---

### US-BM-003: As a developer, I want a quick validation script for smoke testing so that I can verify basic WSL2 health in under 60 seconds
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Script completes in under 60 seconds on the target system
- Tests: VirtioFS mount is accessible, basic read/write works, Linux filesystem is responsive
- Output is a single PASS/FAIL line per check
- Suitable for running in CI or as a post-deploy check

**Files:** `tools/strix-turbo/validate-quick.sh`

---

### US-BM-004: As a performance engineer, I want a script that tests specific performance claims from documentation so that each documented number is independently verifiable
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Each claim from PERFORMANCE_FINAL.md and OPTIMIZATION_SUMMARY.md has a corresponding test
- Tests cover: VirtioFS write at 64K, VirtioFS read at 64K, local write, local read
- Output format: claim, expected value, measured value, pass/fail, percentage deviation
- Claims that cannot be verified (e.g., due to environment differences) are marked as SKIP with reason
- Script is idempotent and cleans up temporary files

**Files:** `tools/strix-turbo/test-claims.sh`

---

### US-BM-005: As a developer, I want a status file indicating benchmark investigation completion so that automation scripts can gate on investigation status
**Priority:** Low | **Points:** 1

**Acceptance Criteria:**
- File exists at project root when investigation is complete
- Contains date of completion and summary of findings
- Can be checked by CI scripts with a simple file-existence test

**Files:** `BENCHMARK_INVESTIGATION_COMPLETE.txt`

---

### US-BM-006: As a developer, I want a guide for restarting benchmarks after WSL restarts so that interrupted benchmark runs can be resumed correctly
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Documents the WSL restart procedure (wsl --shutdown, then relaunch)
- Explains how to verify VirtioFS is re-mounted correctly after restart
- Lists environment variables and kernel parameters that must be rechecked
- Provides commands to resume from the last completed benchmark step

**Files:** `BENCHMARK_RESTART_GUIDE.md`

---

### US-BM-007: As a performance engineer, I want a dated benchmark status report so that I can track progress across multiple benchmark sessions
**Priority:** Low | **Points:** 2

**Acceptance Criteria:**
- Report captures: date, system state, tests completed, tests pending, known issues
- Format is consistent across sessions for easy comparison
- Links to raw benchmark output files for each completed test

**Files:** `BENCHMARK_STATUS_20260205.md`

---

### US-BM-008: As a developer, I want a comprehensive benchmark guide so that new team members can run the full benchmark suite without prior knowledge
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Quick start section gets a new user from zero to first benchmark run in under 5 minutes
- Test matrix documents all configurations: baseline (9p) vs optimized (VirtioFS), stock vs Zen 5 kernel
- Step-by-step instructions cover: disabling VirtioFS for baseline, enabling for optimized, running suite, comparing results
- Troubleshooting section addresses common issues (timeouts, mount failures, permission errors)
- Results interpretation section explains what "good" numbers look like for each metric

**Files:** `tools/strix-turbo/BENCHMARK_GUIDE.md`

---

## Epic 3: Parasitic Batch Queue (io_uring Syscall Batching)

### US-PB-001: As a performance engineer, I want the parasitic batch queue to correctly batch write operations via io_uring so that multiple writes are submitted in a single kernel transition
**Priority:** Critical | **Points:** 13

**Acceptance Criteria:**
- Write operations are queued until batch size threshold (configurable, default 32) or timeout
- Batched writes are submitted via a single `io_uring_enter()` call
- Read and pread operations fall through to synchronous execution (not batched) since callers need data immediately
- `STRIX_BATCH_DEBUG=1` output shows "Flushing write batch of N operations" where N matches the configured batch size
- Test with 50 writes at batch size 10 produces 5 batches (not 50)
- Test with 80 ops at batch size 32 produces 3 batches (32 + 32 + 16)

**Files:** `tools/strix-turbo/parasitic_batch/batch_queue.c`

---

### US-PB-002: As a developer, I want a backup of the original batch queue implementation so that the pre-fix state is preserved for reference and rollback
**Priority:** Low | **Points:** 1

**Acceptance Criteria:**
- Backup file contains the exact contents of batch_queue.c before the write-only batching fix
- File is clearly named with `.backup` extension to prevent accidental compilation
- A comment at the top of the backup explains why it was preserved

**Files:** `tools/strix-turbo/parasitic_batch/batch_queue.c.backup`

---

### US-PB-003: As a developer, I want a summary of the batch queue fix so that reviewers understand what changed and why without reading the full diff
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Documents the problem: hybrid batching returned optimistic results for reads, violating POSIX semantics
- Documents the solution: write-only batching strategy where reads pass through to sync
- Lists which operations are now batched (write, pwrite, close, fsync) vs pass-through (read, pread, open, stat)
- Includes before/after code snippets showing the key change

**Files:** `tools/strix-turbo/parasitic_batch/BATCH_FIX_SUMMARY.md`

---

### US-PB-004: As a developer, I want a detailed fix report for the parasitic batch queue so that the engineering decision log captures the full rationale
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Report covers: original design intent, failure mode discovered, alternative strategies considered, chosen strategy rationale
- References the io_uring research report findings about synchronous I/O limitations
- Documents the POSIX semantics violation that caused the original failure
- Includes timeline of investigation and fix

**Files:** `tools/strix-turbo/parasitic_batch/FIX_REPORT.md`

---

### US-PB-005: As a developer, I want an implementation summary of the parasitic batching system so that the architectural overview is accessible without reading source code
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Covers: LD_PRELOAD intercept mechanism, io_uring ring buffer setup, batch queue lifecycle, flush triggers
- Explains write-only batching strategy with rationale
- Documents thread-local queue model and why it avoids locking
- Lists all intercepted libc functions and their routing (batch vs pass-through)

**Files:** `tools/strix-turbo/parasitic_batch/IMPLEMENTATION_SUMMARY.md`

---

### US-PB-006: As a developer, I want documented known issues for the parasitic batching library so that users understand edge cases before deploying
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Close-without-flush edge case is documented with reproduction steps
- Workaround (explicit fsync before close) is provided with code example
- Impact assessment (low -- most programs fsync critical data) is included
- Proposed fix code for `strix_queue_close` flushing pending operations is documented
- Verified-working test results show correct batch sizes (10, 25, 32 ops per batch)

**Files:** `tools/strix-turbo/parasitic_batch/KNOWN_ISSUES.md`

---

### US-PB-007: As a performance engineer, I want test results for the batch queue so that batching behavior is empirically verified
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Test results show ops_submitted, batches_submitted, and ratio for multiple batch sizes
- Batch size configurations tested: 10, 25, 32, 64
- Results differentiate between the broken state (1:1 ratio) and the fixed state (N:1 ratio)
- Performance comparison shows latency with and without batching for write workloads

**Files:** `tools/strix-turbo/parasitic_batch/TEST_RESULTS.md`

---

### US-PB-008: As a developer, I want a test script for Plan 9 write batching so that I can verify the library works specifically on /mnt/c operations
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script performs write operations to /mnt/c with LD_PRELOAD of the parasitic batch library
- Configurable batch size via STRIX_BATCH_SIZE environment variable
- Captures and reports actual batch sizes from debug output
- Compares performance with and without the library loaded
- Cleans up test files from /mnt/c after completion

**Files:** `tools/strix-turbo/parasitic_batch/test_plan9_writes.sh`

---

### US-PB-009: As a developer, I want a validation script for the batch queue fix so that I can confirm the fix works after any code changes
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Script builds the library, runs test operations, and checks batch ratios
- Passes if batch ratio is >= configured batch size (within tolerance)
- Fails if batch ratio is 1:1 (indicating the old broken behavior)
- Can be integrated into a pre-commit hook or CI pipeline
- Outputs clear pass/fail with diagnostic information on failure

**Files:** `tools/strix-turbo/parasitic_batch/validate_fix.sh`

---

## Epic 4: WSL2 Service Death Spiral Incident Response

### US-INC-001: As an incident responder, I want a comprehensive incident report for the wsl-pro.service death spiral so that the full timeline, impact, and resolution are documented for post-mortem review
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Incident report follows standard format: ID, severity, status, duration, affected systems
- Timeline covers from initial failure through resolution with UTC timestamps
- Detailed analysis covers: initial failure mode, restart loop cascade, systemd-journald overwhelm
- Resource impact (CPU, memory, I/O, PID risk) is quantified
- Resolution steps (systemctl mask) are documented with verification commands
- Lessons learned and preventive measures are listed

**Files:** `docs/incidents/INCIDENT-2026-02-05-wsl-pro-death-spiral.md`

---

### US-INC-002: As an SRE/operator, I want a root cause analysis with 5 Whys methodology so that the systemic causes of the death spiral are understood and prevented
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Three separate issues are analyzed: Docker iptables failure, wsl-pro.service path mismatch, and cascading restart
- Each issue has a complete 5 Whys chain from symptom to root cause
- Docker issue traces to iptables frontend/backend mismatch (nft vs legacy)
- wsl-pro issue traces to hardcoded uppercase path matching ("WINDOWS" vs "Windows") with 78% certainty
- Certainty levels are assigned to each root cause with explanation of what evidence would increase certainty
- Resolution for each issue includes exact commands to execute

**Files:** `docs/incidents/ROOT-CAUSE-ANALYSIS-FINAL.md`

---

### US-INC-003: As an incident responder, I want a quick response runbook for service death spirals so that future incidents can be resolved in under 60 seconds
**Priority:** Critical | **Points:** 5

**Acceptance Criteria:**
- 60-second fix section provides 4 commands: find service, stop, mask, verify
- Symptom checklist covers: frozen shell, restart counter flooding, time jumped errors, high PID 1 CPU
- Detailed investigation section provides commands for: identifying culprit, gathering context, analyzing root cause
- Prevention section covers systemd circuit breaker configuration
- Runbook is usable by an on-call engineer who has never seen this failure mode before

**Files:** `docs/incidents/QUICK-RESPONSE-SERVICE-DEATH-SPIRAL.md`

---

### US-INC-004: As an SRE/operator, I want a full investigation report so that the diagnostic methodology is documented for training and process improvement
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Report documents all diagnostic commands run and their output
- Evidence chain links symptoms to root cause through log analysis
- False leads and ruled-out hypotheses are documented to prevent repeated investigation
- Swarm agent deployment details (3 specialized agents) are noted for process reference
- Time from first symptom to resolution is tracked

**Files:** `docs/incidents/INVESTIGATION-REPORT-2026-02-05.md`

---

### US-INC-005: As an SRE/operator, I want session handoff notes so that the next on-call engineer has full context without re-investigating
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Current state of all three issues (Docker, wsl-pro, systemd) is summarized
- Outstanding actions are listed with priority and estimated effort
- Environment details (distro, kernel version, service states) are captured
- Known workarounds and their limitations are documented

**Files:** `docs/incidents/SESSION-HANDOFF-2026-02-05.md`

---

### US-INC-006: As a developer, I want a specific fix document for the PipelineStoppedException in the tray monitor so that the fix can be applied independently of the broader incident response
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Exception type (PipelineStoppedException) and triggering condition are documented
- Fix includes the specific code or configuration change needed
- Test procedure verifies the fix prevents the exception under the original failure conditions
- Impact assessment confirms the fix does not affect normal tray monitor operation

**Files:** `docs/incidents/wsl-tray-monitor-pipelinestoppedexception-fix.md`

---

### US-INC-007: As an SRE/operator, I want an incident closure report so that the incident lifecycle is formally completed with lessons learned
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- Closure confirms all three issues are resolved or mitigated
- Preventive measures (circuit breakers, monitoring) are confirmed deployed
- Metrics: time to detect, time to mitigate, time to resolve
- Follow-up actions with owners and due dates are listed
- Closure is signed off with date

**Files:** `docs/incidents/INCIDENT-CLOSURE-2026-02-05.md`

---

### US-INC-008: As an SRE/operator, I want a final incident summary so that leadership can understand the incident impact and response without reading the full report
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- One-paragraph executive summary covers: what happened, what was the impact, how was it fixed
- Key metrics: duration, affected systems, data loss (none)
- Root cause in one sentence
- Preventive measures in bullet list
- Document is under 50 lines

**Files:** `docs/incidents/FINAL-SUMMARY-2026-02-05.md`

---

### US-INC-009: As an SRE/operator, I want an index of all incident reports so that I can find past incidents by date, severity, or affected component
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- Table lists all incidents with: ID, date, severity, title, status, link to report
- Sorted by date (newest first)
- Includes brief one-line description for each incident
- Updated whenever a new incident report is added

**Files:** `docs/incidents/README.md`

---

## Epic 5: WSL2 Monitoring and Dashboard

### US-MON-001: As an SRE/operator, I want a PowerShell GUI dashboard for WSL2 health so that I can monitor distribution status, memory, CPU, and I/O in real time
**Priority:** Critical | **Points:** 13

**Acceptance Criteria:**
- Dashboard displays: distribution status (running/stopped), memory usage per distro, CPU utilization, disk I/O, network throughput
- Performance graphs update at configurable intervals (default 5 seconds)
- Error log viewer with filtering by severity and source
- Export functionality for logs and metrics (CSV format)
- Quick-action buttons: start/stop distro, restart WSL, open terminal
- Dashboard works on Windows 10 and Windows 11 with PowerShell 5.1+

**Files:** `tools/monitoring/WSL2-Dashboard.ps1`

---

### US-MON-002: As an SRE/operator, I want a system tray monitor with color-coded health status so that I am alerted to WSL2 issues without keeping a dashboard window open
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Tray icon color: green (healthy), yellow (warning), red (error)
- Hover tooltip shows: running distro count, memory usage, uptime
- Right-click context menu provides: open dashboard, restart WSL, view errors, exit
- Auto-refresh every 5 seconds
- Smart alerting for: high memory (>90%), high CPU (>85%), crash detection, restart loops, disk space warnings
- Runs without elevated privileges for monitoring (admin required for restart actions)

**Files:** `tools/monitoring/WSL2-TrayMonitor.ps1`

---

### US-MON-003: As a developer, I want a simplified tray monitor variant so that systems with limited resources can still have basic WSL2 monitoring
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Reduced feature set: status icon, basic tooltip, restart option
- Lower resource footprint than full tray monitor (fewer timers, no graphs)
- Suitable for always-on monitoring without impacting development workload
- Works on PowerShell 5.1 without additional modules

**Files:** `tools/monitoring/WSL2-TrayMonitor-Simple.ps1`

---

### US-MON-004: As an SRE/operator, I want a balanced tray monitor that provides alerting without full dashboard overhead so that I get the right level of monitoring for production use
**Priority:** Medium | **Points:** 5

**Acceptance Criteria:**
- Feature set between simple and full: includes alerting, basic metrics, but no performance graphs
- Error detection for service restart loops is included
- Memory and CPU threshold alerts are configurable
- Context menu includes quick diagnostic actions
- Timer intervals are optimized to reduce CPU overhead while maintaining responsiveness

**Files:** `tools/monitoring/WSL2-TrayMonitor-Balanced.ps1`

---

### US-MON-005: As a performance engineer, I want a PowerShell performance monitoring module so that I can programmatically collect WSL2 metrics from scripts and automation
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Module exports functions: Get-WSL2Performance, Get-WSL2Memory, Get-WSL2DiskIO, Get-WSL2Network
- Output objects are pipeline-friendly (PSCustomObject with typed properties)
- Supports collection intervals and aggregation (average, max, min over time window)
- Can be imported independently of the dashboard/tray monitor
- Includes Pester tests or equivalent validation

**Files:** `tools/monitoring/WSL2-Performance.psm1`

---

### US-MON-006: As an SRE/operator, I want an error detection module that catches service death spirals and other critical failures so that automated remediation can be triggered
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Module queries Windows Event Log for WslService, wsl.exe, wslhost.exe, wslrelay.exe, and wslg.exe events
- Errors are categorized by severity: Critical (crashes), Warning (restarts), Info (normal)
- WSL2Error class captures: timestamp, severity, source, message, and details hashtable
- Configurable lookback window (default 24 hours)
- Service restart loop detection triggers when restart count exceeds threshold within time window
- VirtioFS status check detects mount failures
- Module works with PowerShell 5.1 and 7.x

**Files:** `tools/monitoring/WSL2-ErrorDetection.psm1`

---

### US-MON-007: As a developer, I want an automated installer for the monitoring suite so that setup is a single command with no manual configuration
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Installer creates scheduled task for tray monitor auto-start
- Optional desktop shortcut creation via `-CreateShortcut` flag
- Validates prerequisites: PowerShell version, WSL2 installed, Windows version
- Skip test run via `-NoTest` flag for headless installation
- Idempotent: running twice does not create duplicate tasks or shortcuts
- Uninstaller cleanly removes all components (scheduled task, shortcuts, config files)

**Files:** `tools/monitoring/Install-WSL2Monitor.ps1`, `tools/monitoring/Uninstall-WSL2Monitor.ps1`

---

### US-MON-008: As a developer, I want compatibility tests for the monitoring suite so that PowerShell version issues are caught before deployment
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- Tests verify: WinForms availability, timer functionality, event log access, WSL command availability
- Test for timer safety verifies that rapid timer callbacks do not cause resource leaks
- PowerShell 7 compatibility notes document known differences and workarounds
- Tests can be run non-interactively and produce pass/fail output

**Files:** `tools/monitoring/test-compatibility.ps1`, `tools/monitoring/test-timer-safety.ps1`, `tools/monitoring/POWERSHELL7-COMPATIBILITY.md`

---

### US-MON-009: As a performance engineer, I want documented performance optimizations for the monitoring tools so that the monitors themselves do not degrade WSL2 performance
**Priority:** Medium | **Points:** 3

**Acceptance Criteria:**
- CPU overhead of tray monitor is measured and documented (target: <1% idle, <3% during updates)
- Memory footprint is measured for each monitor variant (simple, balanced, full)
- Timer interval trade-offs are documented (responsiveness vs overhead)
- Recommendations for which variant to use based on system resources are provided

**Files:** `tools/monitoring/PERFORMANCE_OPTIMIZATIONS.md`

---

### US-MON-010: As an SRE/operator, I want a Linux-side script to check for service restart patterns so that death spirals can be detected from within WSL2 itself
**Priority:** High | **Points:** 3

**Acceptance Criteria:**
- Script queries journalctl for "restart counter" messages within configurable time window
- Outputs: service name, restart count, time range, severity assessment
- Returns non-zero exit code if any service exceeds restart threshold
- Can be run from cron or systemd timer for periodic monitoring
- Integrates with the Windows-side error detection module via shared state file

**Files:** `tools/monitoring/check-service-restarts.sh`

---

### US-MON-011: As a developer, I want monitoring suite documentation so that all monitoring tools are discoverable from a single entry point
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- README lists all tools with: name, platform (Windows/Linux), and one-line purpose
- Installation and quick start sections are present
- Links to individual tool documentation for detailed usage
- Feature comparison table for tray monitor variants (simple, balanced, full)

**Files:** `tools/monitoring/README.md`

---

## Epic 6: Docker/Service Fix Scripts and Research

### US-FIX-001: As an SRE/operator, I want a Docker fix script that resolves the iptables frontend/backend mismatch so that Docker can run in WSL2 alongside nftables
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Script configures Docker daemon.json with iptables-legacy path
- Installs systemd global circuit breaker (StartLimitIntervalSec=120, StartLimitBurst=5, RestartSec=5s) to prevent death spirals
- Reloads systemd and restarts Docker with reset-failed handling
- Verifies Docker is running with `docker info` after fix
- Script is idempotent: safe to run multiple times
- Uses `set -euo pipefail` for safe execution

**Files:** `tools/apply-docker-fix.sh`

---

### US-FIX-002: As an SRE/operator, I want a root cause fix script that applies all fixes from the incident investigation so that the system is hardened against all identified failure modes
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Applies fixes for: Docker iptables (daemon.json + iptables-legacy), wsl-pro.service (mask if broken), systemd circuit breakers
- Each fix step has a verification check that confirms success
- Script reports which fixes were already applied vs newly applied
- Rollback instructions are documented in script comments
- Script requires explicit confirmation before applying changes (unless --yes flag is passed)

**Files:** `tools/apply-root-cause-fixes.sh`

---

### US-FIX-003: As a performance engineer, I want a research report on io_uring batching feasibility so that architectural decisions about syscall batching are backed by evidence
**Priority:** Critical | **Points:** 8

**Acceptance Criteria:**
- Report covers how io_uring works (SQ/CQ ring buffers, io_uring_enter)
- Documents the fundamental limitation: synchronous read/write cannot be batched via LD_PRELOAD because callers need results immediately
- Explains why io_uring bypasses LD_PRELOAD by design (direct syscall, no libc calls)
- Identifies what CAN be batched: write-behind caching, close operations, fsync
- Recommends pivot from LD_PRELOAD batching to: shared memory IPC, async I/O wrappers, write-behind caching
- Addresses the root cause: 9P protocol overhead, and evaluates bypass strategies

**Files:** `docs/research/io_uring_batching_research_report.md`

---

### US-FIX-004: As a developer, I want a VirtioFS troubleshooting guide so that common configuration errors (fstab mistakes, device name mismatches) are resolvable without deep investigation
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Covers the most common error: "Processing /etc/fstab with mount -a failed"
- Documents root cause: incorrect virtiofs device names (drvfsaC0 vs drvfsC0, C: vs actual tag)
- Diagnostic steps: verify VirtioFS enabled in .wslconfig, discover actual device names via dmesg, check fstab
- Solution provides correct fstab syntax with verified device tag format
- Covers VS Code connection failures caused by mount errors
- Includes preventive measures to avoid recurrence

**Files:** `docs/wsl-virtiofs-troubleshooting.md`

---

### US-FIX-005: As a performance engineer, I want the io_uring research to evaluate shared memory IPC as an alternative to 9P protocol so that a path to 10x performance improvement is documented
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- Shared memory IPC bypass strategy is described with architectural diagram
- Expected performance improvement (bypassing FUSE protocol overhead) is estimated
- Implementation complexity and risks are assessed
- Comparison with other approaches (VirtioFS DAX, modified 9P, RDMA) is provided
- Recommendation includes next steps for prototyping

**Files:** `docs/research/io_uring_batching_research_report.md`

---

### US-FIX-006: As an SRE/operator, I want systemd circuit breaker configuration so that no service can enter an unbounded restart loop and destabilize the WSL2 instance
**Priority:** Critical | **Points:** 3

**Acceptance Criteria:**
- Global circuit breaker drop-in is installed at `/etc/systemd/system/service.d/10-circuit-breaker.conf`
- Configuration limits: max 5 restarts in 120 seconds, then stop; RestartSec=5s to slow retry
- Applied via systemctl daemon-reload without requiring WSL restart
- Verified by triggering a test service failure and confirming it stops after 5 attempts
- Does not interfere with critical services that have their own restart configuration

**Files:** `tools/apply-docker-fix.sh`, `tools/apply-root-cause-fixes.sh`

---

### US-FIX-007: As a developer, I want the Docker fix to handle the case where Docker Desktop is preferred over native Docker in WSL2 so that the simpler architecture is documented and supported
**Priority:** Medium | **Points:** 2

**Acceptance Criteria:**
- Documents that WSL2 can access Docker Desktop from Windows without native Docker
- Provides commands to stop, disable, and mask Docker services in WSL2
- Explains the rationale: simpler architecture, avoids iptables complexity
- Alternative path: fix native Docker with iptables-legacy if Docker Desktop is not available

**Files:** `tools/apply-docker-fix.sh`, `docs/incidents/ROOT-CAUSE-ANALYSIS-FINAL.md`

---

### US-FIX-008: As a performance engineer, I want the research report to quantify the performance cost of each layer in the VirtioFS I/O path so that optimization efforts target the largest bottleneck
**Priority:** High | **Points:** 5

**Acceptance Criteria:**
- I/O path breakdown: application -> libc -> FUSE -> VirtioFS -> host filesystem
- Each layer's overhead is estimated or measured (latency and throughput impact)
- The dominant bottleneck (FUSE protocol without DAX) is identified with data
- Comparison: VirtioFS without DAX (429 MB/s) vs with DAX (estimated 2+ GB/s) vs native (6.6 GB/s)
- Quantifies the theoretical maximum improvement achievable by each optimization strategy

**Files:** `docs/research/io_uring_batching_research_report.md`

---

## Summary Table

| Epic | ID Range | Story Count | Total Points | Critical | High | Medium | Low |
|------|----------|-------------|--------------|----------|------|--------|-----|
| **1. VirtioFS Performance** | US-VFS-001 to US-VFS-012 | 12 | 54 | 3 | 5 | 3 | 1 |
| **2. Benchmarking Suite** | US-BM-001 to US-BM-008 | 8 | 32 | 1 | 3 | 2 | 2 |
| **3. Parasitic Batch Queue** | US-PB-001 to US-PB-009 | 9 | 37 | 1 | 3 | 4 | 1 |
| **4. Incident Response** | US-INC-001 to US-INC-009 | 9 | 38 | 3 | 3 | 3 | 0 |
| **5. Monitoring and Dashboard** | US-MON-001 to US-MON-011 | 11 | 58 | 3 | 4 | 4 | 0 |
| **6. Docker/Fixes/Research** | US-FIX-001 to US-FIX-008 | 8 | 38 | 2 | 4 | 1 | 0 |
| **TOTAL** | | **57** | **257** | **13** | **22** | **17** | **4** |

### Priority Distribution

| Priority | Count | Percentage | Total Points |
|----------|-------|------------|--------------|
| Critical | 13 | 22.8% | 99 |
| High | 22 | 38.6% | 105 |
| Medium | 18 | 31.6% | 45 |
| Low | 4 | 7.0% | 8 |

### Points Distribution by Size

| Size (Points) | Count | Category |
|---------------|-------|----------|
| 1-2 | 9 | Trivial / Small |
| 3 | 14 | Small |
| 5 | 17 | Medium |
| 8 | 10 | Large |
| 13 | 2 | Extra Large |

### Roles Covered

| Role | Story Count | Primary Epics |
|------|-------------|---------------|
| Performance Engineer | 18 | VirtioFS, Benchmarking, Parasitic Batch, Research |
| Developer | 22 | VirtioFS, Parasitic Batch, Monitoring, Fixes |
| SRE/Operator | 14 | Incident Response, Monitoring, Fixes |
| Incident Responder | 3 | Incident Response |

---

*Generated for the WSL2 Strix Halo Performance Optimization project on 2026-02-05.*
*Branch: `claude/optimize-wsl2-performance-IZSfc`*
