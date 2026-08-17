import AppKit

// stayup — menu-bar toggle for "stay fully awake, even with the lid closed" (pmset disablesleep, the
// thing caffeinate/Amphetamine can't do). Just a state reader + changer: the icon shows whether it's on
// (re-read from the system every 3s so it follows changes made elsewhere), the menu turns it on/off.
// The setting persists across reboots and across quitting (that's macOS, not us), so the icon is the
// honest reminder — quitting does NOT turn it off.
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
        print("stayup: \(Power.sleepDisabled ? "ON (system sleep disabled)" : "OFF (normal sleep)")")
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

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        // Re-read the system state every 3s so the icon follows changes made elsewhere (a terminal
        // `stayup off`, another tool). That's the only background behavior.
        let t = Timer(timeInterval: 3, repeats: true) { _ in Task { @MainActor in self.refresh() } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
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

        let head = NSMenuItem(title: on ? "Awake with lid closed: ON" : "Awake with lid closed: OFF",
                              action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(
            string: head.title,
            attributes: [.font: NSFont.menuBarFont(ofSize: 0),
                         .foregroundColor: on ? NSColor.systemGreen : NSColor.secondaryLabelColor])
        menu.addItem(head)

        let t = menu.addItem(withTitle: on ? "Turn Off" : "Turn On", action: #selector(toggle), keyEquivalent: "t")
        t.target = self

        if !lastError.isEmpty {
            menu.addItem(.separator())
            menu.addItem(withTitle: "⚠︎ \(lastError)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Persists across reboots until turned off", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit stayup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggle() {
        let (ok, msg) = Power.setSleepDisabled(!Power.sleepDisabled)
        lastError = ok ? "" : msg
        refresh()
    }

    /// Quitting must NOT silently leave the machine unable to sleep — say so.
    func applicationWillTerminate(_ n: Notification) {
        if Power.sleepDisabled {
            NSLog("stayup: quitting while ON — the Mac still won't sleep. `stayup off` to restore.")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
