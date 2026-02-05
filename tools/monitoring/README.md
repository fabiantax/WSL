# WSL2 Monitoring Tools

Comprehensive monitoring and diagnostics tools for Windows Subsystem for Linux 2 (WSL2).

## 📊 Overview

This directory contains tools for monitoring WSL2 performance, system health, and troubleshooting issues:

| Tool | Platform | Purpose |
|------|----------|---------|
| **WSL2-TrayMonitor** | Windows | Real-time system tray monitoring with GUI |
| **check-service-restarts.sh** | Linux | Detect and prevent systemd restart storms |

---

## 🖥️ WSL2 System Tray Monitor

A PowerShell-based system tray application that provides real-time monitoring of WSL2 distributions with an interactive GUI.

### Features

- **Real-time Monitoring**
  - Distribution status (running, stopped)
  - Memory usage per distribution
  - CPU utilization tracking
  - Disk I/O statistics
  - Network throughput

- **Interactive System Tray Icon**
  - Color-coded status (green=healthy, yellow=warning, red=error)
  - Hover tooltip with quick status
  - Right-click menu for quick actions
  - Auto-refresh every 5 seconds

- **Dashboard Window**
  - Performance graphs and charts
  - Detailed distribution information
  - Error log viewer with filtering
  - Export logs and metrics
  - Quick access to common WSL commands

- **Smart Alerting**
  - High memory usage warnings (>90%)
  - High CPU usage alerts (>85%)
  - Distribution crash detection
  - Service restart loops
  - Disk space warnings

- **Quick Actions**
  - Start/stop distributions
  - Restart WSL service
  - Open WSL terminal
  - Access distribution settings
  - View recent errors

### Installation

#### Prerequisites

- Windows 10/11 with WSL2 installed
- PowerShell 5.1 or higher
- Administrator privileges (for scheduled task)

#### Automated Installation

Run the installer script as Administrator:

```powershell
# Navigate to tools/monitoring
cd C:\path\to\WSL\tools\monitoring

# Run installer
.\Install-WSL2Monitor.ps1

# Optional: Create desktop shortcut
.\Install-WSL2Monitor.ps1 -CreateShortcut

# Skip test run
.\Install-WSL2Monitor.ps1 -NoTest
```

The installer will:
1. Validate prerequisites
2. Create a scheduled task for auto-start at login
3. Configure working directory and paths
4. Test the installation
5. Optionally create desktop shortcuts

#### Manual Installation

If you prefer to run manually without auto-start:

```powershell
# Run directly (foreground)
powershell -ExecutionPolicy Bypass -File .\WSL2-TrayMonitor.ps1

# Run minimized to tray
powershell -WindowStyle Hidden -File .\WSL2-TrayMonitor.ps1 -StartMinimized

# Run with custom refresh interval
powershell -File .\WSL2-TrayMonitor.ps1 -RefreshInterval 10
```

### Usage

#### Starting the Monitor

After installation, the monitor will start automatically at login. To start manually:

```powershell
# Via scheduled task
Start-ScheduledTask -TaskName "WSL2-TrayMonitor-AutoStart"

# Or run directly
powershell -File "C:\path\to\WSL\tools\monitoring\WSL2-TrayMonitor.ps1"
```

#### System Tray Icon

The tray icon changes color based on WSL2 health:

- 🟢 **Green** - All distributions healthy
- 🟡 **Yellow** - Warning (high resource usage, non-critical errors)
- 🔴 **Red** - Error (distribution crash, service failure)
- ⚫ **Gray** - No distributions running

#### Tooltip Information

Hover over the tray icon to see:
- Number of running distributions
- Total memory usage
- Aggregate CPU usage
- Recent error count
- Last update time

**Example Tooltip:**
```
WSL2 Status: 2 running
Memory: 8.2 GB / 16.0 GB (51%)
CPU: 23%
Errors: 0
Updated: 14:32:45
```

#### Right-Click Menu

Right-click the tray icon for quick actions:

- **Open Dashboard** - Launch detailed monitoring window
- **Distributions**
  - List all distributions
  - Start/Stop individual distributions
  - Set default distribution
- **WSL Commands**
  - Open WSL Terminal
  - Restart WSL Service
  - Update WSL
  - Open WSL Settings
- **Settings**
  - Configure refresh interval
  - Set alert thresholds
  - Enable/disable notifications
- **Refresh Now** - Force immediate update
- **View Logs** - Open log directory
- **Exit** - Close the monitor

#### Dashboard Window

Double-click the tray icon to open the full dashboard:

**Performance Tab:**
- Real-time graphs (last 60 data points)
- Memory usage chart
- CPU utilization chart
- Disk I/O chart
- Network throughput chart

**Distributions Tab:**
- Table view of all distributions
- Columns: Name, State, Version, Memory, CPU, Uptime
- Start/Stop/Restart buttons per distribution
- Open terminal button
- Export distribution list

**Errors Tab:**
- Chronological error log
- Filter by severity: Info, Warning, Error, Critical
- Filter by distribution
- Search by keyword
- Export to CSV/JSON
- Clear error history

