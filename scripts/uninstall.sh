#!/bin/bash
# Stops VPN Guard, releases anything it froze/blocked and removes it.
set -u
launchctl bootout "gui/$(id -u)/com.vpnguard.menu" 2>/dev/null
sudo launchctl bootout system/com.vpnguard.daemon 2>/dev/null   # daemon unblocks everything on SIGTERM
sudo rm -f /Library/LaunchDaemons/com.vpnguard.daemon.plist /Library/LaunchAgents/com.vpnguard.menu.plist
sudo rm -rf /usr/local/bin/vpnguardd /usr/local/bin/vpnguard-menu "/Applications/VPN Guard.app"
echo "Удалено. Конфиг оставлен в /Library/Application Support/VPNGuard (удалите вручную, если не нужен)."
