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

    // One button, Android-style: heal whatever is stale, fire every prompt macOS
    // offers, and say plainly what is left that only a human can click.
    @objc private func requestPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let log = healAndRequest()

        let unresolved = log.filter { $0.hasPrefix("✗") || $0.hasPrefix("!") }
        let alert = NSAlert()
        alert.messageText = unresolved.isEmpty
            ? "Remote Agent Connector — all permissions in place"
            : "Remote Agent Connector — \(unresolved.count) need a click"
        alert.informativeText = log.joined(separator: "\n") + (unresolved.isEmpty ? "" : """


        The ✗ lines are the ones macOS gives no API for — no app can grant them, so
        the panes are already open. Anything that said "cleared a STALE grant" was a
        checkbox that looked ticked but was dead: TCC pins each grant to the app's
        code signature, so re-signing silently invalidates it while Settings keeps
        showing it as on. Pressing + there does nothing; it had to be removed first.
        """)
        alert.addButton(withTitle: "Done")
        if !unresolved.isEmpty { alert.addButton(withTitle: "Re-check") }
        if alert.runModal() == .alertSecondButtonReturn { requestPermissions() }
    }

}


// MARK: - permission report
//
// macOS has no API to GRANT anything — only to prompt (Accessibility, Screen
// Recording, Automation) or to deep-link the pane (Full Disk Access, which has
// no prompt at all). And /usr/libexec/sshd-keygen-wrapper can never be added
// programmatically by anyone: it is Apple's binary, it is what launchd execs for
// every ssh connection, and TCC blames it for whatever a bare `ssh mac <cmd>`
// tries to touch. So the honest job here is: report precisely what is missing and
// say which pane fixes it.
//
// WHY THERE IS NO requestFullDiskAccess(), since this keeps coming up:
//
// Every promptable permission is tied to one action at one moment — you open the
// camera, macOS asks about the camera. FDA is not a resource, it is a blanket
// exemption from TCC for the whole filesystem, including other apps' private data
// (Mail, Messages, Safari history, the TCC dbs themselves). There is no single
// action that would justify it, and "allow access to everything, forever" is
// precisely the dialog malware would want to spam. Apple made it deliberately
// high-friction instead: the user must open System Settings and flip it by hand.
// A prompt can be social-engineered; a trip to a Settings pane cannot.
//
// The enforcement differs too, which is why no prompt appears even by accident:
//   • protected FOLDERS (Desktop/Documents/Downloads) — TCC suspends the syscall
//     and prompts, so those CAN be triggered by just touching the folder.
//   • FDA-class paths (~/Library/Mail, TCC.db, Safari data) — TCC denies outright
//     with EPERM. Nothing is suspended, so there is nothing to prompt about.
// That denial is exactly what hasFullDisk() below relies on as its probe.
//
// Apple did split the ladder on purpose: kTCCServiceSystemPolicyAppData ("access
// data from other apps") IS promptable; kTCCServiceSystemPolicyAllFiles is not.
//
// ponytail: the only way left to set FDA programmatically is to drive System
// Settings' own UI via our Accessibility grant — a robot clicking the same
// checkbox a human would. Not built: it breaks whenever Apple reshuffles that
// pane. Add it if hand-granting FDA on each new Mac becomes the real friction.

// tccutil's name for a service is the kTCCService prefix stripped off.
struct Perm {
    let label: String
    let service: String          // kTCCService…
    let live: () -> Bool         // the authoritative check: does it work RIGHT NOW
    let request: (() -> Void)?   // nil = macOS offers no request API at all
    let pane: String             // deep link for the manual cases
}

private let userTCC = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
private let systemTCC = "/Library/Application Support/com.apple.TCC/TCC.db"
private let wrapperPath = "/usr/libexec/sshd-keygen-wrapper"

// The user TCC db is itself FDA-protected, so reading it IS the FDA probe. See the
// note above: FDA-class paths are denied outright with EPERM rather than prompted.
func hasFullDisk() -> Bool {
    (try? Data(contentsOf: URL(fileURLWithPath: userTCC), options: .mappedIfSafe)) != nil
}

// Raw auth_value, or nil when there is no row / we cannot read the dbs.
// Automation lives in the USER db while the rest live in the system one, so both
// are consulted — checking only one silently reports Automation missing forever.
func tccAuth(client: String, service: String) -> Int? {
    guard hasFullDisk() else { return nil }
    for db in [systemTCC, userTCC] {
        let q = "select auth_value from access where client='\(client)' and service='\(service)' limit 1;"
        let r = run("/usr/bin/sqlite3", [db, q])
        if r.status == 0, let v = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
    }
    return nil
}

func appPerms() -> [Perm] {
    [
        Perm(label: "Screen Recording", service: "kTCCServiceScreenCapture",
             live: { CGPreflightScreenCaptureAccess() },
             request: { _ = CGRequestScreenCaptureAccess() },
             pane: "Privacy_ScreenCapture"),
        Perm(label: "Accessibility", service: "kTCCServiceAccessibility",
             live: { AXIsProcessTrusted() },
             // Per the header: prompting is asynchronous and does NOT affect the return
             // value. It only informs the user; it never grants.
             request: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) },
             pane: "Privacy_Accessibility"),
        Perm(label: "Automation (System Events)", service: "kTCCServiceAppleEvents",
             live: { run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get name of first process"]).status == 0 },
             request: { _ = run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get name of first process"]) },
             pane: "Privacy_Automation"),
        // No request API exists for this one, for anyone. Report only.
        Perm(label: "Full Disk Access", service: "kTCCServiceSystemPolicyAllFiles",
             live: { hasFullDisk() }, request: nil, pane: "Privacy_AllFiles"),
    ]
}

