#!/bin/bash
# Service Restart Monitor
# Detects systemd death spirals before they cause system instability
# Run via cron every 5 minutes: */5 * * * * /usr/local/bin/check-service-restarts.sh

THRESHOLD=3
WINDOW="5 minutes ago"
LOG_FILE="/var/log/service-restart-monitor.log"
ALERT_FILE="/tmp/service-restart-alert.txt"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Header
{
    echo "=== Service Restart Monitor ==="
    echo "Timestamp: $(date)"
    echo "Threshold: $THRESHOLD restarts"
    echo "Window: $WINDOW"
    echo ""
} >> "$LOG_FILE"

# Check for restart storms
found_issues=0

journalctl --since "$WINDOW" 2>/dev/null | grep "restart counter is at" | while read -r line; do
    # Extract restart count
    count=$(echo "$line" | grep -oP 'restart counter is at \K\d+' || echo "0")

    # Extract service name
    service=$(echo "$line" | grep -oP 'systemd\[1\]: \K[^:]+' || echo "unknown")

    if [ "$count" -gt "$THRESHOLD" ]; then
        found_issues=1

        # Log the issue
        {
            echo "⚠️  WARNING: Restart storm detected!"
            echo "Service: $service"
            echo "Restart count: $count"
            echo "Time: $(date)"
            echo "---"
        } >> "$LOG_FILE"

        # Create alert file
        {
            echo "SERVICE RESTART STORM DETECTED"
            echo "Service: $service"
            echo "Restarts: $count in last 5 minutes"
            echo ""
            echo "RECOMMENDED ACTION:"
            echo "  sudo systemctl stop $service"
            echo "  sudo systemctl mask $service"
            echo ""
            echo "To investigate:"
            echo "  journalctl -u $service -n 50"
            echo ""
        } >> "$ALERT_FILE"

        # Try to auto-mask if count is extremely high
        if [ "$count" -gt 10 ]; then
            echo "🚨 CRITICAL: $count restarts detected!" >> "$LOG_FILE"
            echo "Auto-masking $service to prevent system crash..." >> "$LOG_FILE"

            # Stop and mask the service
            sudo systemctl stop "$service" 2>&1 >> "$LOG_FILE"
            sudo systemctl mask "$service" 2>&1 >> "$LOG_FILE"

            echo "✅ Service $service has been auto-masked" >> "$LOG_FILE"

            # Notify user
            if command -v notify-send &> /dev/null; then
                notify-send "Service Restart Storm" "$service auto-masked after $count restarts"
            fi
        fi
    fi
done

# Check for failed services
failed_count=$(systemctl list-units --failed --no-pager --no-legend | wc -l)
if [ "$failed_count" -gt 0 ]; then
    {
        echo "ℹ️  Info: $failed_count failed services detected"
        systemctl list-units --failed --no-pager --no-legend
        echo ""
    } >> "$LOG_FILE"
fi

# Report if alert file exists
if [ -f "$ALERT_FILE" ]; then
    cat "$ALERT_FILE"

    # Send to syslog
    logger -t service-monitor "$(cat "$ALERT_FILE")"

    # Keep alert for 1 hour
    touch -d "1 hour ago" "$ALERT_FILE.timestamp"
fi

# Rotate log if too large (keep last 10MB)
if [ -f "$LOG_FILE" ]; then
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt 10485760 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        echo "Log rotated at $(date)" > "$LOG_FILE"
    fi
fi

# Clean exit
exit 0
