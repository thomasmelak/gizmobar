#!/bin/bash
# Removes Gizmobar, the gizmo command and the bar's own state.
# Your config in ~/.config/gizmobar is kept.
#   curl -fsSL https://raw.githubusercontent.com/thomasmelak/gizmobar/main/uninstall.sh | bash
set -euo pipefail

BUNDLE_ID="io.thomasmelak.gizmobar"
APP_NAME="Gizmobar.app"

echo "==> Stopping Gizmobar"
pkill -x Gizmobar 2>/dev/null || true

if command -v brew >/dev/null 2>&1 && brew list --cask gizmobar >/dev/null 2>&1; then
    echo "==> Removing the Homebrew cask"
    brew uninstall --cask --zap gizmobar || brew uninstall --cask gizmobar || true
fi

echo "==> Removing the app"
for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/$APP_NAME" ]; then
        rm -rf "${dir:?}/$APP_NAME"
        echo "    removed $dir/$APP_NAME"
    fi
done

echo "==> Removing the gizmo command"
for link in "$HOME/.local/bin/gizmo" /opt/homebrew/bin/gizmo /usr/local/bin/gizmo; do
    if [ -L "$link" ] && [[ "$(readlink "$link")" == *"$APP_NAME"* ]]; then
        rm -f "$link"
        echo "    removed $link"
    fi
done

echo "==> Removing state and settings"
rm -rf "$HOME/Library/Application Support/Gizmobar"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$BUNDLE_ID.plist"

echo
echo "Gizmobar has been removed. Your config is still in ~/.config/gizmobar; delete it if you don't need it."
