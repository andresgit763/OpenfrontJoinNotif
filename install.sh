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

# 0. Make sure Xcode Command Line Tools are present — needed for swiftc.
# macOS *would* pop up the installer automatically on first xcrun call,
# but the shell process returns before the user clicks Install, so we'd
# crash. Prompt the user up front and wait for them to finish.
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    echo "==> Xcode Command Line Tools are required but not installed."
    echo "    Triggering the installer dialog now..."
    /usr/bin/xcode-select --install >/dev/null 2>&1 || true
    echo
    echo "    A macOS dialog should be visible. Click 'Install',"
    echo "    accept the license, and wait for the download to finish"
    echo "    (~5-15 minutes, roughly 1 GB)."
    echo
    read -rp "Press Enter here AFTER the install has completed... "
    if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
        echo "swiftc still not found. Try running './install.sh' again." >&2
        exit 1
    fi
fi
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
# launchd's deregistration is async; give it a beat before bootstrapping,
# otherwise rapid reinstalls can hit "Input/output error (5)".
for _ in 1 2 3; do
    if launchctl bootstrap "gui/$UID" "$PLIST_DEST" 2>/dev/null; then break; fi
    sleep 1
done
launchctl kickstart -k "gui/$UID/$PLIST_LABEL"

echo
echo "==> Installed"
echo "   App:          $APP"
echo "   LaunchAgent:  $PLIST_DEST"
echo "   Config:       \$HOME/Library/Application Support/openfrontmod/config.json"
echo
echo "Look for 'OF' in your menu bar (top-right). Click it to pick which maps to watch."