**System Tab:**
- WSL version information
- Windows kernel version
- Available distributions
- WSL service status
- Quick diagnostic checks
- Export system report

### Configuration

Configuration file location:
```
%LOCALAPPDATA%\WSL2-TrayMonitor\config.json
```

**Default Configuration:**
```json
{
  "refreshInterval": 5,
  "alertThresholds": {
    "memoryPercent": 90,
    "cpuPercent": 85,
    "diskPercent": 90
  },
  "enableNotifications": true,
  "enableSounds": false,
  "logRetentionDays": 30,
  "startMinimized": true
}
```

**Configuration Options:**

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `refreshInterval` | int | 5 | Update frequency in seconds (1-60) |
| `alertThresholds.memoryPercent` | int | 90 | Memory alert threshold (%) |
| `alertThresholds.cpuPercent` | int | 85 | CPU alert threshold (%) |
| `alertThresholds.diskPercent` | int | 90 | Disk alert threshold (%) |
| `enableNotifications` | bool | true | Show Windows notifications |
| `enableSounds` | bool | false | Play sound alerts |
| `logRetentionDays` | int | 30 | Keep logs for N days |
| `startMinimized` | bool | true | Start in system tray |

### Logs

Logs are stored in:
```
%LOCALAPPDATA%\WSL2-TrayMonitor\logs\
```

**Log Files:**
- `monitor-YYYY-MM-DD.log` - Daily monitor logs
- `errors-YYYY-MM-DD.log` - Error-only logs
- `performance-YYYY-MM-DD.csv` - Performance metrics (CSV)

**Log Rotation:**
- Logs older than `logRetentionDays` are automatically deleted
- Maximum log size: 10 MB per file
- Logs are rotated when size limit is reached

### Troubleshooting

#### Monitor Won't Start

```powershell
# Check scheduled task status
Get-ScheduledTask -TaskName "WSL2-TrayMonitor-AutoStart"

# View task history
Get-ScheduledTaskInfo -TaskName "WSL2-TrayMonitor-AutoStart"

# Check for errors
Get-EventLog -LogName Application -Source "WSL2-TrayMonitor" -Newest 10

# Run manually to see errors
powershell -File ".\WSL2-TrayMonitor.ps1" -Verbose
```

#### Tray Icon Not Visible

1. Check if process is running:
   ```powershell
   Get-Process powershell | Where-Object { $_.CommandLine -like "*WSL2-TrayMonitor*" }
   ```

2. Restart the monitor:
   ```powershell
   Stop-Process -Name powershell -Force
   Start-ScheduledTask -TaskName "WSL2-TrayMonitor-AutoStart"
   ```

3. Check system tray overflow:
   - Click the up arrow (^) in the system tray
   - Look for the WSL icon
   - Drag it to the main tray area

#### High CPU Usage

The monitor is designed to be lightweight (<2% CPU). If experiencing high CPU:

1. Increase refresh interval:
   ```powershell
   # Edit config.json
   notepad "$env:LOCALAPPDATA\WSL2-TrayMonitor\config.json"
   # Change refreshInterval to 10 or higher
   ```

2. Disable performance graphs:
   - Open Dashboard → Settings
   - Disable real-time charts

3. Check for WSL issues:
   ```powershell
   wsl --status
   wsl --list --verbose
   ```

#### Missing Metrics

If some metrics show "N/A":

1. Ensure WSL distributions are running:
   ```powershell
   wsl --list --running
   ```

2. Check WSL version (requires WSL 2):
   ```powershell
   wsl --version
   # Should show WSL version 2.0.0.0 or higher
   ```

3. Verify WSL service is running:
   ```powershell
   Get-Service LxssManager
   # Should be "Running"
   ```

#### Permissions Issues

If seeing access denied errors:

1. Run as administrator:
   ```powershell
   Start-Process powershell -Verb RunAs -ArgumentList "-File .\WSL2-TrayMonitor.ps1"
   ```

2. Check execution policy:
   ```powershell
   Get-ExecutionPolicy
   # Should be RemoteSigned or Unrestricted

   # If Restricted, change it:
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

### Uninstallation

#### Automated Uninstallation

```powershell
# Basic uninstall (keeps logs)
.\Uninstall-WSL2Monitor.ps1

# Complete removal (removes logs and shortcuts)
.\Uninstall-WSL2Monitor.ps1 -RemoveLogs -RemoveShortcuts
```

#### Manual Uninstallation

1. Stop the monitor:
   ```powershell
   Get-Process powershell | Where-Object { $_.CommandLine -like "*WSL2-TrayMonitor*" } | Stop-Process
   ```

2. Remove scheduled task:
   ```powershell
   Unregister-ScheduledTask -TaskName "WSL2-TrayMonitor-AutoStart" -Confirm:$false
   ```

3. Remove logs and config:
   ```powershell
   Remove-Item -Path "$env:LOCALAPPDATA\WSL2-TrayMonitor" -Recurse -Force
   ```

4. Remove desktop shortcuts (if created):
   ```powershell
   Remove-Item -Path "$env:USERPROFILE\Desktop\WSL2 Monitor.lnk" -ErrorAction SilentlyContinue
   ```

---

## 🐧 Linux Service Monitor

**Script:** `check-service-restarts.sh`

Monitors systemd services for restart storms and automatically prevents system instability.

### Features

- Detects services restarting more than 3 times in 5 minutes
- Automatically stops and masks services with >10 restarts
- Logs all events to `/var/log/service-restart-monitor.log`
- Creates alerts in `/tmp/service-restart-alert.txt`
- Integrates with system logger

### Installation

```bash
# Make executable
chmod +x check-service-restarts.sh

