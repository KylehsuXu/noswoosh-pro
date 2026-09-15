#!/bin/bash
# Removes noswoosh-pro and restores the system's animated Ctrl+arrow shortcuts.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="$HOME/.local/bin"
LABEL="xu.max.noswoosh-pro"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Stopping and removing LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Restoring the system's animated Ctrl+arrow shortcuts"
if [ -x "$BIN_DIR/noswoosh-pro" ]; then
    "$BIN_DIR/noswoosh-pro" teardown
else
    echo "    noswoosh-pro binary missing — re-enable Ctrl+arrows in System Settings >"
    echo "    Keyboard > Keyboard Shortcuts > Mission Control."
fi

echo "==> Removing binaries and source"
rm -f "$BIN_DIR/noswoosh-pro" "$BIN_DIR/noswoosh.swift" "$BIN_DIR/noswoosh-ctrl-arrows"

echo
echo "Done. Optionally remove 'noswoosh-pro' from"
echo "System Settings > Privacy & Security > Accessibility."
