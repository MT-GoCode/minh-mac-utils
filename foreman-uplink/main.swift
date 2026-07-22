// Foreman Uplink — menu-bar supervisor for the reverse SSH tunnel to foreman.
//
// ❇️ in the menu bar = ssh tunnel transport alive AND foreman's web UI answers
//                      (one probe through the tunnel itself) AND local sshd is on.
// ❌ (pulsing)       = anything else; retries every 2s, forever. No logs, no state.
//
// The app OWNS the whole contract, idempotently, on every launch and every Save:
//   Mac side:     tunnel keypair, `Host foreman-tunnel` ssh config block,
//                 foreman's agent pubkey in ~/.ssh/authorized_keys (loopback-only).
//   foreman side: agent keypair, tunnel-key authorization (restrict+permitlisten),
//                 sshd keepalive drop-in, and a managed `Host <name>` block —
//                 so from foreman, `ssh <name>` reaches this Mac.
//
// Config: the foreman URL + this Mac's name on foreman (defaults to its hostname).
// The reverse-tunnel port is derived deterministically from the name, so several
// Macs can each self-register without colliding.
//
// Provisioning runs over the user's existing `Host foreman` admin alias (BatchMode);
// the tunnel key itself deliberately cannot execute anything on foreman.

import AppKit
import ServiceManagement

let PROBE_PORT = 18700          // local end of the health-probe forward
let RESPAWN_DELAY: TimeInterval = 2.0
let PROBE_INTERVAL: TimeInterval = 2.0
let MAX_PROBE_FAILURES = 3      // consecutive failed probes with a "running" ssh -> kill it
let SSHD_CHECK_EVERY = 15       // probe ticks between local-sshd checks (~30s)

