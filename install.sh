#!/bin/bash
# Gizmobar installer.
#   curl -fsSL https://raw.githubusercontent.com/thomasmelak/gizmobar/main/install.sh | bash
set -euo pipefail

REPO="thomasmelak/gizmobar"
APP_NAME="Gizmobar.app"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Gizmobar.zip"
BIN_DIR="$HOME/.local/bin"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Gizmobar only runs on macOS." >&2
    exit 1
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading the latest release"
if ! curl -fsSL "$ZIP_URL" -o "$TMP/Gizmobar.zip"; then
    echo "Could not download $ZIP_URL." >&2
    echo "Check your connection, or see https://github.com/$REPO/releases." >&2
    exit 1
fi
ditto -x -k "$TMP/Gizmobar.zip" "$TMP"

if [ ! -d "$TMP/$APP_NAME" ]; then
    echo "Something went wrong: $APP_NAME was not found in the download." >&2
    exit 1
fi

echo "==> Installing to $DEST"
pkill -x Gizmobar 2>/dev/null || true
rm -rf "${DEST:?}/$APP_NAME"
ditto "$TMP/$APP_NAME" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo "==> Linking gizmo into $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$DEST/$APP_NAME/Contents/MacOS/gizmo" "$BIN_DIR/gizmo"

echo "==> Copying the example config (existing files are kept)"
"$BIN_DIR/gizmo" config init || true

echo "==> Starting Gizmobar"
open "$DEST/$APP_NAME"

echo
echo "Gizmobar is running. Your config lives in ~/.config/gizmobar."
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Add $BIN_DIR to your PATH to use the gizmo command." ;;
esac
