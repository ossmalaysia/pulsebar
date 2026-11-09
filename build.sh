#!/bin/zsh
# Builds PulseBar.app next to this script. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
APP=PulseBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift history.swift alerts.swift -o "$APP/Contents/MacOS/PulseBar"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PulseBar</string>
  <key>CFBundleIdentifier</key><string>io.github.ossmalaysia.pulsebar</string>
  <key>CFBundleExecutable</key><string>PulseBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/$APP" && cp -R "$APP" /Applications/
  echo "Installed to /Applications/$APP"
fi
