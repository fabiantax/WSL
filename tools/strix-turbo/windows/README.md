# WSL Performance Monitor

A Windows system tray application that monitors WSL2 for filesystem performance issues and helps you avoid the `/mnt/c` performance trap.

![System Tray](docs/tray-icon.png)

## Features

- **Real-time Monitoring**: Detects when processes (git, npm, node, cargo, etc.) are running on slow `/mnt/c` paths
- **System Tray Warnings**: Balloon notifications when performance issues are detected
- **Status Icon**: Green (OK), Yellow (warnings), Red (errors)
- **Project Migration**: One-click migration from Windows to Linux filesystem
- **New Project Wizard**: Create projects on Linux FS with Windows symlinks
- **Dashboard**: View all current performance issues

## Installation

### Quick Install (Requires .NET 8 SDK)

```powershell
cd tools\strix-turbo\windows
.\install.ps1
```

### Build from Source

```powershell
# Debug build
.\build.ps1

# Release build
.\build.ps1 -Release

# Publish self-contained exe + install
.\build.ps1 -Publish -Install
```

### Manual Build

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

Output: `publish\WSLPerfMonitor.exe` (~70MB self-contained)

## Usage

### System Tray

After installation, look for the **W** icon in your system tray:

| Icon | Status |
|------|--------|
| 🟢 Green W | All OK - no performance issues |
| 🟡 Orange W | Warnings - some processes on slow paths |
| 🔴 Red W | Errors - critical processes (git, npm) on slow paths |

### Right-Click Menu

- **Scan Now** - Immediate performance scan with results
- **Open Dashboard** - Live dashboard showing all issues
- **Migrate Project...** - Move a Windows project to Linux FS
- **New Fast Project...** - Create project on Linux FS
- **Enable Warnings** - Toggle balloon notifications
- **Exit** - Close the monitor

### Migrate Existing Project

1. Right-click tray icon → **Migrate Project...**
2. Select your project folder on `C:\`
3. Confirm migration to `~/projects/<name>`
4. Access via `\\wsl$\Ubuntu\home\user\projects\<name>` or the created symlink

### Create New Project

1. Right-click tray icon → **New Fast Project...**
2. Enter project name
3. Choose template (bare, node, python, rust, git)
4. Project created at `~/projects/<name>` with VS Code prompt

## What It Detects

| Issue | Severity | Impact |
|-------|----------|--------|
| `git` on /mnt/c | 🔴 Error | 10-100x slower |
| `npm`/`node` on /mnt/c | 🔴 Error | 10-50x slower |
| `cargo`/`rustc` on /mnt/c | 🔴 Error | 10-50x slower |
| Shell CWD on /mnt/c | 🟡 Warning | All commands slower |
| `node_modules` on C:\ | 🟡 Warning | npm install very slow |

## Requirements

- Windows 10/11
- WSL2 with a Linux distribution installed
- .NET 8 Runtime (included in self-contained build)

## How It Works

The monitor:
1. Runs `wsl -e bash -c "..."` every 5 seconds to check processes
2. Parses process working directories from `/proc/<pid>/cwd`
3. Flags any paths starting with `/mnt/[a-z]/` as slow
4. Updates tray icon and shows notifications

## Performance Impact

- **CPU**: <0.1% (runs every 5 seconds, takes ~50ms)
- **Memory**: ~30MB (50-70MB for self-contained)
- **Network**: None
- **WSL**: Minimal - single lightweight bash command per scan

## Uninstall

```powershell
# Remove auto-start
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\WSL Performance Monitor.lnk"

# Remove Start Menu
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\WSL Performance Monitor.lnk"

# Remove program
Remove-Item -Recurse "$env:LOCALAPPDATA\Programs\WSLPerfMonitor"
```

## License

MIT
