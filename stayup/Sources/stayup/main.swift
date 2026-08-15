import AppKit

// stayup — menu-bar control for "stay fully awake, even with the lid closed"
// (pmset disablesleep, the thing caffeinate/Amphetamine can't do).
//
// Predictable by construction:
//  • The menu ALWAYS shows the system's real state, re-read every 3s — never a cached
//    belief. Toggle it from a terminal or another tool and the menu follows.
//  • The setting persists across reboots (that's macOS, not us), so the menu bar icon is
//    the honest reminder that it's still on. No timers, no "for 2 hours", no silent expiry.
//  • Optional guard: turn OFF automatically when you unplug from AC — the one case where
//    "awake with the lid shut" cooks the machine in a bag.
//
// CLI: stayup on|off|status  (same binary; run with no args for the menu bar app)

let args = CommandLine.arguments.dropFirst()
if let cmd = args.first {
    switch cmd {
    case "on", "off":
        let (ok, msg) = Power.setSleepDisabled(cmd == "on")
        if ok {
            print("stayup: \(cmd.uppercased())"
                + (cmd == "on" ? " — no sleep, even with the lid closed (persists until 'stayup off')" : " — normal sleep restored"))
        } else {
            FileHandle.standardError.write("stayup: \(msg)\n".data(using: .utf8)!)
            exit(1)
        }
    case "status":
        let b = Power.battery
        print("stayup: \(Power.sleepDisabled ? "ON (system sleep disabled)" : "OFF (normal sleep)")"
            + " · \(b.onAC ? "AC power" : "battery")\(b.percent.map { " \($0)%" } ?? "")")
    default:
        FileHandle.standardError.write("usage: stayup [on|off|status]\n".data(using: .utf8)!)
        exit(2)
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var lastError = ""
    /// Auto-off when AC is unplugged. Default ON: the failure mode it prevents (laptop
    /// awake in a closed bag on battery) is the only genuinely dangerous one here.
    private var guardOnBattery: Bool {
        get { UserDefaults.standard.object(forKey: "guardOnBattery") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "guardOnBattery") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        let t = Timer(timeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        // The guard is the only thing that acts on its own, and only ever to TIGHTEN.
        if guardOnBattery, Power.sleepDisabled, !Power.battery.onAC {
            let (ok, msg) = Power.setSleepDisabled(false)
            lastError = ok ? "" : msg
            if ok { notify("stayup turned OFF — you're on battery") }
        }
        refresh()
    }

    private func refresh() {
        let on = Power.sleepDisabled
        item.button?.image = NSImage(
            systemSymbolName: on ? "bolt.fill" : "bolt.slash",
            accessibilityDescription: on ? "stayup on" : "stayup off")
        item.button?.toolTip = on ? "Awake with lid closed — ON" : "Normal sleep"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = Power.sleepDisabled
        let b = Power.battery

        let head = NSMenuItem(
            title: on ? "Awake with lid closed: ON" : "Awake with lid closed: OFF",
            action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(
            string: head.title,
            attributes: [.font: NSFont.menuBarFont(ofSize: 0),
                         .foregroundColor: on ? NSColor.systemGreen : NSColor.secondaryLabelColor])
        menu.addItem(head)

        add(menu, on ? "Turn Off" : "Turn On", #selector(toggle), key: "t")
        menu.addItem(.separator())

        let power = b.onAC ? "AC power" : "Battery"
        menu.addItem(withTitle: "\(power)\(b.percent.map { " · \($0)%" } ?? "")",
                     action: nil, keyEquivalent: "")
        if on, !b.onAC, !guardOnBattery {
            menu.addItem(withTitle: "⚠︎ awake on battery — don't bag it",
                         action: nil, keyEquivalent: "")
        }
        let g = NSMenuItem(title: "Auto-off when unplugged",
                           action: #selector(toggleGuard), keyEquivalent: "")
        g.target = self
        g.state = guardOnBattery ? .on : .off
        menu.addItem(g)

        if !lastError.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "⚠︎ \(lastError)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Persists across reboots until turned off",
                     action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit stayup",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        m.addItem(withTitle: title, action: sel, keyEquivalent: key).target = self
    }

    @objc private func toggle() {
        let (ok, msg) = Power.setSleepDisabled(!Power.sleepDisabled)
        lastError = ok ? "" : msg
        refresh()
    }

    @objc private func toggleGuard() {
        guardOnBattery.toggle()
        tick()
    }

    /// Quitting must NOT silently leave the machine unable to sleep — say so.
    func applicationWillTerminate(_ n: Notification) {
        if Power.sleepDisabled {
            NSLog("stayup: quitting while ON — the Mac still won't sleep. `stayup off` to restore.")
        }
    }

    private func notify(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = "Sleep behavior is back to normal."
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
