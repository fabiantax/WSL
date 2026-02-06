#!/bin/bash
# WSL2 Bash Performance Optimizations
# Run with: sudo bash /mnt/c/Users/fabia/projects/wsl/WSL/tools/strix-turbo/quick-wins/setup-bash-perf.sh

set -e

echo "=== WSL2 Bash Performance Setup ==="

echo ""
echo "1. Updating /etc/wsl.conf (disable appendWindowsPath)..."
printf "[boot]\nsystemd=true\n\n[user]\ndefault=fabia\n\n[interop]\nappendWindowsPath=false\n\n[automount]\noptions=metadata\n" > /etc/wsl.conf
echo "   Done."

echo ""
echo "2. Mounting tmpfs on /tmp (4GB RAM-backed)..."
mount -t tmpfs -o size=4G,noatime tmpfs /tmp 2>/dev/null || echo "   Already mounted or failed."
echo "   Done."

echo ""
echo "3. Making tmpfs permanent in /etc/fstab..."
if grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
    echo "   Already in fstab, skipping."
else
    echo "tmpfs /tmp tmpfs noatime,size=4G 0 0" >> /etc/fstab
    echo "   Added to fstab."
fi

echo ""
echo "=== All done ==="
echo "NOTE: appendWindowsPath takes effect after: wsl --shutdown"
echo ""
