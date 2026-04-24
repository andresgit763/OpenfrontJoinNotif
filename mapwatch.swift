// OpenFront Map Watch — native macOS menu bar app.
//
// Replaces the Python + WKWebView implementation. Apple's URLSession uses
// SecureTransport, whose TLS fingerprint Cloudflare's WAF accepts for the
// openfront.io WebSocket upgrade — so no browser engine is needed. Total
// footprint drops from ~280 MB to ~30 MB.
//
// Build:  swiftc -O mapwatch.swift -o mapwatch
// Run:    ./mapwatch

import AppKit
import Foundation
import UserNotifications

// MARK: - Constants

let OPENFRONT_URL = URL(string: "https://openfront.io/")!
let WORKER_COUNT = 20

let MODES = ["any", "ffa", "team", "special"]
let MODE_LABELS: [String: String] = [
    "any": "Any", "ffa": "FFA", "team": "Team", "special": "Special",
]

// Stable, deterministic category order for rendering. The server's JSON uses
// a Swift `Dictionary` whose iteration order is NOT stable tick-to-tick, so
// without this constant the three "Current" rows would visibly swap places
// every broadcast even when lobby contents didn't change. Listing explicitly
// also means any future publicGameType the server adds won't silently shift
// existing rows around.
let CATEGORY_ORDER = ["ffa", "team", "special"]

// Mirrors src/core/game/Game.ts :: GameMapType in the OpenFrontIO repo.
let ALL_MAPS: [String] = [
    "World", "Giant World Map", "Europe", "Europe Classic", "Mena",
    "North America", "South America", "Oceania", "Black Sea", "Africa",
    "Pangaea", "Asia", "Mars", "Britannia Classic", "Britannia",
    "Gateway to the Atlantic", "Australia", "Iceland", "East Asia",
    "Between Two Seas", "Faroe Islands", "Deglaciated Antarctica",
    "Falkland Islands", "Baikal", "Halkidiki", "Strait of Gibraltar",
    "Italia", "Japan", "Pluto", "Montreal", "New York City", "Achiran",
    "Baikal Nuke Wars", "Four Islands", "Svalmel", "Gulf of St. Lawrence",
    "Lisbon", "Manicouagan", "Lemnos", "Tourney 2 Teams", "Tourney 3 Teams",
    "Tourney 4 Teams", "Tourney 8 Teams", "Passage", "Sierpinski", "The Box",
    "Two Lakes", "Strait of Hormuz", "Surrounded", "Didier", "Didier France",
    "Amazon River", "Bosphorus Straits", "Bering Strait", "Yenisei",
    "Traders Dream", "Hawaii", "Alps", "Nile Delta", "Arctic", "San Francisco",
    "Aegean", "MilkyWay", "Mediterranean", "Dyslexdria", "Great Lakes",
    "Strait Of Malacca", "Luna", "Conakry", "Caucasus", "Bering Sea",
]

let POPULAR_MAPS: [String] = [
    "World", "Europe", "Asia", "Africa", "North America",
    "South America", "Oceania", "Pangaea", "Mars",
]

let SAFARI_UA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// MARK: - Config

struct Config: Codable {
    var watched_maps: [String: String] = [:]
    var play_sound: Bool = true
}

func configDir() -> URL {
    let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("openfrontmod")
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true
    )
    return dir
}

func configPath() -> URL { configDir().appendingPathComponent("config.json") }

func loadConfig() -> Config {
    let url = configPath()
    guard let data = try? Data(contentsOf: url),
          var cfg = try? JSONDecoder().decode(Config.self, from: data)
    else { return Config() }
    cfg.watched_maps = cfg.watched_maps.mapValues {
        MODES.contains($0) ? $0 : "any"
    }
    return cfg
}

func saveConfig(_ c: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(c) {
        try? data.write(to: configPath())
    }
}

// MARK: - Incoming JSON model