func openPane(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
}

// THE core of "just press the button".
//
// Apple's header for CGRequestScreenCaptureAccess is explicit: "A previously denied
// process is not re-prompted; the user must enable access in System Settings."
// The same is true across TCC — once a decision exists, request APIs silently no-op.
// That is also what happens when a grant goes STALE: TCC stores a code requirement
// alongside each row, so re-signing the app with a different identity (self-signed →
// Developer ID) leaves a row that still says "allowed" and a checkbox that still
// looks ticked, while every actual call is denied. Pressing + in Settings does not
// help, because the entry is already there.
//
// So: whenever a permission does not work but a row exists, clear the row with
// tccutil first. That returns the service to "undetermined", which is the one state
// in which the request API will actually prompt again.
func healAndRequest() -> [String] {
    var log: [String] = []
    let bundleID = Bundle.main.bundleIdentifier ?? "com.minh.remote-agent-connector"

    for p in appPerms() {
        if p.live() { log.append("✓ \(p.label)"); continue }
        let row = tccAuth(client: bundleID, service: p.service)
        // A row that claims "allowed" while the live check fails is a stale grant.
        let stale = (row ?? 0) >= 2
        if row != nil, p.request != nil {
            let name = p.service.replacingOccurrences(of: "kTCCService", with: "")
            let r = run("/usr/bin/tccutil", ["reset", name, bundleID])
            log.append(r.status == 0
                ? "↻ \(p.label): cleared \(stale ? "a STALE grant (re-signed app)" : "a previous denial") so macOS will ask again"
                : "!  \(p.label): could not reset (\(name)) — remove it by hand in Settings, then press this again")
        }
        if let request = p.request {
            request()
            log.append(p.live() ? "✓ \(p.label) (just granted)" : "…\(p.label): prompted — click Allow" )
        } else {
            log.append("✗ \(p.label): macOS has no request API — opening the pane, add this app by hand")
            openPane(p.pane)
        }
    }

    // The ssh identity. Prompt-on-use services can be driven for it over the
    // loopback cert; the rest have to be clicked, same as ours.
    log.append(contentsOf: wrapperStatus())
    return log
}


// Fire the prompts AS sshd-keygen-wrapper.
//
// TCC blames whatever launchd exec'd for a session, so for an ssh command that is
// always /usr/libexec/sshd-keygen-wrapper — never this app, and never a program we
// can run directly. The only way to make the wrapper the responsible process is to
// genuinely come in over ssh. We can: rac's own agent CA is already installed in
// authorized_keys as cert-authority with from="127.0.0.1,::1", so minting a
// short-lived cert for ourselves and connecting to localhost is the same trust path
// an agent uses, just loopback-only. Prompts then land on the wrapper's row.
//
// Only prompt-on-use services can be driven this way. Full Disk Access has no prompt
// at all and Accessibility only deep-links, so both stay manual for the wrapper.
func triggerWrapperPermissions() -> String {
    let ca = racDir.appendingPathComponent("agent_ca").path
    guard FileManager.default.fileExists(atPath: ca) else { return "no agent CA yet — run `rac setup` first" }
    let user = NSUserName()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rac-perm-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: tmp) }
    let key = tmp.appendingPathComponent("k").path

    guard run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key, "-C", "rac-perm-trigger"]).status == 0,
          run("/usr/bin/ssh-keygen", ["-q", "-s", ca, "-I", "rac-perm-trigger", "-n", user, "-V", "+5m", key + ".pub"]).status == 0
    else { return "could not mint a loopback cert" }

    let script = "/usr/bin/osascript -e 'tell application \"System Events\" to get name of every process' >/dev/null 2>&1"
    let r = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
                                 "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=8",
                                 "-i", key, "\(user)@localhost", script])
    return r.status == 0 ? "triggered over loopback cert ✓" : "ssh to localhost failed: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))"
}

func wrapperStatus() -> [String] {
    var log: [String] = []
    guard hasFullDisk() else {
        log.append("?  sshd-keygen-wrapper: needs Full Disk Access above before its state can be read")
        return log
    }
    let trigger = triggerWrapperPermissions()
    for (svc, label, pane) in [("kTCCServiceAppleEvents", "Automation", "Privacy_Automation"),
                               ("kTCCServiceSystemPolicyAllFiles", "Full Disk Access", "Privacy_AllFiles"),
                               ("kTCCServiceAccessibility", "Accessibility", "Privacy_Accessibility")] {
        let ok = (tccAuth(client: wrapperPath, service: svc) ?? 0) >= 2
        if ok { log.append("✓ ssh (sshd-keygen-wrapper) → \(label)"); continue }
        if svc == "kTCCServiceAppleEvents" {
            log.append("…ssh → \(label): \(trigger)")
        } else {
            log.append("✗ ssh → \(label): no request API — add \(wrapperPath) by hand (+ ▸ ⇧⌘G)")
            openPane(pane)
        }
    }
    return log
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // in the Dock (for the Dock menu) + Login Items
let delegate = AppDelegate()
app.delegate = delegate
app.run()
