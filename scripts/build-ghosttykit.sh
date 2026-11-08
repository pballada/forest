#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (libghostty: terminal core + Metal renderer) from Ghostty's official
# source at a pinned tag, plus the terminfo and shell-integration resources Forest bundles.
#
#   scripts/build-ghosttykit.sh            # -> Vendor/GhosttyKit.xcframework, Vendor/ghostty-resources
#
# Requires Zig (the version Ghostty's build.zig.zon asks for; `brew install zig`) and Xcode.
# The embedding API is not stable, so bump GHOSTTY_TAG deliberately and re-check Sources/ForestTerminal.
set -euo pipefail

GHOSTTY_TAG="${GHOSTTY_TAG:-v1.4.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="${GHOSTTY_WORK:-$ROOT/.build/ghostty-src}"

if [ -d "$VENDOR/GhosttyKit.xcframework" ] && [ "$(cat "$VENDOR/GHOSTTY_TAG" 2>/dev/null)" = "$GHOSTTY_TAG" ] && [ -z "${FORCE:-}" ]; then
  echo "GhosttyKit $GHOSTTY_TAG already built (FORCE=1 to rebuild)"
  exit 0
fi

command -v zig >/dev/null || { echo "zig not found: brew install zig" >&2; exit 1; }

if [ ! -d "$WORK/.git" ] || [ "$(git -C "$WORK" describe --tags --exact-match 2>/dev/null)" != "$GHOSTTY_TAG" ]; then
  rm -rf "$WORK"
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$WORK"
fi

# Xcode 26+ no longer ships `metallib` where Ghostty's build looks for it.
SHIM="$(mktemp -d)"
printf '#!/bin/sh\nexec xcrun metal "$@"\n' > "$SHIM/metallib"
chmod +x "$SHIM/metallib"
export PATH="$SHIM:$PATH"

cd "$WORK"
zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast

mkdir -p "$VENDOR"
rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/ghostty-resources"
cp -R macos/GhosttyKit.xcframework "$VENDOR/GhosttyKit.xcframework"
# Same layout as Ghostty.app's Resources: libghostty finds terminfo next to its resources directory.
mkdir -p "$VENDOR/ghostty-resources/ghostty"
cp -R zig-out/share/ghostty/shell-integration "$VENDOR/ghostty-resources/ghostty/shell-integration"
cp -R zig-out/share/terminfo "$VENDOR/ghostty-resources/terminfo"
cp LICENSE "$VENDOR/GHOSTTY_LICENSE"
echo "$GHOSTTY_TAG" > "$VENDOR/GHOSTTY_TAG"
rm -rf "$SHIM"
echo "Built GhosttyKit $GHOSTTY_TAG into $VENDOR"
