#!/usr/bin/env bash
# Builds Forest.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Forest.app"
# Marketing version from the latest v* tag (or MARKETING_VERSION); build number = commit count.
VERSION="${MARKETING_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo 0.2.0)}"
VERSION="${VERSION#v}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$ROOT"
# libghostty (embedded terminal), built once from Ghostty's official source.
scripts/build-ghosttykit.sh
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
# Shell integration and terminfo for the embedded terminal, laid out like Ghostty.app's Resources.
cp -R Vendor/ghostty-resources/ghostty "$APP/Contents/Resources/ghostty"
cp -R Vendor/ghostty-resources/terminfo "$APP/Contents/Resources/terminfo"
cp Vendor/GHOSTTY_LICENSE "$APP/Contents/Resources/Ghostty-LICENSE.txt"

# Compile the asset catalog so the system accent (selection, focus rings, default buttons) is Forest green.
ASSETS_TMP="$(mktemp -d)"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$ASSETS_TMP/assets.plist" >/dev/null
rm -rf "$ASSETS_TMP"

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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.pballada.forest.branch</string>
      <key>UTTypeDescription</key><string>Forest branch</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
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