# Install to system
sudo cp check-service-restarts.sh /usr/local/bin/

# Add to crontab (run every 5 minutes)
sudo crontab -e
# Add line:
*/5 * * * * /usr/local/bin/check-service-restarts.sh
```

### Usage

```bash
# Run manually
sudo /usr/local/bin/check-service-restarts.sh

# View logs
tail -f /var/log/service-restart-monitor.log

# Check for alerts
cat /tmp/service-restart-alert.txt
```

### Configuration

Edit the script to adjust thresholds:

```bash
THRESHOLD=3              # Alert after 3 restarts
WINDOW="5 minutes ago"   # Time window to check
AUTO_MASK_COUNT=10       # Auto-mask after 10 restarts
```

---

## 🔧 Advanced Usage

### Integration with WSL2 Performance Monitoring

Combine both tools for comprehensive monitoring:

**Windows Side (PowerShell):**
```powershell
# Monitor WSL2 host metrics
.\WSL2-TrayMonitor.ps1
```

**Linux Side (within WSL):**
```bash
# Monitor systemd services
*/5 * * * * /usr/local/bin/check-service-restarts.sh

# Export metrics for Windows monitor
wsl --exec bash -c "systemctl status | grep -E 'active|failed'" > /mnt/c/wsl-status.txt
```

### Automation Examples

**Auto-restart on crash:**
```powershell
# Add to scheduled task settings
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
```

**Email alerts (requires SMTP configuration):**
```powershell
# In WSL2-TrayMonitor.ps1, add email function
function Send-Alert {
    param($Subject, $Body)
    Send-MailMessage -To "admin@example.com" -From "wsl-monitor@localhost" -Subject $Subject -Body $Body -SmtpServer "smtp.example.com"
}
```

**Slack notifications:**
```bash
# In check-service-restarts.sh, add webhook
curl -X POST -H 'Content-type: application/json' \
  --data "{\"text\":\"Service restart storm: $service - $count restarts\"}" \
  https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

---

## 📸 Screenshots

### System Tray Icon
- **Healthy State:** Green icon with "WSL2: 2 running, 51% memory"
- **Warning State:** Yellow icon with "WSL2: High CPU (87%)"
- **Error State:** Red icon with "WSL2: Distribution crashed"

### Dashboard Window
- **Performance Tab:** Four real-time graphs showing memory, CPU, disk, network
- **Distributions Tab:** Table with distribution names, status, metrics
- **Errors Tab:** Filtered log viewer with severity indicators
- **System Tab:** WSL version info and diagnostic buttons

### Right-Click Menu
```
┌────────────────────────────┐
│ Open Dashboard             │
├────────────────────────────┤
│ Distributions             >│
│   ├─ Ubuntu (Running)      │
│   ├─ Debian (Stopped)      │
│   └─ Alpine (Running)      │
├────────────────────────────┤
│ WSL Commands              >│
│   ├─ Open Terminal         │
│   ├─ Restart Service       │
│   ├─ Update WSL            │
│   └─ Settings              │
├────────────────────────────┤
│ Refresh Now                │
│ View Logs                  │
│ Settings                   │
│ Exit                       │
└────────────────────────────┘
```

---

## 🤝 Contributing

Contributions are welcome! Please see the main [CONTRIBUTING.md](../../CONTRIBUTING.md) for guidelines.

### Development Setup

```powershell
# Clone repository
git clone https://github.com/microsoft/WSL.git
cd WSL/tools/monitoring

# Test monitor
powershell -File .\WSL2-TrayMonitor.ps1 -Verbose

# Run linters
# PowerShell: Use PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path .\WSL2-TrayMonitor.ps1

# Bash: Use shellcheck
shellcheck check-service-restarts.sh
```

---

## 📝 License

These tools are part of the WSL project and are licensed under the MIT License. See [LICENSE](../../LICENSE) for details.

---

## 🔗 Related Documentation

- [WSL Documentation](https://learn.microsoft.com/windows/wsl/)
- [WSL Troubleshooting Guide](../../docs/wsl-virtiofs-troubleshooting.md)
- [Strix-Turbo Performance Suite](../strix-turbo/README.md)
- [WSL Architecture](../../doc/docs/technical-documentation/)

---

## 💬 Support

- **Issues:** [GitHub Issues](https://github.com/microsoft/WSL/issues)
- **Discussions:** [GitHub Discussions](https://github.com/microsoft/WSL/discussions)
- **Documentation:** [WSL Docs](https://aka.ms/wsldocs)
