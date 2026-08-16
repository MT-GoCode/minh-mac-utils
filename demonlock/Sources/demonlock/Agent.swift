import AppKit
import Foundation

/// The logged-in GUI agent: runs the sensor feed (location + BSSID) to the root enforcer and
/// shows the status/countdown panel (phase, reason, red/green policy tree, Disarm). Closing the
/// window does nothing; it pops to front on a countdown. A menubar item reflects phase.
final class AgentApp: NSObject, NSApplicationDelegate {
    private var feeder: SensorFeeder!
    private var activity: NSObjectProtocol?
    private var statusItem: NSStatusItem!

    private var window: NSWindow!
    private var header: NSView!
    private var bigLabel: NSTextField!
    private var reasonLabel: NSTextField!
    private var treeView: NSTextView!
    private var healthLabel: NSTextField!
    private var disarmButton: NSButton!
    private var permButton: NSButton!
    private var lastPhase = ""
    private var lastRVPhase = ""
    private var dpApplied: [String: Double] = [:]   // kind → last-seen lastAppliedEpoch (drives apply alerts)
    private var dpSeeded = false                     // skip alerts on the first refresh (seed the baseline)

    func applicationDidFinishLaunching(_ note: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "demonlock sensor feed must keep reporting")
        feeder = SensorFeeder(settings: Settings.load())
        feeder.start()
        buildMenubar()
        buildWindow()
        Timer.scheduledTimer(withTimeInterval: Settings.load().agentRefreshSeconds, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Surface a release-valve grant/revoke as an ALERT DIALOG, not a notification banner. Focus /
    /// Do Not Disturb filters *notifications*, but a dialog is ordinary app UI — so it shows even
    /// during a Sleep focus, which is what you want for "your admin just unlocked/relocked". Runs
    /// DETACHED on a background queue (the alert is modal — blocking the agent's 0.25s refresh loop
    /// would freeze the UI) and auto-dismisses after 10 min so a stale alert can't pile up. Text is
    /// passed as osascript `argv` positionals (injection-proof — never parsed as AppleScript), no shell.
    private func notify(_ title: String, _ body: String) {
        DispatchQueue.global(qos: .utility).async {
            Proc.run("/usr/bin/osascript", [
                "-e", "on run argv",
                "-e", "display alert (item 1 of argv) message (item 2 of argv) giving up after 600",
                "-e", "end run",
                title, body,
            ])
        }
    }

    /// Fire notifications on release-valve transitions into / out of the "granted" phase.
    private func handleReleaseValve(_ rv: RVStatus?) {
        let phase = rv?.phase ?? "idle"
        defer { lastRVPhase = phase }
        guard !lastRVPhase.isEmpty else { return }        // skip the very first refresh
        if phase == "granted" && lastRVPhase != "granted" {
            let mins = rv?.requestedDurationSec.map { Int($0 / 60) } ?? 0
            notify("Release valve granted", "Admin access unlocked for \(mins) min.")
        } else if phase != "granted" && lastRVPhase == "granted" {
            notify("Release valve closed", "Admin access has been revoked.")
        }
    }

    /// Alert (dialog — breaks Focus/DnD, like the release valve) when a queued delayed change lands.
    /// Keyed on the persisted `lastAppliedEpoch`, so a daemon restart or the agent's faster poll can't
    /// double-fire; the first refresh only seeds the baseline.
    private func handleDelayedApplied(_ items: [(String, DelayedStatus?)]) {
        for (label, d) in items {
            let ep = d?.lastAppliedEpoch ?? 0
            if dpSeeded, ep > (dpApplied[label] ?? 0) {
                notify("Delayed \(label) applied", "Your queued \(label) change is now live.")
            }
            dpApplied[label] = ep
        }
        dpSeeded = true
    }

    /// A queued delayed change's panel section (only shown while one is pending).
    private func delayedText(_ label: String, _ d: DelayedStatus?) -> String {
        guard let d, d.pending else { return "" }
        let left = d.applyAtEpoch.map { max(0, Int($0 - nowEpoch())) } ?? 0
        var out = "\n\nDELAYED \(label.uppercased())\nQUEUED — lands in \(left/3600)h\(left%3600/60)m"
        if let p = d.payloadPreview { out += "\n  \(p)" }
        return out
    }

    /// The RELEASE VALVE section shown in the panel (phase + delay/duration + the window-policy tree).
    private func releaseValveText(_ rv: RVStatus?) -> String {
        guard let rv, rv.configured else { return "" }
        func left(_ e: Double?) -> String {
            e.map { let s = max(0, Int($0 - nowEpoch())); return "\(s/3600)h\(s%3600/60)m\(s%60)s" } ?? "?"
        }
        let line: String
        switch rv.phase {
        case "granted": line = "GRANTED — admin held, \(left(rv.grantExpiresEpoch)) left"
        case "delay":   line = "REQUEST pending — in delay, eligible in \(left(rv.eligibleAtEpoch))"
        case "waiting": line = "REQUEST pending — eligible, waiting for the window"
        default:        line = "idle (no active request)"
        }
        var out = "\n\nRELEASE VALVE\n\(line)"
        if let d = rv.delaySec, let u = rv.maxRequestDurationSec { out += "\n  delay \(Int(d/60))m · max grant \(Int(u/60))m" }
        if let t = rv.windowTree { out += "\n  gate eval:\n" + t.asText(indent: 1) }
        return out
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: build

    private func buildMenubar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🌑"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showWindow)
    }

    private func label(_ font: NSFont, _ frame: NSRect, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(frame: frame)
        l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        l.font = font; l.textColor = color; l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 3
        return l
    }

    private func buildWindow() {
        let size = NSSize(width: 540, height: 480)
        window = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 320)
        window.title = "Demonlock"

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let headH: CGFloat = 96

        header = NSView(frame: NSRect(x: 0, y: size.height - headH, width: size.width, height: headH))
        header.autoresizingMask = [.width, .minYMargin]
        header.wantsLayer = true
        // NOTE: header-LOCAL coords (header is headH tall, origin bottom-left) — not window coords.
        bigLabel = label(.systemFont(ofSize: 25, weight: .bold), NSRect(x: 20, y: 46, width: size.width - 40, height: 38), .white)
        bigLabel.autoresizingMask = [.width]
        reasonLabel = label(.systemFont(ofSize: 13), NSRect(x: 20, y: 12, width: size.width - 40, height: 30), .white)
        reasonLabel.autoresizingMask = [.width]
        header.addSubview(bigLabel); header.addSubview(reasonLabel)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 92, width: size.width - 32, height: size.height - headH - 100))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        treeView = NSTextView(frame: scroll.bounds)
        treeView.isEditable = false
        treeView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        treeView.textContainerInset = NSSize(width: 6, height: 6)
        treeView.isVerticallyResizable = true
        treeView.isHorizontallyResizable = false
        treeView.autoresizingMask = [.width]
        treeView.textContainer?.widthTracksTextView = true
        scroll.documentView = treeView

        healthLabel = label(.systemFont(ofSize: 11), NSRect(x: 18, y: 52, width: size.width - 36, height: 34), .secondaryLabelColor)
        healthLabel.autoresizingMask = [.width, .maxYMargin]

        permButton = NSButton(title: "Fix permissions…", target: self, action: #selector(permTapped))
        permButton.frame = NSRect(x: 18, y: 14, width: 150, height: 28)
        permButton.autoresizingMask = [.maxYMargin]
        permButton.isHidden = true

        disarmButton = NSButton(title: "Disarm (admin)", target: self, action: #selector(disarmTapped))
        disarmButton.frame = NSRect(x: size.width - 170, y: 14, width: 150, height: 28)
        disarmButton.autoresizingMask = [.minXMargin, .maxYMargin]
        disarmButton.bezelStyle = .rounded

        [header, scroll, healthLabel, permButton, disarmButton].forEach { content.addSubview($0) }
        window.contentView = content
    }

    // MARK: refresh

    private func refresh() {
        guard let s = StateStore.read() else {
            statusItem.button?.title = "🌑"
            paint(.darkGray, "ENFORCER OFF", "The root enforcer isn't reporting yet.")
            treeView.string = ""
            healthLabel.stringValue = ""
            window.title = "Demonlock"
            return
        }
        let armedSuffix = s.armed ? "" : "  (DISARMED)"
        window.title = "Demonlock" + armedSuffix

        let remaining = s.countdownDeadlineEpoch.map { max(0, Int(($0 - nowEpoch()).rounded())) }
        var color = NSColor.darkGray
        var big = s.phase.uppercased()
        switch s.phase {
        case "monitoring": color = .systemGreen; big = "● ALLOWED"
        case "countdown":
            color = .systemRed
            if let r = remaining {
                big = s.armed ? "LOCK IN \(r)s" : "WOULD LOCK IN \(r)s (DISARMED)"
                if r == 0 { big = s.armed ? "LOCKING…" : "WOULD LOCK (DISARMED)" }
            }
        case "locked":
            color = .systemRed
            big = s.armed ? "🔒 LOCKED — closing apps" : "WOULD BE LOCKED (DISARMED)"
        case "snoozed": color = .systemGray; big = "SNOOZED"
        case "standby": color = .systemGray; big = "STANDBY"
        default: break
        }
        paint(color, big, s.reason)
        statusItem.button?.title = menuGlyph(s.phase)

        let policy = "POLICY\n" + (s.tree?.asText() ?? "(no policy / no evaluation)")
        let locMap = s.health.locationTrail.isEmpty ? "" : "\n\nLOCATION\n" + s.health.locationTrail.joined(separator: "\n")
        treeView.string = policy + locMap + releaseValveText(s.releaseValve)
            + delayedText("policy", s.delayedPolicy) + delayedText("zones", s.delayedZones)
            + delayedText("gate-policy", s.delayedGatePolicy)
        handleReleaseValve(s.releaseValve)
        handleDelayedApplied([("policy", s.delayedPolicy), ("zones", s.delayedZones), ("gate-policy", s.delayedGatePolicy)])
        let h = s.health
        healthLabel.stringValue = s.sshAddr ?? ""          // SSH-in hint (sshd/tmux survive a lockout → disarm)
        permButton.isHidden = !h.needsPermAsk
        disarmButton.isHidden = !s.armed

        // Pop to front while blocking (countdown or locked).
        let blocking = s.phase == "countdown" || s.phase == "locked"
        let wasBlocking = lastPhase == "countdown" || lastPhase == "locked"
        if blocking, !wasBlocking {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !blocking, wasBlocking {
            window.level = .normal
        }
        lastPhase = s.phase
    }

    private func menuGlyph(_ phase: String) -> String {
        switch phase {
        case "monitoring": return "🟢"
        case "countdown": return "🟠"
        case "locked": return "🔴"
        case "snoozed", "standby": return "⚪️"
        default: return "🌑"
        }
    }

    private func paint(_ color: NSColor, _ big: String, _ reason: String) {
        header.layer?.backgroundColor = color.cgColor
        bigLabel.stringValue = big
        reasonLabel.stringValue = reason
    }

    // MARK: actions

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func disarmTapped() {
        // Escalate via the admin prompt; only succeeds if the user currently holds admin.
        let script = "do shell script \"\(Paths.cliWrapper) disarm\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    @objc private func permTapped() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }
}

/// The status panel can never be truly closed or minimized away — X and minimize just hide it
/// (it reopens from the menubar and pops to front on a countdown). The agent keeps feeding
/// regardless; this is purely cosmetic, since killing the agent entirely only fails the daemon closed.
final class PanelWindow: NSWindow {
    override func performClose(_ sender: Any?) { orderOut(sender) }
    override func performMiniaturize(_ sender: Any?) { orderOut(sender) }
}

func runAgent() {
    let app = NSApplication.shared
    // FOREGROUND (.regular, dock icon) — macOS 26 throttles Wi-Fi scanForNetworks for a background
    // accessory app; a foreground app is far more likely to get live scans. We do NOT activate/steal
    // focus. Killing/quitting it just fails the enforcer closed (feed goes stale), so it stays secure.
    app.setActivationPolicy(.regular)
    let delegate = AgentApp()
    app.delegate = delegate
    app.run()
}
