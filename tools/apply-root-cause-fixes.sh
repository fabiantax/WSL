#!/bin/bash
# Root Cause Fixes - 95% Certainty
# Applies Docker iptables fix + systemd circuit breakers
# Date: 2026-02-05
# Reference: docs/incidents/ROOT-CAUSE-ANALYSIS-FINAL.md

set -euo pipefail

echo "========================================"
echo "Root Cause Fixes (95% Certainty)"
echo "========================================"
echo ""

# Fix 1: Docker iptables backend (95% certainty)
echo "1️⃣  Switching iptables to legacy backend..."
echo "   Current: $(update-alternatives --query iptables | grep ^Value | cut -d' ' -f2)"

sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

echo "   New: $(update-alternatives --query iptables | grep ^Value | cut -d' ' -f2)"
echo "   ✅ iptables backend switched"
echo ""

# Fix 2: Global systemd circuit breakers (95% certainty)
echo "2️⃣  Installing systemd circuit breakers..."

sudo mkdir -p /etc/systemd/system/service.d

sudo tee /etc/systemd/system/service.d/10-circuit-breaker.conf > /dev/null << 'EOF'
[Service]
# Global circuit breaker to prevent death spirals
# Max 5 restarts in 120 seconds, then stop
StartLimitIntervalSec=120
StartLimitBurst=5
RestartSec=5s
EOF

echo "   ✅ Circuit breaker config created"
echo ""

# Apply changes
echo "3️⃣  Reloading systemd and restarting Docker..."

sudo systemctl daemon-reload

# Reset Docker's failed state and restart
sudo systemctl reset-failed docker 2>/dev/null || true
sudo systemctl restart docker

echo "   ✅ Services reloaded"
echo ""

# Verification
echo "========================================"
echo "Verification"
echo "========================================"
echo ""

echo "📊 Docker Status:"
systemctl status docker --no-pager | head -10
echo ""

echo "📊 Circuit Breaker Config:"
cat /etc/systemd/system/service.d/10-circuit-breaker.conf
echo ""

echo "📊 iptables Backend:"
update-alternatives --query iptables | grep -E "^(Value|Status)"
echo ""

# Final check
if systemctl is-active --quiet docker; then
    echo "✅ SUCCESS: Docker is running"
    echo "✅ SUCCESS: Circuit breakers installed"
    echo ""
    echo "All fixes applied successfully!"
else
    echo "⚠️  Docker not active - checking logs..."
    journalctl -u docker -n 20 --no-pager
fi
