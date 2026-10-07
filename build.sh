#!/bin/bash
# Builds build/runawake.app. ./build.sh install copies it to ~/Applications, registers it as a login item,
# and registers hooks with installed AI agents (hooks/setup.py).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/runawake.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/runawake.icns "$APP/Contents/Resources/"
swiftc -O Sources/main.swift Sources/critters.swift -o "$APP/Contents/MacOS/runawake"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.runawake</string>
<key>CFBundleName</key><string>runawake</string>
<key>CFBundleExecutable</key><string>runawake</string>
<key>CFBundleIconFile</key><string>runawake</string>
<key>CFBundleDisplayName</key><string>Runawake</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign -s - --force "$APP" >/dev/null 2>&1
echo "built $APP"

if [ "${1:-}" = install ]; then
  pkill -x runawake 2>/dev/null || true
  rm -rf ~/Applications/runawake.app; cp -R "$APP" ~/Applications/
  PL=~/Library/LaunchAgents/local.runawake.plist
  cat > "$PL" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.runawake</string>
<key>ProgramArguments</key><array><string>$HOME/Applications/runawake.app/Contents/MacOS/runawake</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
  launchctl bootout gui/$(id -u) "$PL" 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) "$PL"
  echo "installed: ~/Applications/runawake.app (login item: $PL)"
  python3 hooks/setup.py install
fi