let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tunnel: Process?
    private var timer: Timer?
    private var respawnScheduled = false
    private var shuttingDown = false
    private var isGreen: Bool? = nil
    private var pulseDim = false
    private var probeInFlight = false
    private var probeFailures = 0
    private var tickCount = 0
    private var sshdLocalOK = true
    private var provisionNote = ""     // "" = fine; else shown in the status line

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var window: NSWindow?
    private var urlField: NSTextField?
    private var nameField: NSTextField?

    private var foremanURL: String {
        get { UserDefaults.standard.string(forKey: "foremanURL") ?? "http://100.59.145.138:8700" }
        set { UserDefaults.standard.set(newValue, forKey: "foremanURL") }
    }
    private var macName: String {
        get {
            if let v = UserDefaults.standard.string(forKey: "macName"), !v.isEmpty { return v }
            let host = run("/usr/sbin/scutil", ["--get", "LocalHostName"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitizedName(host.isEmpty ? "mac" : host)
        }
        set { UserDefaults.standard.set(newValue, forKey: "macName") }
    }
    private var tunnelPort: Int { stablePort(for: macName) }

    func applicationDidFinishLaunching(_ note: Notification) {
        try? SMAppService.mainApp.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let cfg = NSMenuItem(title: "Configure…", action: #selector(configure), keyEquivalent: ",")
        cfg.target = self
        menu.addItem(cfg)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Foreman Uplink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon(green: false)

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "ssh -N .*foreman-tunnel"]
        try? pkill.run(); pkill.waitUntilExit()

        provisionInBackground()   // converge both sides; does not block the tunnel
        startTunnel()
        timer = Timer.scheduledTimer(withTimeInterval: PROBE_INTERVAL, repeats: true) { [weak self] _ in
            self?.probe()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.kickTunnel() }
    }

    func applicationWillTerminate(_ note: Notification) {
        shuttingDown = true
        tunnel?.terminate()
    }

    // MARK: - provisioning (idempotent; both sides converge to the contract)

    private func provisionInBackground() {
        let name = macName, port = tunnelPort
        let host = URL(string: foremanURL)?.host ?? "100.59.145.138"
        let user = NSUserName()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let note = Self.provision(name: name, port: port, foremanHost: host, macUser: user)
            DispatchQueue.main.async { self?.provisionNote = note }
        }
    }

    /// Returns "" on success, else a short human-readable problem for the status line.
    private static func provision(name: String, port: Int, foremanHost: String, macUser: String) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        // 1. Mac: tunnel keypair.
        let keyPath = sshDir.appendingPathComponent("foreman_tunnel").path
        if !fm.fileExists(atPath: keyPath) {
            run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", keyPath, "-C", "foreman-tunnel-from-mac"])
        }
        guard let pub = try? String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty
        else { return "cannot create tunnel key" }
        let pubParts = pub.split(separator: " ")
        guard pubParts.count >= 2 else { return "malformed tunnel pubkey" }
        let pubBlob = String(pubParts[1])

        // 2. Mac: `Host foreman-tunnel` block (append once; user edits are respected).
        let cfgURL = sshDir.appendingPathComponent("config")
        let cfg = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
        if !cfg.contains("Host foreman-tunnel") {
            let block = """

            Host foreman-tunnel
              User ubuntu
              IdentityFile ~/.ssh/foreman_tunnel
              IdentitiesOnly yes
              BatchMode yes
              StrictHostKeyChecking accept-new
              ExitOnForwardFailure yes
              ServerAliveInterval 15
              ServerAliveCountMax 2
              ConnectTimeout 10

            """
            if let h = FileHandle(forWritingAtPath: cfgURL.path) {
                h.seekToEndOfFile(); h.write(block.data(using: .utf8)!); h.closeFile()
            } else {
                try? block.write(to: cfgURL, atomically: true, encoding: .utf8)
            }
        }

        // 3. foreman: converge everything in one idempotent script (admin alias).
        let script = """
        set -e
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        [ -f ~/.ssh/mac_agent_key ] || ssh-keygen -t ed25519 -N '' -q -f ~/.ssh/mac_agent_key -C foreman-agents
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        grep -vF '\(pubBlob)' ~/.ssh/authorized_keys > ~/.ssh/ak.tmp || true
        printf '%s\\n' 'restrict,port-forwarding,permitlisten="127.0.0.1:\(port)" \(pub)' >> ~/.ssh/ak.tmp
        mv ~/.ssh/ak.tmp ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        if [ ! -f /etc/ssh/sshd_config.d/60-tunnel-keepalive.conf ]; then
          printf 'ClientAliveInterval 30\\nClientAliveCountMax 3\\n' | sudo tee /etc/ssh/sshd_config.d/60-tunnel-keepalive.conf >/dev/null
          sudo systemctl reload ssh 2>/dev/null || true
        fi
        touch ~/.ssh/config
        awk '/^# >>> foreman-uplink:\(name) >>>/{skip=1} skip!=1{print} /^# <<< foreman-uplink:\(name) <<</{skip=0}' ~/.ssh/config > ~/.ssh/cfg.tmp
        { echo '# >>> foreman-uplink:\(name) >>>'
          echo 'Host \(name)'
          echo '  HostName localhost'
          echo '  Port \(port)'
          echo '  User \(macUser)'
          echo '  IdentityFile ~/.ssh/mac_agent_key'
          echo '  IdentitiesOnly yes'
          echo '  StrictHostKeyChecking accept-new'
          echo '# <<< foreman-uplink:\(name) <<<'
        } >> ~/.ssh/cfg.tmp
        mv ~/.ssh/cfg.tmp ~/.ssh/config
        cat ~/.ssh/mac_agent_key.pub
        """
        let remote = run("/usr/bin/ssh",
                         ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                          "-o", "HostName=\(foremanHost)", "foreman", "bash -s"],
                         stdin: script)
        guard remote.status == 0 else { return "provisioning: cannot reach foreman admin alias" }
        guard let agentPub = remote.out.split(separator: "\n").last.map(String.init),
              agentPub.hasPrefix("ssh-")
        else { return "provisioning: no agent pubkey returned" }

        // 4. Mac: authorize foreman's agent key, loopback-only (replace any old line).
        let akURL = sshDir.appendingPathComponent("authorized_keys")
        var lines = ((try? String(contentsOf: akURL, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.removeAll { $0.contains("foreman-agents") }
        lines.append("from=\"127.0.0.1,::1\" \(agentPub)")
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: akURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: akURL.path)

        return ""
    }

    // MARK: - tunnel

    private func startTunnel() {
        guard !shuttingDown, tunnel?.isRunning != true else { return }
        let url = URL(string: foremanURL)
        let host = url?.host ?? "100.59.145.138"
        let webPort = url?.port ?? 8700

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N",
            "-o", "HostName=\(host)",
            "-R", "127.0.0.1:\(tunnelPort):127.0.0.1:22",
            "-L", "127.0.0.1:\(PROBE_PORT):127.0.0.1:\(webPort)",
            "foreman-tunnel",
        ]
        p.standardOutput = FileHandle.nullDevice   // nothing is ever logged anywhere
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRespawn() }
        }
        do { try p.run(); tunnel = p } catch { scheduleRespawn() }
    }

    private func scheduleRespawn() {
        guard !shuttingDown, !respawnScheduled else { return }
        respawnScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + RESPAWN_DELAY) { [weak self] in
            self?.respawnScheduled = false
            self?.startTunnel()
        }
    }

    private func kickTunnel() {
        tunnel?.terminate()   // termination handler respawns with fresh network
    }

    // MARK: - health

    private func probe() {
        if tunnel?.isRunning != true { startTunnel() }
        tickCount += 1
        if tickCount % SSHD_CHECK_EVERY == 1 {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let ok = run("/usr/bin/nc", ["-z", "-G", "2", "127.0.0.1", "22"]).status == 0
                DispatchQueue.main.async { self?.sshdLocalOK = ok }
            }
        }
        guard !probeInFlight else { return }
        probeInFlight = true
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(PROBE_PORT)/")!)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 599) < 500
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                self.setState(green: ok && self.sshdLocalOK)
                if ok {
                    self.probeFailures = 0
                } else {
                    // ssh can sit "running" on a dead transport for up to ~30s
                    // (ServerAlive 15x2). Don't wait: after 3 straight failed
                    // probes, kill it ourselves; the exit handler respawns it.
                    self.probeFailures += 1
                    if self.probeFailures >= MAX_PROBE_FAILURES, self.tunnel?.isRunning == true {
                        self.probeFailures = 0
                        self.tunnel?.terminate()
                    }
                }
            }
        }.resume()
    }

    private func setState(green: Bool) {
        if isGreen != green {
            isGreen = green
        }
        statusLine.title = statusText(green: green)
        setIcon(green: green)
    }

    private func statusText(green: Bool) -> String {
        if !sshdLocalOK { return "Remote Login is OFF — enable it in System Settings › Sharing" }
        if !provisionNote.isEmpty { return provisionNote }
        return green ? "Connected — `ssh \(macName)` works on foreman" : "DOWN — reconnecting…"
    }

    private func setIcon(green: Bool) {
        guard let button = statusItem.button else { return }
        if green {
            button.attributedTitle = NSAttributedString(string: "❇️")
        } else {
            pulseDim.toggle()
            button.attributedTitle = NSAttributedString(
                string: "❌",
                attributes: pulseDim ? [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.25)] : [:])
        }
    }

    // MARK: - config window

    @objc private func configure() {
        showConfigWindow()
    }

    private func showConfigWindow() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Foreman Uplink"
            w.isReleasedWhenClosed = false
            w.center()

            let urlLabel = NSTextField(labelWithString: "Foreman URL (host is used for the ssh tunnel):")
            urlLabel.frame = NSRect(x: 20, y: 120, width: 400, height: 20)
            let uField = NSTextField(string: foremanURL)
            uField.frame = NSRect(x: 20, y: 92, width: 400, height: 24)

            let nameLabel = NSTextField(labelWithString: "This Mac's name on foreman (→ `ssh <name>`):")
            nameLabel.frame = NSRect(x: 20, y: 64, width: 400, height: 20)
            let nField = NSTextField(string: macName)
            nField.frame = NSRect(x: 20, y: 36, width: 400, height: 24)

            let save = NSButton(title: "Save & Provision", target: self, action: #selector(saveConfig))
            save.frame = NSRect(x: 290, y: 4, width: 130, height: 28)
            save.bezelStyle = .rounded
            save.keyEquivalent = "\r"

            for v in [urlLabel, uField, nameLabel, nField, save] as [NSView] {
                w.contentView?.addSubview(v)
            }
            window = w
            urlField = uField
            nameField = nField
        }
        urlField?.stringValue = foremanURL
        nameField?.stringValue = macName
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveConfig() {
        let urlValue = urlField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameValue = sanitizedName(nameField?.stringValue ?? "")
        guard URL(string: urlValue)?.host != nil, !nameValue.isEmpty else { NSSound.beep(); return }
        foremanURL = urlValue
        macName = nameValue
        window?.close()
        setState(green: false)
        provisionInBackground()
        kickTunnel()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
