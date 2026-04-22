# OpenFront Map Watch

A tiny native macOS menu bar app that alerts you when your favourite
map appears in the [openfront.io](https://openfront.io) public lobby
rotation — so you can jump in before the lobby fills up.

- **Menu bar only** — no Dock icon, no window. Just `OF` in the top-right.
- Flashes red/orange + fires a macOS notification when a watched map
  shows up (both "upcoming" and "joinable NOW" pings).
- Per-map mode filter: *Any*, *FFA*, *Team*, or *Special*.
- real-time — 2 Hz lobby feed direct from openfront.io's own WebSocket.
- **~50-70 MB RAM, ~1% CPU.** No browser engine, no Python, no Electron.

![menu-bar-demo](https://placehold.co/600x40/111111/ff8800?text=OF++%C2%B7++menu+bar+item&font=mono)

## Requirements

- macOS **13 Ventura** or later (Apple Silicon or Intel)
- Xcode Command Line Tools for the one-time build (Swift compiler).
  You don't need to install these manually — `install.sh` will trigger
  the standard macOS installer dialog if they're missing, then wait
  for you to finish. ~1 GB, can be removed later if you want.

No App Store, no signing, no third-party dependencies. Pure Swift + AppKit.

## Install

```bash
git clone https://github.com/andresgit763/OpenfrontJoinNotif.git
cd OpenfrontJoinNotif
./install.sh
```

That script:

1. Checks for the Swift compiler. If missing, pops up macOS's
   Command Line Tools installer and waits for you to finish.
2. Compiles `mapwatch.swift`.
3. Installs the `.app` bundle into `~/Applications/`.
4. Registers a user LaunchAgent so it autostarts at login.
5. Starts it immediately — look for **`OF`** in the top-right menu bar.

## Using it

1. Click **`OF`** in the menu bar.
2. Open **Watched maps** → pick the maps you want to be alerted about.
   Each watched map gets a sub-menu where you can pin it to a specific
   mode (FFA / Team / Special) or leave it on *Any*.
3. That's it. When a lobby matching your filter appears you'll see:
   - The menu bar title flashes **red ↔ orange**.
   - A macOS notification banner pops up.
   - A short "Glass" chime plays (toggle via *Play sound on alert*).

The menu also shows live **Current lobbies** and **Upcoming lobbies**
so you can peek at what's running without opening a browser. Clicking
any lobby opens openfront.io in your default browser.

### Notifications — one-time setup

The first time the app fires a notification macOS will ask you (via
*System Settings → Notifications*) whether to allow them. They're
attributed to **Script Editor** / **osascript** in Settings (that's how
the `display notification` AppleScript dispatch works) — it's still
your notification, just listed under that name.

You can fire one on demand via the menu: **Send test notification**.

### Config

Your watchlist and sound preference are saved to:

```
~/Library/Application Support/openfrontmod/config.json
```

## Start / Stop / Restart

Running is the default — LaunchAgent starts the app at every login.

| I want to… | Command |
|---|---|
| Start now (from menu bar's **Quit**) | `launchctl kickstart gui/$UID/com.openfrontmod.mapwatch` |
| Force restart (e.g. after an update) | `launchctl kickstart -k gui/$UID/com.openfrontmod.mapwatch` |
| Stop the current session | Click **`OF` → Quit** in the menu bar |
| Disable autostart at login | `launchctl bootout gui/$UID/com.openfrontmod.mapwatch` |
| Re-enable autostart | `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.openfrontmod.mapwatch.plist` |

Double-clicking the `.app` in `~/Applications/` (or Spotlight-searching
*OpenFront*) also starts it if it's not running.

## Update

```bash
cd OpenfrontJoinNotif
git pull
./install.sh     # recompiles + reloads
```

## Uninstall

```bash
./uninstall.sh           # removes the app and LaunchAgent
./uninstall.sh --purge   # also deletes your config/watchlist
```

## How it works (the 90-second version)

openfront.io has a WebSocket at `wss://openfront.io/w{0-19}/lobbies`
that pushes the public-lobby list every 500 ms. The site itself
consumes that feed in its React client, which is why the front page
shows the current FFA / Team / Special lobby.

Cloudflare protects that WebSocket — it rejects most generic HTTP
clients. But its gate is **TLS client fingerprint (JA3/JA4)**, not a
cookie. Apple's `URLSessionWebSocketTask` uses SecureTransport — the
same TLS stack Safari uses — so the connection goes straight through
without a browser engine, a `cf_clearance` cookie, or any JS challenge.

That's the whole trick. The rest of the app is just an `NSStatusItem`,
a `Codable` for the JSON lobby schema, and a small reconciler that
decides when to notify. See `mapwatch.swift` — ~450 lines.

## Measured footprint

(Running idle on an M-series Mac, macOS 15, 500 ms lobby tick)

| | |
|---|---|
| Memory (RSS) | **~50-70 MB** (stable) |
| CPU (idle) | **~0.5-2%** |
| Bandwidth | ~25 MB/hour (~3 KB/s — server-driven) |
| Binary on disk | **~210 KB** |
| Alert latency | **real-time, 500 ms** |

## Troubleshooting

**The menu bar item doesn't appear after `./install.sh`.**
Check it's running: `pgrep -fl OpenFrontMapWatch`. If empty, check
logs: `cat /tmp/openfrontmapwatch.err`. Try a manual kickstart:
`launchctl kickstart -k gui/$UID/com.openfrontmod.mapwatch`.

**Notifications never appear.**
Use the menu → *Send test notification*. If you don't see anything,
open *System Settings → Notifications* and allow **Script Editor** (or
**osascript**) to show notifications. Focus modes / Do Not Disturb
will also silence them.

**`swiftc: command not found` when running `./install.sh`.**
Run `xcode-select --install` and try again.

**It worked yesterday but now I get `HTTP 403` in the logs.**
Cloudflare may have tightened the fingerprint check. Check for an
update in this repo, or open an issue.

## License

MIT. Do whatever you want.

## Not affiliated

This is an unofficial third-party tool. OpenFront.io is its own thing.
