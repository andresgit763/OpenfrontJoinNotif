#!/bin/bash
# Fully remove OpenFront Map Watch.
#   - Unload + delete the LaunchAgent
#   - Delete the .app bundle
#   - (Optional) delete the config file  — pass --purge to include it

set -euo pipefail

APP_NAME="OpenFront Map Watch"
APP="$HOME/Applications/$APP_NAME.app"
PLIST_LABEL="com.openfrontmod.mapwatch"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CONFIG_DIR="$HOME/Library/Application Support/openfrontmod"

launchctl bootout "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"
rm -rf "$APP"
pkill -f 'OpenFrontMapWatch' >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$CONFIG_DIR"
    echo "Removed: app, LaunchAgent, and config"
else
    echo "Removed: app and LaunchAgent"
    echo "Config kept at: $CONFIG_DIR"
    echo "To also remove config: $0 --purge"
fi
