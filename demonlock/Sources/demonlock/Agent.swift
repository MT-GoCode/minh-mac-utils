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

    func applicationDidFinishLaunching(_ note: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "demonlock sensor feed must keep reporting")
        feeder = SensorFeeder(settings: Settings.load())
        feeder.start()
        buildMenubar()
        buildWindow()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
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
                big = s.armed ? "LOG OUT IN \(r)s" : "WOULD LOG OUT IN \(r)s (DISARMED)"
                if r == 0 { big = s.armed ? "LOGGING OUT…" : "WOULD LOG OUT (DISARMED)" }
            }
        case "initializing": color = .systemBlue; big = "INITIALIZING…"
        case "snoozed": color = .systemGray; big = "SNOOZED"
        case "standby": color = .systemGray; big = "STANDBY"
        default: break
        }
        paint(color, big, s.reason)
        statusItem.button?.title = menuGlyph(s.phase)

        treeView.string = s.tree?.asText() ?? "(no policy / no evaluation)"
        let h = s.health
        healthLabel.stringValue = "feed \(h.agentFeedFresh ? "fresh" : "STALE") · location \(h.locState) · wifi \(h.wifiOn ? "on" : "off") · scan \(h.scanFresh ? "fresh" : "stale")"
        permButton.isHidden = !h.needsPermAsk
        disarmButton.isHidden = !s.armed

        // Pop to front when a countdown begins.
        if s.phase == "countdown", lastPhase != "countdown" {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if s.phase != "countdown", lastPhase == "countdown" {
            window.level = .normal
        }
        lastPhase = s.phase
    }

    private func menuGlyph(_ phase: String) -> String {
        switch phase {
        case "monitoring": return "🟢"
        case "countdown": return "🔴"
        case "initializing": return "🔵"
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
    app.setActivationPolicy(.accessory)
    let delegate = AgentApp()
    app.delegate = delegate
    app.run()
}
