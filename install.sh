#!/bin/bash
# Install OpenFront Map Watch:
#   1. Build the .app
#   2. Copy it to ~/Applications (created if missing)
#   3. Generate + install a user LaunchAgent so it starts at login
#   4. Start it now
#
# Safe to re-run. If already installed, this updates the binary and reloads.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="OpenFront Map Watch"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
PLIST_LABEL="com.openfrontmod.mapwatch"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

# 1. Build.
bash "$HERE/build.sh"

# 2. Install.
mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
cp -R "$HERE/dist/$APP_NAME.app" "$APP"

# 3. LaunchAgent.
APP_BIN="$APP/Contents/MacOS/OpenFrontMapWatch"
mkdir -p "$(dirname "$PLIST_DEST")"
sed "s|__APP_BIN__|$APP_BIN|g" \
    "$HERE/com.openfrontmod.mapwatch.plist.template" > "$PLIST_DEST"
chmod 644 "$PLIST_DEST"

# 4. (Re)load.
launchctl bootout "gui/$UID/$PLIST_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DEST"
launchctl kickstart -k "gui/$UID/$PLIST_LABEL"

echo
echo "==> Installed"
echo "   App:          $APP"
echo "   LaunchAgent:  $PLIST_DEST"
echo "   Config:       \$HOME/Library/Application Support/openfrontmod/config.json"
echo
echo "Look for 'OF' in your menu bar (top-right). Click it to pick which maps to watch."
