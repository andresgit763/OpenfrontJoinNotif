# OpenFront Map Watch

A light native macOS menu bar app that alerts you when your favourite
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

No App Store and no paid signing. The app is native Swift + AppKit and uses
macOS's built-in JavaScriptCore to run the OpenFront-compatible lobby decoder.

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
any lobby opens openfront.io in **Safari** (Safari's WebKit is the
lightest browser engine on macOS, so the lobby loads fastest there).

### Notifications — one-time setup

The first time you launch the app, macOS pops up
*"OpenFront Map Watch" would like to send you notifications*. Click
**Allow**. If you miss the prompt, grant it manually under
*System Settings → Notifications → OpenFront Map Watch*.

Notifications are attributed to the app itself, and **clicking a
notification opens openfront.io in Safari** — you can jump straight
into the lobby without reaching for the menu bar.

You can fire one on demand via the menu: **Send test notification**.

(If you decline the permission prompt, the app silently falls back to
the AppleScript `display notification` path. Banners will still appear,
but they'll be attributed to "Script Editor" and clicking them opens
Script Editor instead of openfront.io.)

### Config

Your watchlist and sound preference are saved to:

```
~/Library/Application Support/openfrontmod/config.json
```

## Start / Stop / Restart

Running is the default — LaunchAgent starts the app at every login and
restarts it if it ever exits. **`OF` → Quit** stops it until the next login.

| I want to… | Command |
|---|---|
| Start again after **Quit** | `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.openfrontmod.mapwatch.plist` |
| Force restart | `launchctl kickstart -k gui/$UID/com.openfrontmod.mapwatch` |
| Stop until next login | Click **`OF` → Quit** in the menu bar |
| Remove autostart for good | `./uninstall.sh` |

Double-clicking the `.app` in `~/Applications/` (or Spotlight-searching
*OpenFront*) also starts it if it's not running.

## Update

```bash
cd OpenfrontJoinNotif
git pull
./install.sh     # recompiles + reloads
```

OpenFront deploys don't need an update: the app fetches the decoder for the
new build by itself (see *How it works*). `git pull` is only for app changes.

The decoders are built by the **Lobby decoders** GitHub Action, which runs
every 3 hours. To publish one sooner, run the Action from the repo's
*Actions* tab (*Run workflow*). To build one by hand, check out the deployed OpenFrontIO
commit, run `npm_config_engine_strict=false npm ci --ignore-scripts` in it,
then:

```bash
node scripts/build-lobby-decoder.mjs /path/to/OpenFrontIO <git-commit> decoders/<git-commit>.js
```

Leave out the last argument to rebuild the decoder bundled in the app instead.

## Uninstall

```bash
./uninstall.sh           # removes the app and LaunchAgent
./uninstall.sh --purge   # also deletes your config/watchlist
```

## How it works (the 90-second version)

openfront.io pushes the public-lobby list every 500 ms over a WebSocket
at `wss://<server host>/w{0-N}/lobbies`. The site itself consumes that
feed in its client, which is why the front page shows the current FFA /
Team / Special lobby.

Which host and how many workers is not fixed: OpenFront runs several game
servers at once and rolls deploys between them, so Map Watch reads the
server list from `api.openfront.io/cluster.json` and connects to whichever
server is currently `open` (the apex host stopped proxying this socket in
September 2026). The list is re-resolved when it ages out, after repeated
connection failures, and on wake from sleep, so a deploy that moves the
feed to another host reconnects on its own.

Since August 2026 those frames use OpenFront's positional `zbin` protocol
rather than JSON. There is deliberately no wire-version byte or fallback:
fields are read in declaration order and enums by position, so any OpenFront
release can change the layout (a new map shifts every map after it in the
alphabet). Map Watch therefore runs OpenFront's own lobby decoder built from
the exact commit the server runs, never a guess.

Keeping up with deploys is automatic:

1. OpenFront records every production deploy, with its commit, in the public
   GitHub deployments API of `openfrontio/OpenFrontIO`.
2. The **Lobby decoders** Action in this repo checks that every 3 hours
   and publishes `decoders/<commit>.js` for each new build.
3. The app reads the server's build from the server list and downloads the
   matching decoder. It caches the last few under
   `~/Library/Application Support/openfrontmod/decoders/`.

The decoder bundled in the app is only the starting point. Between a deploy
and the Action publishing its decoder (up to about 3 hours), the old
decoder keeps running. If it can't read the new frames, the menu says
**OpenFront updated, fetching new decoder** and the socket stays calm instead
of entering a reconnect storm. Downloaded decoders run in a bare
JavaScriptCore context with no access to the system.

Cloudflare protects that WebSocket — it rejects most generic HTTP
clients. But its gate is **TLS client fingerprint (JA3/JA4)**, not a
cookie. Apple's `URLSessionWebSocketTask` uses SecureTransport — the
same TLS stack Safari uses — so the connection goes straight through
without a browser engine, a `cf_clearance` cookie, or any JS challenge.

The rest of the app is an `NSStatusItem`, small `Codable` display models, and a
reconciler that decides when to notify. No WebView, Python, Node, or Electron
process runs after installation.

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
