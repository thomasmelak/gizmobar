#!/usr/bin/env bash
# Builds Gizmobar.app from the SwiftPM products.
#
# Sign with a stable Apple Development identity so privacy grants (audio
# capture, accessibility) survive rebuilds:
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
# Without it the app is ad-hoc signed and macOS asks again after each build.
#
# Release builds (see .github/workflows/release.yml):
#   UNIVERSAL=1   build for arm64 and x86_64
#   VERSION=1.2.3 (or v1.2.3) BUILD_NUMBER=42   stamp the bundle version
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
OUT="build/Gizmobar.app"

FLAGS=(-c "$CONFIG")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  FLAGS+=(--arch arm64 --arch x86_64)
fi

swift build "${FLAGS[@]}" --product Gizmobar
swift build "${FLAGS[@]}" --product gizmo
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp "$BIN/Gizmobar" "$OUT/Contents/MacOS/Gizmobar"
cp "$BIN/gizmo" "$OUT/Contents/MacOS/gizmo"
cp -R icon-packs "$OUT/Contents/Resources/icon-packs"
cp -R themes "$OUT/Contents/Resources/themes"
cp Resources/AppIcon/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
# The example config, so `gizmo config init` works without a source checkout.
mkdir -p "$OUT/Contents/Resources/examples"
cp -R examples/gizmobar "$OUT/Contents/Resources/examples/gizmobar"

PLIST="$OUT/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$OUT/Contents/MacOS/gizmo"
codesign --force --options runtime --entitlements Resources/Gizmobar.entitlements --sign "${SIGN_IDENTITY:--}" "$OUT"
echo "built $OUT"
