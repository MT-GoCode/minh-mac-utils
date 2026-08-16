// Remote Agent Connector — one Mac app that lets remote agents reach in.
//
// Two jobs:
//   1. TRANSPORT: keep an OUTBOUND reverse-SSH tunnel to your middleman box alive
//      forever, so `ssh` from an authorized machine reaches this Mac's sshd. Nothing
//      listens for inbound connections on the Mac itself. (Self-provisions both sides.)
//   2. HANDS: hold the macOS permissions (Screen Recording / Accessibility / Automation)
//      and the unlocked login keychain that an `ssh` session can NEVER have — and expose
//      them on 127.0.0.1 so a command run over ssh can ask THIS app (via the `rac` CLI)
//      to do the privileged thing as itself. That's the only way GUI/keychain actions
//      work for a remote session on macOS; sshd's own identity is permanently denied.
//
// Dock menu: "Get Permissions" (grant this app everything, once) and "See Guide".
// Menu-bar glyph: ❇️ = tunnel healthy, ❌ = reconnecting.

import AppKit
import ServiceManagement
import Network
import ApplicationServices
import CoreGraphics
import Security

let PROBE_PORT = 18700          // local end of the health-probe forward
let RELAY_PORT: UInt16 = 18701  // loopback-only capability relay (exec/screenshot/type/click)
let RESPAWN_DELAY: TimeInterval = 2.0
let PROBE_INTERVAL: TimeInterval = 2.0
let MAX_PROBE_FAILURES = 3
let SSHD_CHECK_EVERY = 15

let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
let racDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".remote-agent-connector")

// MARK: - small helpers

@discardableResult
func run(_ tool: String, _ args: [String], stdin: String? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    if let stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        do { try p.run() } catch { return (1, "") }
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    } else {
        do { try p.run() } catch { return (1, "") }
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func sanitizedName(_ raw: String) -> String {
    let s = raw.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" }
    return String(String(s).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32))
}

// Deterministic (djb2 — NOT Swift's per-process-seeded hash) port in 2200..2899.
func stablePort(for name: String) -> Int {
    var h: UInt32 = 5381
    for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
    return 2200 + Int(h % 700)
}

