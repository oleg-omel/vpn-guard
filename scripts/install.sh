#!/bin/bash
# Builds VPN Guard and installs the root daemon (LaunchDaemon) and the menu bar app (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release

sudo install -d /usr/local/bin
sudo install -m 755 .build/release/vpnguardd /usr/local/bin/vpnguardd

# Menu bar app must be a real .app bundle so macOS can ask for Location access (needed to read the Wi-Fi name).
APP="/Applications/VPN Guard.app"
sudo rm -rf "$APP" /usr/local/bin/vpnguard-menu
sudo mkdir -p "$APP/Contents/MacOS"
sudo install -m 755 .build/release/vpnguard-menu "$APP/Contents/MacOS/vpnguard-menu"
sudo tee "$APP/Contents/Info.plist" >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.vpnguard.menu</string>
  <key>CFBundleName</key><string>VPN Guard</string>
  <key>CFBundleExecutable</key><string>vpnguard-menu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>VPN Guard читает название Wi-Fi сети, чтобы отключать защиту в доверенных сетях.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>VPN Guard читает название Wi-Fi сети, чтобы отключать защиту в доверенных сетях.</string>
</dict></plist>
PLIST
sudo codesign --force --deep -s - "$APP"

sudo install -d -m 775 -o root -g admin "/Library/Application Support/VPNGuard"

sudo tee /Library/LaunchDaemons/com.vpnguard.daemon.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.vpnguard.daemon</string>
  <key>ProgramArguments</key><array><string>/usr/local/bin/vpnguardd</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>/var/log/vpnguard.log</string>
</dict></plist>
PLIST

sudo tee /Library/LaunchAgents/com.vpnguard.menu.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.vpnguard.menu</string>
  <key>ProgramArguments</key><array><string>/Applications/VPN Guard.app/Contents/MacOS/vpnguard-menu</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

sudo launchctl bootout system/com.vpnguard.daemon 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.vpnguard.daemon.plist
launchctl bootout "gui/$(id -u)/com.vpnguard.menu" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" /Library/LaunchAgents/com.vpnguard.menu.plist
echo "Готово. Значок щита появился в строке меню."
