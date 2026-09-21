#!/bin/bash
# Builds ClaudeActivity.app with the Command Line Tools (no Xcode needed) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Claude Activity.app"
pkill -x ClaudeActivity 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeActivity" main.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Claude Activity</string>
<key>CFBundleIdentifier</key><string>local.claudeactivity</string>
<key>CFBundleExecutable</key><string>ClaudeActivity</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Installed: $APP"