struct GameCfg: Codable {
    let gameMap: String?
    let gameMode: String?
}
struct LobbyInfo: Codable {
    let gameID: String
    let numClients: Int
    let startsAt: Int?
    let gameConfig: GameCfg?
    let publicGameType: String?
}
struct PublicGames: Codable {
    let serverTime: Int
    let games: [String: [LobbyInfo]]
}

// Normalized lobby used internally.
struct Lobby {
    let kind: String       // "ffa" | "team" | "special"
    let gameID: String
    let gameMap: String
    let gameMode: String
    let numClients: Int
    let startsAt: Int
    let isCurrent: Bool    // index 0 of its category
}

// MARK: - Utility

func formatCountdown(_ startsAt: Int, _ serverTime: Int) -> String? {
    guard startsAt > 0, serverTime > 0 else { return nil }
    let delta = (startsAt - serverTime) / 1000
    if delta <= 0 { return "starting" }
    return "\(delta / 60):\(String(format: "%02d", delta % 60))"
}

// AppleScript literal-safe quoting. Uses double-quoted string with
// escaped backslashes and quotes — matches JSON semantics closely enough.
func appleScriptQuote(_ s: String) -> String {
    let esc = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(esc)\""
}

/// Fallback-only path for when UNUserNotificationCenter isn't authorised.
/// Still lands as a Notification Center banner, but attributed to
/// "Script Editor"/"osascript" and clicks open that app — we prefer the
/// native path when available (see AppDelegate.fireNotification).
func fireOsascriptNotification(title: String, body: String) {
    let script =
        "display notification \(appleScriptQuote(body)) "
        + "with title \(appleScriptQuote(title)) sound name \"Glass\""
    let proc = Process()
    proc.launchPath = "/usr/bin/osascript"
    proc.arguments = ["-e", script]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { /* no-op */ }
}

// MARK: - App

