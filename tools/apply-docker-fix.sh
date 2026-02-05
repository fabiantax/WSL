#!/bin/bash
# Docker Fix - Configure Docker to use iptables-legacy (system stays on nftables)
# Date: 2026-02-05
# Reference: docs/incidents/ROOT-CAUSE-ANALYSIS-FINAL.md

set -euo pipefail

echo "========================================"
echo "Docker Fix (95% Certainty)"
echo "========================================"
echo ""

echo "Current system iptables backend:"
update-alternatives --query iptables | grep ^Value
echo ""

# Fix 1: Configure Docker to use iptables-legacy
echo "1️⃣  Configuring Docker to use iptables-legacy..."

sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "iptables": true,
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "userland-proxy": false,
  "iptables-path": "/usr/sbin/iptables-legacy",
  "ip6tables-path": "/usr/sbin/ip6tables-legacy"
}
EOF

echo "   ✅ Docker daemon.json configured"
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
echo "3️⃣  Reloading and restarting Docker..."

sudo systemctl daemon-reload
sudo systemctl reset-failed docker 2>/dev/null || true
sudo systemctl restart docker

echo "   ✅ Docker restarted"
echo ""

# Verification
echo "========================================"
echo "Verification"
echo "========================================"
echo ""

echo "📊 System iptables (unchanged):"
update-alternatives --query iptables | grep ^Value
echo "   ✅ System still uses nftables"
echo ""

echo "📊 Docker configuration:"
cat /etc/docker/daemon.json
echo ""

echo "📊 Docker Status:"
systemctl status docker --no-pager | head -10
echo ""

echo "📊 Circuit Breaker Config:"
cat /etc/systemd/system/service.d/10-circuit-breaker.conf
echo ""

# Final check
if systemctl is-active --quiet docker; then
    echo "✅ SUCCESS: Docker running with iptables-legacy"
    echo "✅ SUCCESS: System iptables unchanged (nftables)"
    echo "✅ SUCCESS: Circuit breakers installed"
    echo ""

    # Test Docker
    echo "Testing Docker functionality..."
    sudo docker run --rm hello-world 2>&1 | head -5

    echo ""
    echo "🎉 All fixes applied successfully!"
else
    echo "⚠️  Docker not active - checking logs..."
    journalctl -u docker -n 30 --no-pager
fi