func loadOrCreateRelayToken() -> String {
    let fm = FileManager.default
    try? fm.createDirectory(at: racDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let tokenURL = racDir.appendingPathComponent("relay.token")
    if let existing = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !existing.isEmpty {
        return existing
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    return token
}

// Parse the CLI-managed config (~/.remote-agent-connector/config): KEY=VALUE lines, # comments.
// The `rac` CLI owns this file; the app only reads it to know where to tunnel.
func readConfig() -> [String: String] {
    guard let txt = try? String(contentsOf: racDir.appendingPathComponent("config"), encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for raw in txt.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = String(raw)
        if let h = line.firstIndex(of: "#") { line = String(line[..<h]) }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { d[k] = v }
    }
    return d
}

// MARK: - capability relay
//
// TCC attributes a command run via `ssh mac <cmd>` to sshd's responsible process,
// which macOS refuses to ever prompt for — permanently denied, no dialog. So privileged
// actions can't be shelled out over ssh directly. Instead: this GUI app (a real,
// promptable, WindowServer-attached process in the user's UNLOCKED login session) holds
// the permissions AND the keychain, and listens on 127.0.0.1 only. `rac <cmd>` reaches
// in locally to ask THIS process to run things — with its grants, not sshd's.
final class RelayServer {
    private var listener: NWListener?
    private let port: UInt16
    private let token: String

    init(port: UInt16, token: String) { self.port = port; self.token = token }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func receiveMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
                guard let self else { return }
                if error != nil { conn.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 8_000_000 { self.respond(conn, 400, "Bad Request") } else { receiveMore() }
                    return
                }
                let headerStr = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let lines = headerStr.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                guard let requestLine = lines.first else { self.respond(conn, 400, "Bad Request"); return }
                let parts = requestLine.split(separator: " ")
                guard parts.count >= 2 else { self.respond(conn, 400, "Bad Request"); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let idx = line.firstIndex(of: ":") else { continue }
                    let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                    headers[k] = v
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                // Reject an oversized/negative body BEFORE buffering it, and AUTHENTICATE on the headers
                // BEFORE draining the body — otherwise any local process can declare a huge Content-Length
                // and OOM the relay (the token check in route() only ran AFTER the whole body was buffered).
                if contentLength < 0 || contentLength > 8_000_000 { self.respond(conn, 413, "Payload Too Large"); return }
                guard headers["authorization"] == "Bearer \(self.token)" else { self.respond(conn, 401, "unauthorized"); return }
                let bodyStart = headerEnd.upperBound
                if buffer.count - bodyStart < contentLength { receiveMore(); return }
                let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
                self.route(conn, method: String(parts[0]), pathAndQuery: String(parts[1]), headers: headers, body: body)
            }
        }
        receiveMore()
    }

    private func route(_ conn: NWConnection, method: String, pathAndQuery: String, headers: [String: String], body: Data) {
        guard headers["authorization"] == "Bearer \(token)" else { respond(conn, 401, "unauthorized"); return }
        let comps = pathAndQuery.split(separator: "?", maxSplits: 1)
        let path = String(comps[0])
        var params: [String: String] = [:]
        if comps.count > 1 {
            for pair in comps[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { params[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
            }
        }
        switch (method, path) {
        case ("GET", "/health"):
            respondJSON(conn, ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()])

        case ("POST", "/exec"):
            // Run an arbitrary command as THIS app: inherits its TCC grants, its unlocked
            // login keychain (so codesign/security work with no prompt), and its GUI session.
            guard let cmd = String(data: body, encoding: .utf8), !cmd.isEmpty else { respond(conn, 400, "empty command"); return }
            let (code, out) = self.runAsApp(cmd)
            self.sendExit(conn, out: out, exit: code)

        case ("POST", "/applescript"):
            guard let script = String(data: body, encoding: .utf8), !script.isEmpty else { respond(conn, 400, "empty script"); return }
            let (code, out) = self.runAppleScript(script)
            self.sendExit(conn, out: out, exit: code)

        case ("GET", "/screenshot"):
            // NOT a dot-prefixed path: screencapture silently no-ops for hidden filenames.
            let tmp = "/tmp/rac-shot-\(UUID().uuidString).png"
            var args = ["-x"]
            if let win = params["window"], Int(win) != nil { args += ["-o", "-l", win] }  // one window by CGWindowID
            args.append(tmp)
            let res = run("/usr/sbin/screencapture", args)
            guard res.status == 0, let data = FileManager.default.contents(atPath: tmp), !data.isEmpty else {
                respond(conn, 500, "screenshot failed — grant Screen Recording (Dock ▸ Get Permissions), or bad window id"); return
            }
            try? FileManager.default.removeItem(atPath: tmp)
            respondBinary(conn, data, contentType: "image/png")

        case ("GET", "/windows"):
            respondBinary(conn, Self.windowListJSON(), contentType: "application/json")

        case ("POST", "/type"):
            guard let text = String(data: body, encoding: .utf8), !text.isEmpty else { respond(conn, 400, "empty body"); return }
            guard AXIsProcessTrusted() else { respond(conn, 403, "accessibility not granted"); return }
            typeText(text); respond(conn, 200, "ok")

        case ("POST", "/click"):
            guard let x = Double(params["x"] ?? ""), let y = Double(params["y"] ?? "") else { respond(conn, 400, "need x,y"); return }
            guard AXIsProcessTrusted() else { respond(conn, 403, "accessibility not granted"); return }
            clickAt(x: x, y: y); respond(conn, 200, "ok")

        default:
            respond(conn, 404, "not found")
        }
    }

    // Arbitrary command via a login shell, stdout+stderr merged, real exit code.
    private func runAsApp(_ command: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (127, "spawn failed: \(error)\n") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // osascript reading the program from stdin, run as this app (Automation attributed here).
    private func runAppleScript(_ script: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe
        do { try p.run() } catch { return (127, "spawn failed\n") }
        inPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // On-screen normal app windows (layer 0), for `rac windows` and per-window screenshots.
    // Reading window titles requires Screen Recording — which this app has and sshd never can.
    static func windowListJSON() -> Data {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infos = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        var out: [[String: Any]] = []
        for w in infos {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }   // normal windows only
            let app = w[kCGWindowOwnerName as String] as? String ?? ""
            if app.isEmpty { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            func num(_ k: String) -> Int { (b[k] as? NSNumber)?.intValue ?? 0 }
            out.append([
                "id": w[kCGWindowNumber as String] as? Int ?? 0,
                "app": app,
                "title": w[kCGWindowName as String] as? String ?? "",
                "x": num("X"), "y": num("Y"), "w": num("Width"), "h": num("Height"),
            ])
        }
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data("[]".utf8)
    }

    private func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            var chars = [UniChar(truncatingIfNeeded: scalar.value)]
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars); down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars); up.post(tap: .cghidEventTap)
            }
        }
    }

    private func clickAt(x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func respond(_ conn: NWConnection, _ code: Int, _ text: String) {
        sendHTTP(conn, code: code, contentType: "text/plain", body: Data(text.utf8))
    }
    private func respondBinary(_ conn: NWConnection, _ data: Data, contentType: String) {
        sendHTTP(conn, code: 200, contentType: contentType, body: data)
    }
    private func respondJSON(_ conn: NWConnection, _ obj: [String: Bool]) {
        let body = "{" + obj.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
        sendHTTP(conn, code: 200, contentType: "application/json", body: Data(body.utf8))
    }
    // Command result: body is the output, exit code rides an X-Exit-Code header.
    private func sendExit(_ conn: NWConnection, out: String, exit: Int32) {
        sendHTTP(conn, code: 200, contentType: "text/plain", body: Data(out.utf8), extra: ["X-Exit-Code": "\(exit)"])
    }

    private func sendHTTP(_ conn: NWConnection, code: Int, contentType: String, body: Data, extra: [String: String] = [:]) {
        let statusText = ["200": "OK", "400": "Bad Request", "401": "Unauthorized", "403": "Forbidden",
                          "404": "Not Found", "500": "Internal Server Error"]["\(code)"] ?? ""
        var head = "HTTP/1.1 \(code) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var full = Data(head.utf8); full.append(body)
        conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tunnel: Process?
    private var timer: Timer?
    private var respawnScheduled = false
    private var shuttingDown = false
    private var agentCount = 0
    private var tickCount = 0
    private var sshdLocalOK = true
    private var provisionNote = ""

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var relay: RelayServer?

    func applicationDidFinishLaunching(_ note: Notification) {
        try? SMAppService.mainApp.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(menuItem("Get Permissions", #selector(requestPermissions)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Remote Agent Connector", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon()

        let token = loadOrCreateRelayToken()
        relay = RelayServer(port: RELAY_PORT, token: token)
        relay?.start()

        // Clear a tunnel left by a previous instance, then start ours from config.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "ssh -N -i .*remote-agent-connector/tunnel_key"]
        try? pkill.run(); pkill.waitUntilExit()

        startTunnel()
        timer = Timer.scheduledTimer(withTimeInterval: PROBE_INTERVAL, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.kickTunnel() }
    }

    func applicationWillTerminate(_ note: Notification) { shuttingDown = true; tunnel?.terminate() }

    private func menuItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; return i
    }

    // Right-click Dock icon → these live here too (the buttons you asked for).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let s = NSMenuItem(title: statusText(), action: nil, keyEquivalent: ""); s.isEnabled = false
        m.addItem(s); m.addItem(.separator())
        m.addItem(menuItem("Get Permissions", #selector(requestPermissions)))
        return m
    }

    // MARK: - tunnel

    private func startTunnel() {
        guard !shuttingDown, tunnel?.isRunning != true else { return }
        // Everything derives from the ssh target + name in config — nothing else to store.
        // Until `rac setup` fills those in, there's no middleman: stay idle.
        let c = readConfig()
        guard let mid = c["MIDDLEMAN"], !mid.isEmpty,
              let name = c["MACHINE_NAME"], !name.isEmpty else { return }
        // Pass the target verbatim so ~/.ssh/config fully applies (aliases, ProxyJump,
        // per-hop identities). Resolving to user@host here would strip the jump path and
        // dial hosts that are only reachable through it.
        let target = mid.split(separator: " ").map(String.init)
        let key = racDir.appendingPathComponent("tunnel_key").path
        guard FileManager.default.fileExists(atPath: key) else { return }
        let port = String(stablePort(for: name))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-i", key,
                       "-o", "IdentitiesOnly=yes",
                       "-o", "StrictHostKeyChecking=accept-new",
                       "-o", "ExitOnForwardFailure=yes",
                       "-o", "ServerAliveInterval=15",
                       "-o", "ServerAliveCountMax=2",
                       "-o", "ConnectTimeout=10",
                       "-o", "BatchMode=yes",
                       "-R", "127.0.0.1:\(port):127.0.0.1:22"]
                      + target
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.scheduleRespawn() } }
        do { try p.run(); tunnel = p } catch { scheduleRespawn() }
    }

    private func scheduleRespawn() {
        guard !shuttingDown, !respawnScheduled else { return }
        respawnScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + RESPAWN_DELAY) { [weak self] in
            self?.respawnScheduled = false; self?.startTunnel()
        }
    }

    private func kickTunnel() { tunnel?.terminate() }

    // MARK: - health

    // The tunnel is kept up quietly (that's how agents reach in); the glyph shows PRESENCE —
    // bland when idle, filled when an agent is actually connected — not tunnel churn.
    private func tick() {
        if tunnel?.isRunning != true { startTunnel() }
        tickCount += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sshd = run("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", "22"]).status == 0
            let agents = Self.connectedAgents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sshdLocalOK = sshd
                self.agentCount = agents
                self.refresh()
            }
        }
    }

    // Agents arrive through the reverse tunnel as loopback connections into sshd (:22).
    private static func connectedAgents() -> Int {
        let out = run("/usr/sbin/netstat", ["-an", "-p", "tcp"]).out
        return out.split(separator: "\n").filter { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return f.count >= 6 && f[3] == "127.0.0.1.22" && f[5] == "ESTABLISHED"
        }.count
    }

    private func refresh() {
        statusLine.title = statusText()
        setIcon()
    }

    private func statusText() -> String {
        if !sshdLocalOK { return "Remote Login is OFF — enable it in System Settings › Sharing" }
        if !provisionNote.isEmpty { return provisionNote }
        if agentCount > 0 { return "\(agentCount) live session\(agentCount == 1 ? "" : "s") — agent working" }
        return "Ready — idle (no active session)"
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        if !sshdLocalOK {
            button.attributedTitle = NSAttributedString(string: "◌", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        } else if agentCount > 0 {
            button.attributedTitle = NSAttributedString(string: "●", attributes: [.foregroundColor: NSColor.systemGreen])
        } else {
            button.attributedTitle = NSAttributedString(string: "○", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    // MARK: - permissions + guide

    @objc private func requestPermissions() {
        let screenOK = CGRequestScreenCaptureAccess()
        let axOK = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        // Warm the Automation consent so `rac exec osascript`/AppleScript works later.
        DispatchQueue.global(qos: .utility).async {
            _ = run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get name of first process"])
        }
        let alert = NSAlert()
        alert.messageText = "Remote Agent Connector — Permissions"
        alert.informativeText = """
        Screen Recording: \(screenOK ? "granted ✓" : "prompted — click Allow, then relaunch")
        Accessibility: \(axOK ? "granted ✓" : "prompted — click Allow, then relaunch")
        Automation: a “control System Events” prompt may appear — click Allow.

        These let remote agents' `rac` commands take screenshots, click/type, run
        AppleScript, and sign with your keychain AS THIS APP — the one identity in the
        ssh path macOS will grant. Bare ssh can never be granted these.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // in the Dock (for the Dock menu) + Login Items
let delegate = AppDelegate()
app.delegate = delegate
app.run()
