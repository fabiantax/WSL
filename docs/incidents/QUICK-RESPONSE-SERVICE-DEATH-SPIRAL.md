# Quick Response: Service Death Spiral

## 🚨 Emergency Checklist

When you see these symptoms:
- ✅ Shell is frozen or extremely slow
- ✅ `journalctl` shows "restart counter" messages flooding
- ✅ `systemd-journald` errors about time jumping
- ✅ High CPU on systemd (PID 1)

**You have a service death spiral!**

---

## ⚡ 60-Second Fix

```bash
# 1. Find the problematic service (look for high restart counter)
journalctl --since "5 minutes ago" | grep "restart counter" | tail

# 2. Stop it immediately
sudo systemctl stop <SERVICE_NAME>

# 3. Prevent restart
sudo systemctl mask <SERVICE_NAME>

# 4. Verify it's stopped
systemctl status <SERVICE_NAME>
# Should show: "Loaded: masked"
```

**Done!** System should stabilize immediately.

---

## 🔍 Detailed Investigation

### Step 1: Identify the Culprit

```bash
# See which services are failing
systemctl list-units --failed

# Check recent restart activity
journalctl -p err --since "10 minutes ago" | grep -E "restart|failed"

# Find services with high restart counts
journalctl --since "1 hour ago" | grep "restart counter is at" | \
  awk '{for(i=1;i<=NF;i++) if($i~/^restart/) print $(i-1), $(i+1), $(i+2)}' | \
  sort -k3 -n | tail
```

### Step 2: Gather Context

```bash
# Full service status
systemctl status <SERVICE_NAME>

# Recent logs for this service
journalctl -u <SERVICE_NAME> --since "1 hour ago"

# Check service configuration
systemctl cat <SERVICE_NAME>
```

### Step 3: Determine Root Cause

**Common causes**:
1. **Missing dependencies**: Service tries to start before dependencies ready
2. **Configuration error**: Invalid config file or missing files
3. **WSL incompatibility**: Service expects hardware/features not available in WSL
4. **Permission issues**: Service can't access required resources
5. **Network issues**: Service needs external connectivity

---

## 🛡️ Permanent Fix Options

### Option 1: Mask Service (Recommended if not needed)

```bash
# Prevent service from EVER starting
sudo systemctl mask <SERVICE_NAME>

# To undo later (if needed)
sudo systemctl unmask <SERVICE_NAME>
```

**Use when**: Service is not needed in your WSL environment

### Option 2: Fix Configuration

```bash
# Edit service configuration
sudo systemctl edit <SERVICE_NAME>

# Add these safety limits:
[Service]
RestartSec=5s              # Wait 5 seconds between restarts
StartLimitBurst=3          # Max 3 restarts
StartLimitInterval=60s     # Within 60 second window
StartLimitAction=none      # Just stop trying

# Save and reload
sudo systemctl daemon-reload

# Try starting again
sudo systemctl start <SERVICE_NAME>
```

**Use when**: You need the service but want to prevent runaway restarts

### Option 3: Fix Root Cause

```bash
# Example: Fix missing dependency
sudo systemctl edit <SERVICE_NAME>

# Add:
[Unit]
After=network-online.target
Wants=network-online.target

# Or fix permissions
sudo chown -R <user>:<group> /path/to/service/files
```

**Use when**: Service is needed and you can fix the underlying issue

---

## 🔧 WSL-Specific Service Management

### Known Problematic Services in WSL

```bash
# Mask all known problematic services at once
sudo systemctl mask \
  wsl-pro.service \
  snapd.service \
  snapd.socket \
  snapd.seeded.service \
  multipathd.service \
  thermald.service \
  ModemManager.service

# Verify they're masked
systemctl list-unit-files | grep masked
```

### Safe Service Template for WSL

When creating custom services in WSL, use this template:

```ini
[Unit]
Description=My Service
After=network.target
ConditionVirtualization=wsl  # Only run in WSL

[Service]
Type=simple
ExecStart=/path/to/executable
Restart=on-failure
RestartSec=5s                # Minimum 5 second delay
StartLimitBurst=3            # Max 3 retries
StartLimitInterval=60s       # Per minute
User=your-username
WorkingDirectory=/home/your-username

[Install]
WantedBy=multi-user.target
```

---

## 📊 Monitoring for Future Issues

### One-Time Check

```bash
# Check for any restart loops right now
journalctl --since "10 minutes ago" | grep "restart counter" | \
  awk '{print $NF}' | sort -n | tail -1
```

### Automated Monitoring

Create `/usr/local/bin/check-restarts.sh`:

```bash
#!/bin/bash
THRESHOLD=3
WINDOW="5 minutes ago"

journalctl --since "$WINDOW" | grep "restart counter is at" | while read -r line; do
    count=$(echo "$line" | grep -oP 'restart counter is at \K\d+')
    service=$(echo "$line" | grep -oP '\]: \K[^:]+')

    if [ "$count" -gt "$THRESHOLD" ]; then
        echo "⚠️  WARNING: $service restarted $count times!"
        echo "Consider: sudo systemctl mask $service"
    fi
done
```

Run periodically:
```bash
chmod +x /usr/local/bin/check-restarts.sh

# Add to crontab
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/check-restarts.sh") | crontab -
```

---

## 🎓 Prevention Best Practices

### 1. Service Hardening Checklist

Before enabling any new service:
- [ ] Set `RestartSec` >= 5 seconds
- [ ] Add `StartLimitBurst` and `StartLimitInterval`
- [ ] Test service starts successfully
- [ ] Verify service is actually needed in WSL
- [ ] Check for WSL compatibility issues

### 2. Regular Audits

```bash
# Weekly audit: find services with no restart limits
systemctl show '*.service' -p Restart,RestartSec,StartLimitBurst | \
  grep -B1 "Restart=on-failure" | \
  grep -B1 "StartLimitBurst=0" | \
  grep "^Id=" | \
  cut -d= -f2
```

### 3. Emergency Contacts

If you can't resolve a death spiral:

1. **Nuclear option**: Restart WSL entirely
   ```powershell
   wsl --shutdown
   ```

2. **Debug mode**: Start WSL without systemd
   ```powershell
   wsl --no-systemd
   ```

3. **Recovery**: Boot into recovery shell
   ```powershell
   wsl --debug-shell
   ```

---

## 📚 Additional Resources

- [Full Incident Report](./INCIDENT-2026-02-05-wsl-pro-death-spiral.md)
- [systemd.service man page](https://www.freedesktop.org/software/systemd/man/systemd.service.html)
- [WSL systemd documentation](https://learn.microsoft.com/windows/wsl/systemd)

---

**Last Updated**: February 5, 2026
**Quick Reference Card** - Keep this handy!