final class AppDelegate: NSObject,
                         NSApplicationDelegate,
                         URLSessionWebSocketDelegate,
                         UNUserNotificationCenterDelegate,
                         NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var session: URLSession!
    var task: URLSessionWebSocketTask?
    var reconnectAttempt = 0

    /// Per-connection identity. Each time we start a new WebSocket we bump
    /// this. Every receive-callback closure captures the ID it was registered
    /// under and bails out if the current ID doesn't match — so stale
    /// callbacks from cancelled tasks become no-ops instead of re-triggering
    /// reconnects. (Earlier the same cancellation fanned out into 15k+
    /// "cancelled" callbacks all racing to scheduleReconnect, which doubled
    /// each cycle and DoS'd the user's Cloudflare rate-limit from their own
    /// machine. Never again.)
    var currentConnID: UInt64 = 0

    /// Single-flight guard. Ensures only ONE delayed reconnect is in flight
    /// at a time, no matter how many callers raced to schedule one.
    var pendingReconnect = false

    var config = Config()
    var watched: [String: String] = [:]     // map -> mode filter
    var playSound = true

    var currentLobbies: [Lobby] = []
    var serverTime: Int = 0
    var connected = false

    var activeAlerts: [String: String] = [:]   // gameID -> map (for flash title)
    var prevAlertState: [String: Bool] = [:]   // gameID -> wasCurrent last tick
    var flashOn = false
    var flashTimer: Timer?

    // Stall detection. macOS sleep/wake often leaves URLSessionWebSocketTask
    // holding a TCP half-state — receive() hangs silently without firing
    // the failure callback. A watchdog timer compares the wall clock to
    // the last message time and force-reconnects if it's been too long.
    var lastMessageAt: Date = Date.distantPast
    var watchdogTimer: Timer?

    /// Set after UNUserNotificationCenter.requestAuthorization returns.
    /// When false we fall back to osascript, which still delivers a banner
    /// but attributes it to Script Editor — clicks then open that, not us.
    var notificationsAuthorized = false

    /// True while the popup menu is being displayed. Mutating menu items
    /// while AppKit is laying out the popup causes the constraint system
    /// to throw NSGenericException after enough re-layout passes — the
    /// crash observed on real usage was:
    ///   "The window has been marked as needing another Layout Window
    ///    pass, but it has already had more Layout Window passes than
    ///    there are views in the window."
    /// Gate item mutations on this flag; catch up in menuDidClose(_:).
    var menuIsOpen = false

    // Stable menu-item references so every tick mutates titles in place
    // instead of tearing the menu down. Rebuilding (removeAllItems() +
    // add) dismisses the menu if it's open and also reorders items, which
    // is what was making "Watched maps" unclickable while updates flowed.
    var statusHeaderItem: NSMenuItem!
    var currentSlotItems: [NSMenuItem] = []     // 3 rows: one per category
    var upcomingSlotItems: [NSMenuItem] = []    // 3 rows: one per category
    var watchedParentItem: NSMenuItem!          // "Watched maps (N)"
    var soundToggleItem: NSMenuItem!
    var dismissAlertItem: NSMenuItem!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = loadConfig()
        watched = config.watched_maps
        playSound = config.play_sound

        let sessionCfg = URLSessionConfiguration.default
        sessionCfg.httpAdditionalHeaders = [
            "User-Agent": SAFARI_UA,
            "Origin": "https://openfront.io",
        ]
        sessionCfg.waitsForConnectivity = true
        session = URLSession(
            configuration: sessionCfg,
            delegate: self,
            delegateQueue: OperationQueue.main
        )

        buildStatusItem()
        buildMenuStructure()
        rebuildWatchedSubmenu()
        updateMenuFromState()
        startFlashTimer()
        startWatchdog()
        registerSleepWakeHandlers()
        setupNotifications()
        connectWebSocket()
    }

    // MARK: Notifications

    /// Use the native notification API so banners are attributed to our app
    /// (rather than "Script Editor" via osascript) and a click routes
    /// through our delegate — we then open openfront.io.
    func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationsAuthorized = granted && error == nil
                NSLog("[ofmw] notification auth: granted=\(granted) error=\(error?.localizedDescription ?? "nil")")
            }
        }
    }

    func fireNotification(title: String, body: String) {
        if notificationsAuthorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Sound is already driven by the user's "Play sound on alert"
            // toggle via NSSound; leave the notification silent to avoid
            // double-playing.
            content.userInfo = ["openURL": OPENFRONT_URL.absoluteString]
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req) { err in
                if let err = err {
                    NSLog("[ofmw] notify add failed, falling back: \(err.localizedDescription)")
                    fireOsascriptNotification(title: title, body: body)
                }
            }
        } else {
            fireOsascriptNotification(title: title, body: body)
        }
    }

    // UNUserNotificationCenterDelegate

    /// Called on Apple Silicon / modern macOS when a notification arrives
    /// while our app is "frontmost" (menu-bar apps are effectively always
    /// so). Without this override, the banner would be swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NSLog("[ofmw] willPresent fired — returning [.banner, .list]")
        completionHandler([.banner, .list])
    }

    /// Called when the user clicks the notification banner. Route it to
    /// openfront.io instead of "activating" our menu-bar app (which would
    /// do nothing visible anyway).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlStr = response.notification.request.content
                        .userInfo["openURL"] as? String,
           let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    // MARK: Sleep / wake handling

    func registerSleepWakeHandlers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        nc.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc func systemWillSleep(_ note: Notification) {
        // Proactively drop the socket so it doesn't go zombie during sleep.
        // Bump currentConnID so the doomed task's pending receive callback
        // becomes a stale no-op when it fires — it must NOT kick off a
        // reconnect storm while we're asleep.
        currentConnID &+= 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    @objc func systemDidWake(_ note: Notification) {
        // Reset backoff and reconnect immediately on wake.
        reconnectAttempt = 0
        pendingReconnect = false
        connectWebSocket()
    }

    // MARK: Watchdog

    func startWatchdog() {
        // Every 2 s, check whether we've received a message in the last 10 s.
        // Server broadcasts every 500 ms so 10 s of silence (20 missed
        // broadcasts) is unambiguously a dead socket. Earlier this was
        // 5 s which caused ~200 nuisance reconnects over a 26-hour run
        // from normal network jitter + CPU throttling blips.
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            // Only care once we've ever received a message; otherwise it's
            // just the initial connect taking a moment.
            guard self.lastMessageAt > .distantPast else { return }
            // If the failure path already scheduled a reconnect, let it
            // play out — firing again would race with it.
            if self.pendingReconnect { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 10.0 {
                NSLog("[ofmw] stall detected — forcing reconnect (no frames >10s)")
                self.lastMessageAt = .distantPast
                self.reconnectAttempt = 0
                self.connectWebSocket()
            }
        }
    }

    // MARK: Status item / title

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateTitle()
    }

    // MARK: NSMenuDelegate — freeze item mutations while the menu is shown

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Any ticks that landed while the menu was open were suppressed;
        // apply the latest state now that it's safe to mutate items.
        updateMenuFromState()
    }

    func updateTitle() {
        guard let btn = statusItem.button else { return }
        let attrs: [NSAttributedString.Key: Any]
        if !activeAlerts.isEmpty {
            let color: NSColor = flashOn ? .systemRed : .systemOrange
            attrs = [
                .foregroundColor: color,
                .font: NSFont.boldSystemFont(ofSize: 0),
            ]
        } else {
            attrs = [.font: NSFont.systemFont(ofSize: 0)]
        }
        btn.attributedTitle = NSAttributedString(string: "OF", attributes: attrs)
    }

    // MARK: WebSocket

    func connectWebSocket() {
        let worker = Int.random(in: 0..<WORKER_COUNT)
        guard let url = URL(string: "wss://openfront.io/w\(worker)/lobbies")
        else { return }
        var req = URLRequest(url: url)
        req.setValue(SAFARI_UA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://openfront.io", forHTTPHeaderField: "Origin")

        // Invalidate the previous connection's receive callbacks before
        // starting a new one. Any cancelled/failed fires that land later
        // will see a mismatched connID and bail quietly.
        currentConnID &+= 1
        let connID = currentConnID

        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: req)
        task = t
        pendingReconnect = false
        t.resume()
        receiveMessage(on: t, connID: connID)
    }

    /// Callbacks are bound to a specific (task, connID) pair. If by the
    /// time the callback fires the current connection has moved on, we
    /// return immediately — no log, no reconnect. This makes cancellation
    /// idempotent and stops the reconnect-storm cascade.
    func receiveMessage(on task: URLSessionWebSocketTask, connID: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard connID == self.currentConnID else {
                // stale callback from a task we already abandoned
                return
            }
            switch result {
            case .failure(let err):
                NSLog("[ofmw] recv error: \(err.localizedDescription)")
                self.connected = false
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .string(let s): self.handleMessage(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        self.handleMessage(s)
                    }
                @unknown default: break
                }
                self.receiveMessage(on: task, connID: connID)
            }
        }
    }

    func scheduleReconnect() {
        // Single-flight: multiple callers racing here collapse into one
        // scheduled reconnect. Without this guard, duplicate triggers
        // (e.g. failure callback + didCloseWith delegate) multiplied
        // into exponential reconnect growth.
        if pendingReconnect { return }
        pendingReconnect = true
        reconnectAttempt += 1
        // Exponential backoff, 1s/2s/4s/8s/16s, capped at 30s.
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        NSLog("[ofmw] reconnect scheduled in \(delay)s (attempt \(reconnectAttempt))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connectWebSocket()
        }
    }

    // URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        connected = true
        reconnectAttempt = 0
        pendingReconnect = false
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Reconnect is driven from the receive callback's .failure branch
        // only. Calling scheduleReconnect here too caused duplicate
        // triggers per cancellation — the very bug that storm'd 15k sockets.
        connected = false
    }

    // MARK: Message handling

    func handleMessage(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        guard let pub = try? JSONDecoder().decode(PublicGames.self, from: data)
        else { return }

        serverTime = pub.serverTime
        var lobbies: [Lobby] = []
        // Iterate in a fixed category order so the rendered row order is
        // deterministic and stable tick to tick.
        for kind in CATEGORY_ORDER {
            guard let arr = pub.games[kind] else { continue }
            for (i, info) in arr.enumerated() {
                lobbies.append(Lobby(
                    kind: kind,
                    gameID: info.gameID,
                    gameMap: info.gameConfig?.gameMap ?? "",
                    gameMode: info.gameConfig?.gameMode ?? "",
                    numClients: info.numClients,
                    startsAt: info.startsAt ?? 0,
                    isCurrent: i == 0
                ))
            }
        }
        currentLobbies = lobbies
        connected = true
        lastMessageAt = Date()
        // Healthy frames → backoff is no longer warranted.
        reconnectAttempt = 0
        pendingReconnect = false

        reconcileAlerts()
        // In-place mutation only — never re-adds/removes items, so the
        // menu stays interactive while it's open.
        updateMenuFromState()
    }

    // MARK: Alerts

    func lobbyMatches(_ l: Lobby) -> Bool {
        guard let mode = watched[l.gameMap] else { return false }
        if mode == "any" { return true }
        return l.kind.lowercased() == mode
    }

    func reconcileAlerts() {
        let matches = currentLobbies.filter { lobbyMatches($0) }
        var newAlerts: [String: Lobby] = [:]
        for l in matches { newAlerts[l.gameID] = l }

        var toNotify: [(Lobby, String)] = []  // (lobby, kind: "new"|"promoted")
        for (gid, l) in newAlerts {
            if prevAlertState[gid] == nil {
                toNotify.append((l, "new"))
            } else if prevAlertState[gid] == false && l.isCurrent {
                toNotify.append((l, "promoted"))
            }
        }

        prevAlertState = newAlerts.mapValues { $0.isCurrent }
        activeAlerts = newAlerts.mapValues { $0.gameMap }

        for (l, kind) in toNotify {
            var title: String, body: String
            if kind == "promoted" {
                title = "OpenFront: \(l.gameMap) (\(l.gameMode)) is live"
                body = "Joinable NOW · \(l.numClients) players"
            } else if l.isCurrent {
                title = "OpenFront: \(l.gameMap) (\(l.gameMode))"
                body = "Starts NOW · \(l.numClients) players"
            } else {
                let when = formatCountdown(l.startsAt, serverTime) ?? "soon"
                title = "OpenFront: Upcoming \(l.gameMap) (\(l.gameMode))"
                body = "Starts in \(when) · get in early"
            }
            fireNotification(title: title, body: body)
        }
        if !toNotify.isEmpty && playSound {
            NSSound(named: "Glass")?.play()
        }
    }

    // MARK: Flash timer

    func startFlashTimer() {
        flashTimer = Timer.scheduledTimer(
            withTimeInterval: 0.35, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.flashOn.toggle()
            if !self.activeAlerts.isEmpty {
                self.updateTitle()
            }
        }
    }

    // MARK: Menu — built once, mutated in place

    func buildMenuStructure() {
        menu.removeAllItems()

        statusHeaderItem = NSMenuItem(
            title: "Connecting…", action: nil, keyEquivalent: ""
        )
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)

        menu.addItem(.separator())

        // Current lobbies section — fixed 3 slots, one per category.
        let currentHeader = NSMenuItem(
            title: "Current lobbies", action: nil, keyEquivalent: ""
        )
        currentHeader.isEnabled = false
        menu.addItem(currentHeader)
        for _ in CATEGORY_ORDER {
            let it = NSMenuItem(
                title: "    (waiting)",
                action: #selector(openOpenFront(_:)),
                keyEquivalent: ""
            )
            it.target = self
            currentSlotItems.append(it)
            menu.addItem(it)
        }

        menu.addItem(.separator())

        // Upcoming section — fixed 3 slots.
        let upcomingHeader = NSMenuItem(
            title: "Upcoming", action: nil, keyEquivalent: ""
        )
        upcomingHeader.isEnabled = false
        menu.addItem(upcomingHeader)
        for _ in CATEGORY_ORDER {
            let it = NSMenuItem(
                title: "    (waiting)",
                action: #selector(openOpenFront(_:)),
                keyEquivalent: ""
            )
            it.target = self
            upcomingSlotItems.append(it)
            menu.addItem(it)
        }

        menu.addItem(.separator())

        watchedParentItem = NSMenuItem(
            title: "Watched maps", action: nil, keyEquivalent: ""
        )
        menu.addItem(watchedParentItem)

        soundToggleItem = NSMenuItem(
            title: "Play sound on alert",
            action: #selector(toggleSound(_:)),
            keyEquivalent: ""
        )
        soundToggleItem.target = self
        menu.addItem(soundToggleItem)

        let testItem = NSMenuItem(
            title: "Send test notification",
            action: #selector(sendTestNotification(_:)),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        dismissAlertItem = NSMenuItem(
            title: "Dismiss alert",
            action: #selector(dismissAlert(_:)),
            keyEquivalent: ""
        )
        dismissAlertItem.target = self
        menu.addItem(dismissAlertItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open openfront.io",
            action: #selector(openOpenFront(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let quit = NSMenuItem(
            title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// Mutate item titles / enabled state from the current state. Safe to
    /// call any time: if the menu is currently open we only refresh the
    /// status-bar title (which is a separate view) and defer item
    /// mutations until menuDidClose.
    func updateMenuFromState() {
        updateTitle()
        if menuIsOpen { return }

        if !activeAlerts.isEmpty {
            statusHeaderItem.title =
                "ALERT: \(activeAlerts.count) watched map(s) live"
        } else if connected {
            statusHeaderItem.title = "Connected"
        } else {
            statusHeaderItem.title = "Connecting…"
        }

        // Index lobbies by (kind, current?) and populate fixed slots in
        // CATEGORY_ORDER so rows never swap places.
        var currentByKind: [String: Lobby] = [:]
        var upcomingByKind: [String: Lobby] = [:]
        for l in currentLobbies {
            if l.isCurrent {
                currentByKind[l.kind] = l
            } else if upcomingByKind[l.kind] == nil {
                // Take first upcoming per category (server sorted by startsAt).
                upcomingByKind[l.kind] = l
            }
        }

        for (i, kind) in CATEGORY_ORDER.enumerated() {
            let label = MODE_LABELS[kind] ?? kind
            setSlot(currentSlotItems[i], lobby: currentByKind[kind],
                    placeholder: "    (no \(label) lobby)")
            setSlot(upcomingSlotItems[i], lobby: upcomingByKind[kind],
                    placeholder: "    (no upcoming \(label))")
        }

        dismissAlertItem.isEnabled = !activeAlerts.isEmpty
        soundToggleItem.state = playSound ? .on : .off
    }

    private func setSlot(_ item: NSMenuItem, lobby: Lobby?, placeholder: String) {
        guard let l = lobby else {
            item.title = placeholder
            item.representedObject = nil
            item.isEnabled = false
            return
        }
        let countdown = formatCountdown(l.startsAt, serverTime) ?? ""
        let star = lobbyMatches(l) ? "★ " : "   "
        var t = "\(star)\(l.gameMap)  ·  \(l.gameMode)  ·  \(l.numClients)p"
        if !countdown.isEmpty { t += "  ·  \(countdown)" }
        item.title = t
        item.representedObject = l.gameID
        item.isEnabled = true
    }

    /// Fully rebuild the "Watched maps" submenu. Called only on watchlist
    /// changes (user action), never from a lobby tick, so it can't steal
    /// focus from the live menu.
    func rebuildWatchedSubmenu() {
        watchedParentItem.title = "Watched maps (\(watched.count))"
        let sub = NSMenu()
        sub.autoenablesItems = false

        if !watched.isEmpty {
            let h = NSMenuItem(
                title: "— Selected —", action: nil, keyEquivalent: ""
            )
            h.isEnabled = false
            sub.addItem(h)
            for m in watched.keys.sorted() {
                addMapItem(into: sub, map: m)
            }
            sub.addItem(.separator())
        }

        let ph = NSMenuItem(title: "— Popular —", action: nil, keyEquivalent: "")
        ph.isEnabled = false
        sub.addItem(ph)
        for m in POPULAR_MAPS {
            addMapItem(into: sub, map: m)
        }

        sub.addItem(.separator())
        let ah = NSMenuItem(title: "— All maps —", action: nil, keyEquivalent: "")
        ah.isEnabled = false
        sub.addItem(ah)
        for m in ALL_MAPS.sorted() {
            addMapItem(into: sub, map: m)
        }

        watchedParentItem.submenu = sub
    }

    private func addMapItem(into parent: NSMenu, map mapName: String) {
        if let mode = watched[mapName] {
            let label = MODE_LABELS[mode] ?? mode
            let mi = NSMenuItem(
                title: "\(mapName)  —  \(label)",
                action: nil,
                keyEquivalent: ""
            )
            mi.state = .on
            let sub = NSMenu()
            sub.autoenablesItems = false
            for m in MODES {
                let smi = NSMenuItem(
                    title: "Mode: \(MODE_LABELS[m] ?? m)",
                    action: #selector(setMapMode(_:)),
                    keyEquivalent: ""
                )
                smi.target = self
                smi.representedObject = [mapName, m]
                smi.state = (mode == m) ? .on : .off
                sub.addItem(smi)
            }
            sub.addItem(.separator())
            let remove = NSMenuItem(
                title: "Remove from watchlist",
                action: #selector(unwatchMap(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = mapName
            sub.addItem(remove)
            mi.submenu = sub
            parent.addItem(mi)
        } else {
            let mi = NSMenuItem(
                title: mapName,
                action: #selector(addMap(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.representedObject = mapName
            parent.addItem(mi)
        }
    }

    // MARK: Actions

    private func persistWatchlist() {
        config.watched_maps = watched
        config.play_sound = playSound
        saveConfig(config)
    }

    @objc func addMap(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        watched[m] = "any"
        persistWatchlist()
        reconcileAlerts()
        rebuildWatchedSubmenu()
        updateMenuFromState()
    }

    @objc func unwatchMap(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        watched.removeValue(forKey: m)
        persistWatchlist()
        reconcileAlerts()
        rebuildWatchedSubmenu()
        updateMenuFromState()
    }

    @objc func setMapMode(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String],
              pair.count == 2
        else { return }
        watched[pair[0]] = pair[1]
        persistWatchlist()
        reconcileAlerts()
        rebuildWatchedSubmenu()
        updateMenuFromState()
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        playSound.toggle()
        persistWatchlist()
        updateMenuFromState()
    }

    @objc func sendTestNotification(_ sender: NSMenuItem) {
        fireNotification(
            title: "OpenFront Map Watch test",
            body: "If you see this, notifications are working."
        )
        if playSound { NSSound(named: "Glass")?.play() }
    }

    @objc func dismissAlert(_ sender: NSMenuItem) {
        activeAlerts.removeAll()
        updateMenuFromState()
    }

    @objc func openOpenFront(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(OPENFRONT_URL)
    }

    @objc func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(self)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
