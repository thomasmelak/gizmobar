#!/usr/bin/env bash
# Packages build/Gizmobar.app into build/Gizmobar.dmg with a drag-to-Applications layout.
# Run scripts/bundle.sh (make app) first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Gizmobar.app"
DMG="build/Gizmobar.dmg"
STAGING="build/dmg"

if [ ! -d "$APP" ]; then
    echo "Missing $APP. Run make app first." >&2
    exit 1
fi

echo "==> Staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Gizmobar.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "Gizmobar" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DMG"
