#!/usr/bin/env bash
# Builds Forest.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Forest.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0)"

cd "$ROOT"
swift build -c "$CONFIG" --product Forest
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Forest"

if [ ! -f Resources/AppIcon.icns ]; then
  mkdir -p Resources
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Forest"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Forest</string>
  <key>CFBundleDisplayName</key><string>Forest</string>
  <key>CFBundleIdentifier</key><string>com.pballada.forest</string>
  <key>CFBundleExecutable</key><string>Forest</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
  <key>CFBundleVersion</key><string>${VERSION#v}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Forest opens worktrees and Claude Code sessions in your terminal.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
