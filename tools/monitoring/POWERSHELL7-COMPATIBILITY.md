# PowerShell 7 Compatibility Fixes for WSL2-TrayMonitor

## Problem
The WSL2-TrayMonitor.ps1 script throws `PipelineStoppedException` when run in PowerShell 7 due to Windows Forms compatibility issues.

## Root Cause
- Windows Forms was designed for Windows PowerShell 5.1 with STA (Single-Threaded Apartment) mode
- PowerShell 7+ has different threading models and assembly loading behavior
- Event handlers in PowerShell 7 can trigger pipeline exceptions with Windows Forms controls
- Control rendering and disposal may behave differently in PowerShell 7

## Solutions Implemented

### 1. Version Detection and Auto-Relaunch
The script now detects PowerShell 7+ at startup and offers to relaunch in Windows PowerShell 5.1:
```powershell
if ($PSVersionTable.PSVersion.Major -ge 7) {
    # Prompt user and relaunch in powershell.exe (5.1)
}
```

### 2. STA Apartment State Enforcement
Verifies the script is running in STA mode, which is required for Windows Forms:
```powershell
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "Must run in STA mode"
    exit 1
}
```

### 3. Comprehensive Error Handling
All event handlers now wrapped in try-catch blocks with logging:
- Context menu click handlers
- Timer tick events
- Form event handlers (closing, button clicks)
- NotifyIcon click events

### 4. Error Logging
All errors are logged to `$env:TEMP\WSL2-TrayMonitor-YYYYMMDD.log` with:
- Timestamps
- Exception messages
- Stack traces
- Context information

## Usage

### Recommended Launch Method (Windows PowerShell 5.1)
```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\WSL2-TrayMonitor.ps1
```

### PowerShell 7 (Not Recommended)
If you must use PowerShell 7:
```powershell
pwsh.exe -File .\WSL2-TrayMonitor.ps1
```
The script will warn you and offer to relaunch in PowerShell 5.1.

### Automated Startup (Task Scheduler)
```powershell
# Create scheduled task for startup
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\path\to\WSL2-TrayMonitor.ps1`" -StartMinimized"

$trigger = New-ScheduledTaskTrigger -AtLogon

Register-ScheduledTask -TaskName "WSL2 Monitor" -Action $action -Trigger $trigger
```

## Troubleshooting

### Still Getting PipelineStoppedException?
1. Ensure you're using Windows PowerShell 5.1, not PowerShell 7
2. Verify STA mode: `[Threading.Thread]::CurrentThread.GetApartmentState()`
3. Check log file for detailed errors: `$env:TEMP\WSL2-TrayMonitor-YYYYMMDD.log`
4. Try launching with explicit `-STA` flag

### Event Handler Errors?
All event handler errors are now logged to the log file. Check there for details:
```powershell
Get-Content "$env:TEMP\WSL2-TrayMonitor-$(Get-Date -Format 'yyyyMMdd').log"
```

### Assembly Loading Failures?
If Windows Forms assemblies fail to load:
1. Verify .NET Framework 4.x is installed
2. Try repairing Visual Studio redistributables
3. Check Windows Event Viewer for .NET runtime errors

## Technical Details

### Why PowerShell 7 Has Issues
- **Threading Model**: PowerShell 7 uses .NET Core/5+, which has different threading behavior
- **Assembly Loading**: Different assembly resolution and loading paths
- **Pipeline Behavior**: PowerShell 7 pipeline error handling is more strict
- **Event Handling**: Asynchronous event handling differences

### Why STA Mode Matters
- Windows Forms controls must be accessed from the thread that created them
- STA ensures COM interop and UI thread safety
- Windows Forms message pump requires STA mode

## Best Practices

1. **Always use Windows PowerShell 5.1** for Windows Forms GUI applications
2. **Always specify -STA** when launching from external processes
3. **Wrap all event handlers** in try-catch blocks
4. **Log errors** for debugging
5. **Test on target PowerShell version** before deployment

## References
- [PowerShell Threading and Jobs](https://docs.microsoft.com/powershell/scripting/learn/deep-dives/everything-about-thread-jobs)
- [Windows Forms in PowerShell](https://docs.microsoft.com/powershell/scripting/samples/creating-a-custom-input-box)
- [STA vs MTA Apartment States](https://docs.microsoft.com/windows/win32/com/single-threaded-apartments)
