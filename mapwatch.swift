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

// MARK: - Constants

let OPENFRONT_URL = URL(string: "https://openfront.io/")!
let WORKER_COUNT = 20

let MODES = ["any", "ffa", "team", "special"]
let MODE_LABELS: [String: String] = [
    "any": "Any", "ffa": "FFA", "team": "Team", "special": "Special",
]

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

func fireNotification(title: String, body: String) {
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
                         URLSessionWebSocketDelegate {

    var statusItem: NSStatusItem!
    var menu: NSMenu!

    var session: URLSession!
    var task: URLSessionWebSocketTask?
    var reconnectAttempt = 0

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

    var lastFingerprint = ""

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
        rebuildMenu()
        startFlashTimer()
        connectWebSocket()
    }

    // MARK: Status item / title

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateTitle()
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

        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receiveMessage()
    }

    func receiveMessage() {
        task?.receive { [weak self] result in
            guard let self else { return }
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
                self.receiveMessage()
            }
        }
    }

    func scheduleReconnect() {
        reconnectAttempt += 1
        // Exponential backoff, capped at 30 s.
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
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
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        connected = false
        scheduleReconnect()
    }

    // MARK: Message handling

    func handleMessage(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        guard let pub = try? JSONDecoder().decode(PublicGames.self, from: data)
        else { return }

        serverTime = pub.serverTime
        var lobbies: [Lobby] = []
        for (kind, arr) in pub.games {
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

        reconcileAlerts()

        // Fingerprint check — only rebuild menu when lobby state actually
        // changed. Prevents flicker while the menu is open and saves CPU.
        let fp = lobbies.map {
            "\($0.gameID)|\($0.numClients)|\($0.startsAt)|\($0.isCurrent ? 1 : 0)"
        }.joined(separator: ",")
        if fp != lastFingerprint {
            lastFingerprint = fp
            rebuildMenu()
        } else {
            updateTitle()
        }
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

    // MARK: Menu

    func rebuildMenu() {
        menu.removeAllItems()

        // Header status line
        let statusText: String
        if !activeAlerts.isEmpty {
            statusText = "ALERT: \(activeAlerts.count) watched map(s) live"
        } else if connected {
            statusText = "Connected"
        } else {
            statusText = "Connecting…"
        }
        addDisabled(statusText)
        menu.addItem(.separator())

        // Split current / upcoming
        let current = currentLobbies.filter { $0.isCurrent }
        let upcoming = currentLobbies.filter { !$0.isCurrent }
        addLobbyRows("Current lobbies (\(current.count))", current)
        menu.addItem(.separator())
        addLobbyRows("Upcoming (\(upcoming.count))", upcoming)
        menu.addItem(.separator())

        // Watched maps submenu
        let watchedItem = NSMenuItem(
            title: "Watched maps (\(watched.count))", action: nil, keyEquivalent: ""
        )
        let watchedMenu = NSMenu()
        watchedMenu.autoenablesItems = false

        if !watched.isEmpty {
            let h = NSMenuItem(title: "— Selected —", action: nil, keyEquivalent: "")
            h.isEnabled = false
            watchedMenu.addItem(h)
            for m in watched.keys.sorted() {
                addMapItem(into: watchedMenu, map: m)
            }
            watchedMenu.addItem(.separator())
        }

        let ph = NSMenuItem(title: "— Popular —", action: nil, keyEquivalent: "")
        ph.isEnabled = false
        watchedMenu.addItem(ph)
        for m in POPULAR_MAPS {
            addMapItem(into: watchedMenu, map: m)
        }

        watchedMenu.addItem(.separator())
        let ah = NSMenuItem(title: "— All maps —", action: nil, keyEquivalent: "")
        ah.isEnabled = false
        watchedMenu.addItem(ah)
        for m in ALL_MAPS.sorted() {
            addMapItem(into: watchedMenu, map: m)
        }

        watchedItem.submenu = watchedMenu
        menu.addItem(watchedItem)

        // Sound toggle
        let soundItem = NSMenuItem(
            title: "Play sound on alert",
            action: #selector(toggleSound(_:)),
            keyEquivalent: ""
        )
        soundItem.target = self
        soundItem.state = playSound ? .on : .off
        menu.addItem(soundItem)

        // Test notification
        let testItem = NSMenuItem(
            title: "Send test notification",
            action: #selector(sendTestNotification(_:)),
            keyEquivalent: ""
        )
        testItem.target = self
        menu.addItem(testItem)

        // Dismiss alert
        let dismiss = NSMenuItem(
            title: "Dismiss alert",
            action: #selector(dismissAlert(_:)),
            keyEquivalent: ""
        )
        dismiss.target = self
        dismiss.isEnabled = !activeAlerts.isEmpty
        menu.addItem(dismiss)

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

        updateTitle()
    }

    private func addDisabled(_ text: String) {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        menu.addItem(it)
    }

    private func addLobbyRows(_ header: String, _ group: [Lobby]) {
        let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)

        if group.isEmpty {
            let e = NSMenuItem(title: "    (none)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
            return
        }
        for lob in group {
            let countdown = formatCountdown(lob.startsAt, serverTime) ?? ""
            let star = lobbyMatches(lob) ? "★ " : "   "
            var title = "\(star)\(lob.gameMap)  ·  \(lob.gameMode)  ·  \(lob.numClients)p"
            if !countdown.isEmpty { title += "  ·  \(countdown)" }
            let it = NSMenuItem(
                title: title,
                action: #selector(openOpenFront(_:)),
                keyEquivalent: ""
            )
            it.target = self
            it.representedObject = lob.gameID
            menu.addItem(it)
        }
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
        rebuildMenu()
    }

    @objc func unwatchMap(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        watched.removeValue(forKey: m)
        persistWatchlist()
        reconcileAlerts()
        rebuildMenu()
    }

    @objc func setMapMode(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String],
              pair.count == 2
        else { return }
        watched[pair[0]] = pair[1]
        persistWatchlist()
        reconcileAlerts()
        rebuildMenu()
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        playSound.toggle()
        persistWatchlist()
        rebuildMenu()
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
        rebuildMenu()
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
