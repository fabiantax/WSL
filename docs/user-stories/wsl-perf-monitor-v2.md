# User Stories: WSL Performance Monitor v2

## US-PM-005: Dark Mode Dashboard
**As a** developer using WSL Performance Monitor,
**I want** a dark-themed UI across all windows,
**So that** the tool matches my dark IDE/terminal setup and reduces eye strain.

### Acceptance Criteria
- [x] Dashboard, Scan Results, and New Project forms use dark backgrounds
- [x] ListView column headers are owner-drawn with dark theme
- [x] Buttons use flat style with dark surface colors
- [x] Error rows use dark red, warning rows use dark amber, OK rows use dark green
- [x] Context menus use dark background with light text
- [x] Theme colors defined in a central `Theme` static class

### Implementation
- `Theme` static class: VS Code-inspired palette (BgDark #1E1E1E, BgPanel #2D2D30, FgText #F1F1F1)
- Owner-drawn column headers via `DrawColumnHeader` event
- All forms set `BackColor = Theme.BgDark`, `ForeColor = Theme.FgText`
- Buttons styled via `Theme.StyleButton()` with flat style and border color

---

## US-PM-006: Kill All Zombies
**As a** developer with stuck WSL processes,
**I want** a single button to kill all zombie processes at once,
**So that** I can clean up stuck tasks without manually running kill commands.

### Acceptance Criteria
- [x] Red "Kill All Zombies" button appears only when zombies are detected
- [x] Clicking shows confirmation dialog listing PIDs to be killed
- [x] Executes `wsl -e bash -c "kill -9 <pids>"` on confirmation
- [x] Dashboard auto-refreshes after kill
- [x] Button hidden when no zombies present

### Implementation
- `_killZombiesBtn` with `Theme.Danger` background color
- `KillAllZombies()` collects PIDs from `_currentGrouped` where `IsZombie == true`
- Confirmation via `MessageBox` with PID list
- Visibility toggled in `RefreshIssues()` based on zombie presence

---

## US-PM-007: I/O Throughput Per Process
**As a** developer investigating slow /mnt/c performance,
**I want** to see which processes are generating the most disk I/O,
**So that** I can identify the heaviest hitters and prioritize migration.

### Acceptance Criteria
- [x] New "I/O" column in the dashboard between Issue and Path
- [x] Shows read and write bytes: `R:12.3 MB W:4.5 MB`
- [x] Reads from `/proc/$pid/io` (read_bytes, write_bytes fields)
- [x] Human-readable format (B, KB, MB, GB)
- [x] Results sorted by total I/O volume (heaviest first)

### Implementation
- Bash loop reads `awk '/^read_bytes:/{print $2}' /proc/$pid/io`
- Parsed as `parts[12]` (ioRead) and `parts[13]` (ioWrite) in C#
- `Theme.FormatBytes()` helper for human-readable display
- `PerformanceIssue` model: `IoReadBytes`, `IoWriteBytes` (long)
- Grouped issues sum I/O across all processes in the group

---

## US-PM-008: Group Duplicate Rows
**As a** developer with multiple similar processes on /mnt/c,
**I want** duplicate processes grouped into single rows,
**So that** the dashboard is concise and I can see aggregate impact.

### Acceptance Criteria
- [x] Processes with same name and CWD are merged into one row
- [x] Process column shows count: `3x bash` instead of 3 separate rows
- [x] I/O values are summed across grouped processes
- [x] All PIDs are collected for bulk kill operations
- [x] Severity is the maximum across the group

### Implementation
- LINQ `GroupBy` on `$"{Process}|{Path}"` key in `RefreshIssues()`
- Merged `PerformanceIssue` with aggregated Pids, summed I/O, max severity
- `_currentGrouped` list stored for KillAllZombies PID collection
- Sort: severity descending, then total I/O descending
