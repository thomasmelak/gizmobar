#!/usr/bin/env bash
# Builds Gizmobar.app from the SwiftPM products.
#
# Sign with a stable Apple Development identity so privacy grants (audio
# capture, accessibility) survive rebuilds:
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
# Without it the app is ad-hoc signed and macOS asks again after each build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
OUT="build/Gizmobar.app"

swift build -c "$CONFIG" --product Gizmobar
swift build -c "$CONFIG" --product gizmo
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp "$BIN/Gizmobar" "$OUT/Contents/MacOS/Gizmobar"
cp "$BIN/gizmo" "$OUT/Contents/MacOS/gizmo"
cp -R icon-packs "$OUT/Contents/Resources/icon-packs"

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$OUT/Contents/MacOS/gizmo"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$OUT"
echo "built $OUT"
