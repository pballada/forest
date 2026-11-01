#!/usr/bin/env bash
# Builds, signs (Developer ID, hardened runtime), notarizes and staples Forest.
# Produces build/Forest-<version>.dmg and build/Forest-<version>.zip, ready to download from the web.
#
# Prerequisites (once):
#   - A "Developer ID Application" certificate in your keychain
#   - xcrun notarytool store-credentials notary --apple-id <you> --team-id <team>
#
# Usage: scripts/release.sh   (override with SIGN_IDENTITY=… NOTARY_PROFILE=…)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
PROFILE="${NOTARY_PROFILE:-notary}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

scripts/build-app.sh release
APP="$ROOT/build/Forest.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/Forest-$VERSION.dmg"
ZIP="$ROOT/build/Forest-$VERSION.zip"

echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --entitlements Resources/Forest.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Disk image with a drag-to-Applications link.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Forest" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Notarizing (this usually takes a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
# Stapling the DMG covers its contents; staple the app too so the zip works offline.
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Done:"
echo "  $DMG"
echo "  $ZIP"
