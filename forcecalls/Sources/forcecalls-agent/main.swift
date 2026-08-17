import AppKit

/// Forcecalls GUI agent.
///
/// Invisible — no Dock tile, no menu, nothing — until a call is actually live. Then it takes a Dock
/// tile and opens a small window with the running duration and a mute button.
///
/// CLOSING THE WINDOW DOES NOT END THE CALL. The close button and the Dock icon only show and hide
/// the window; the call is held by baresip and the far end, neither of which this process controls.
/// There is deliberately no hang-up button — the escape hatch is the thing forcecalls exists to
/// remove. When the call ends on its own, the window and the Dock tile disappear together.
final class AgentDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow?
    private var durationLabel: NSTextField?
    private var muteButton: NSButton?
    private var timer: Timer?

    private var live = false
    private var callStart: Date?
    private var muted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // start hidden: no Dock tile
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: state

    private func poll() {
        let nowLive = Baresip.callIsLive()
        if nowLive != live {
            live = nowLive
            live ? callDidStart() : callDidEnd()
        }
        if live { refresh() }
    }

    private func callDidStart() {
        callStart = Date()
        muted = false
        NSApp.setActivationPolicy(.regular)            // Dock tile appears
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func callDidEnd() {
        callStart = nil
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)          // Dock tile goes away with the call
    }

    private func refresh() {
        guard let start = callStart else { return }
        let s = Int(Date().timeIntervalSince(start))
        durationLabel?.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        muteButton?.title = muted ? "Unmute" : "Mute"
    }

    // MARK: window

    private func showWindow() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "On a call"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let duration = NSTextField(labelWithString: "0:00")
        duration.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        durationLabel = duration

        let mute = NSButton(title: "Mute", target: self, action: #selector(toggleMute))
        mute.bezelStyle = .rounded
        muteButton = mute

        let note = NSTextField(labelWithString: "Closing this window won't end the call.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        [duration, mute, note].forEach { stack.addArrangedSubview($0) }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    @objc private func toggleMute() {
        Baresip.resetBackoff()          // explicit user action: always worth one more try
        Baresip.command("mute")                        // ctrl_tcp toggles; we mirror the flag locally
        muted.toggle()
        refresh()
    }

    /// Close = hide. The Dock tile stays for the life of the call so you can bring the window back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Clicking the Dock icon reopens the window — only meaningful while a call is live.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if live { showWindow() }
        return true
    }
}

let app = NSApplication.shared
let delegate = AgentDelegate()
app.delegate = delegate
app.run()
