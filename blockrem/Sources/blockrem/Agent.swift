import AppKit
import ApplicationServices
import CoreGraphics

/// A borderless opaque window at the screen-saver shield level — above the menu bar, Dock, and
/// other apps' full-screen spaces. Can't be closed or miniaturized; re-asserted every tick.
final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func performClose(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}
}

/// The GUI blocker agent. Renders ONLY from the daemon's active.json: while a block is active it
/// shows a grey opaque cover (one per display, constantly re-maximized) with the label + a live
/// countdown, and arms a CGEvent tap that swallows keyboard/mouse so the machine is unusable. When
/// the block ends (or active.json can't be read) it lifts everything — a blocker must never trap you.
final class AgentApp: NSObject, NSApplicationDelegate {
    private var shields: [ShieldWindow] = []
    private var titleLabels: [NSTextField] = []
    private var timeLabels: [NSTextField] = []
    private var activity: NSObjectProtocol?
    private var blocking = false

    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ note: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "blockrem must render scheduled blocks")
        promptAccessibilityIfNeeded()
        setupEventTap()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuildShields()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // Deny the polite quit (Cmd-Q / Quit menu) while a block is up. launchd bootout still uses
    // SIGKILL (uncatchable) so uninstall/recovery is unaffected — this only stops a casual quit.
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        blocking ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: shields

    @objc private func screensChanged() { rebuildShields() }

    private func rebuildShields() {
        shields.forEach { $0.orderOut(nil) }
        shields.removeAll(); titleLabels.removeAll(); timeLabels.removeAll()
        for screen in NSScreen.screens {
            let w = ShieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.backgroundColor = NSColor(white: 0.11, alpha: 1.0)
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let title = Self.label(size: 46, weight: .semibold)
            let time = Self.label(size: 130, weight: .bold, mono: true)
            content.addSubview(title); content.addSubview(time)
            w.contentView = content
            shields.append(w); titleLabels.append(title); timeLabels.append(time)
        }
        if blocking { layoutAndShow() }
    }

    private static func label(size: CGFloat, weight: NSFont.Weight, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor(white: 0.85, alpha: 1.0)
        l.alignment = .center
        l.isBezeled = false; l.drawsBackground = false; l.isEditable = false
        return l
    }

    // MARK: tick — render from active.json

    private func tick() {
        let st = ActiveStore.read()
        let now = nowEpoch()
        let isActive = (st?.active ?? false) && (st?.endsEpoch ?? 0) > now   // missing/garbage ⇒ fail open

        if isActive, let st {
            blocking = true
            if shields.count != NSScreen.screens.count { rebuildShields() }
            let remaining = max(0, Int((st.endsEpoch - now).rounded(.up)))
            for i in titleLabels.indices {
                titleLabels[i].stringValue = st.label.isEmpty ? "Break" : st.label
                timeLabels[i].stringValue = Self.clock(remaining)
            }
            layoutAndShow()
            enableTap(true)
        } else if blocking {
            blocking = false
            enableTap(false)
            shields.forEach { $0.orderOut(nil) }
        }
    }

    /// Re-assert frame, label positions, and z-order on every active tick (the "constantly-maximizing"
    /// behavior — anything that tries to climb on top is shoved back under within 0.25s).
    private func layoutAndShow() {
        for (i, w) in shields.enumerated() {
            guard i < NSScreen.screens.count else { continue }
            let frame = NSScreen.screens[i].frame
            w.setFrame(frame, display: true)
            w.contentView?.frame = NSRect(origin: .zero, size: frame.size)
            let cx = frame.size.width, cy = frame.size.height
            titleLabels[i].frame = NSRect(x: 0, y: cy / 2 + 20, width: cx, height: 70)
            timeLabels[i].frame = NSRect(x: 0, y: cy / 2 - 130, width: cx, height: 150)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func clock(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: event tap (input capture)

    private func promptAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            NSLog("blockrem: needs Accessibility to block input — grant it in System Settings ▸ Privacy & Security ▸ Accessibility")
        }
    }

    private func setupEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // The OS disables a tap that's slow or on user input toggles — re-enable and pass through.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let rc = refcon {
                    let me = Unmanaged<AgentApp>.fromOpaque(rc).takeUnretainedValue()
                    if let tap = me.eventTap, me.blocking { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                return Unmanaged.passUnretained(event)
            }
            return nil   // swallow — the tap is only ENABLED while a block is active
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: refcon) else {
            NSLog("blockrem: event tap unavailable (grant Accessibility) — falling back to visual-only cover")
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)   // created idle; enabled only during a block
    }

    private func enableTap(_ on: Bool) {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: on)
    }
}

func runAgent() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no Dock icon; a menubar/background agent that shields on demand
    let delegate = AgentApp()
    app.delegate = delegate
    app.run()
}
