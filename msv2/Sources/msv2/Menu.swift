import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    static weak var current: AppDelegate?

    override init() {
        super.init()
        AppDelegate.current = self
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // A kill/crash while the switcher was open leaves Karabiner's msv_switcher stuck
        // at 1, so cmd+arrow remaps stay gated off — and a restart never cleared it,
        // because only Switcher.close() ever reset it. Clear it unconditionally on launch.
        Switcher.karabinerVar(0)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.stack", accessibilityDescription: "msv2")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        Engine.shared.onChange = { [weak self] in self?.refreshTitle() }

        // ALWAYS run. Tracking desktops needs no permission at all (the window list is
        // public); only the hotkey tap and raising windows need Accessibility, and
        // thumbnails need Screen Recording. So msv2 is fully usable from the menu and
        // the overview even with nothing granted — and it lights up the moment you do.
        Engine.shared.start()
        Hotkeys.shared.start()
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                Hotkeys.shared.start()          // no-op once alive; retries after a grant
                AppDelegate.current?.refreshTitle()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTitle()
    }

    func applicationWillTerminate(_ n: Notification) { Switcher.karabinerVar(0) }

    private func refreshTitle() {
        let n = Engine.shared.currentIndex + 1
        statusItem.button?.title = Hotkeys.shared.alive ? " \(n)" : " \(n) ⚠"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !Hotkeys.shared.alive {
            menu.addItem(withTitle: "⚠ Hotkeys off — Accessibility not granted",
                         action: nil, keyEquivalent: "")
            add(menu, "Request Permissions…", #selector(requestPermissions))
            add(menu, "Repair: reset msv2's grant & re-ask", #selector(repairPermissions))
            menu.addItem(.separator())
        }
        for g in Engine.shared.view() {
            let i = NSMenuItem(title: "\(g.index + 1)  \(g.name) — \(g.windows.count)",
                               action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = g.id
            i.state = g.isCurrent ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        add(menu, "Show All Desktops  (or hold ⌘⌥)", #selector(showAll), key: "")
        add(menu, "New Desktop", #selector(newGroup), key: "n")
        add(menu, "Seed Current Desktop", #selector(seedCurrent), key: "")
        add(menu, "Gather All Windows Here", #selector(gather), key: "g")
        add(menu, "Settings…", #selector(openSettings), key: ",")
        if Hotkeys.shared.alive, !CGPreflightScreenCaptureAccess() {
            add(menu, "Enable thumbnails (Screen Recording)…", #selector(requestPermissions))
        }
        if !Hotkeys.shared.alive {
            menu.addItem(withTitle: "⚠ Hotkeys inactive — grant Accessibility, relaunch",
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit msv2",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: sel, keyEquivalent: key).target = self
    }

    @objc private func pick(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { Engine.shared.jump(to: id) }
    }
    @objc private func newGroup() { Engine.shared.newGroup() }
    @objc private func gather() { Engine.shared.gatherAll() }
    @objc private func showAll() { Overlay.shared.toggle() }
    @objc private func seedCurrent() { Engine.shared.seed(Engine.shared.currentID) }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func requestPermissions() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// A grant made to an EARLIER build is silently void once the app is re-signed —
    /// TCC keys on bundle id + code signature, so the checkbox can look ON while the
    /// entry no longer matches. Resetting clears the stale row so the prompt returns.
    @objc private func repairPermissions() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", "com.minh.msv2"]
        try? p.run()
        p.waitUntilExit()
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
