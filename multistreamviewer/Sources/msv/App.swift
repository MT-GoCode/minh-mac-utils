import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        // Invisible Edit menu so cmd+C/V/X/A work in our text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "MultiStreamViewer")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cmds = ["show", "hide", "toggle", "new", "switch.next"]
            + (1...32).map { "switch.\($0)" }
        for cmd in cmds {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let n = name?.rawValue as String? else { return }
                    DispatchQueue.main.async { Controller.shared.handle(n) }
                },
                Notify.prefixed(cmd) as CFString, nil, .deliverImmediately)
        }

        Controller.shared.start()
        Hotkeys.shared.start()
        if let name = UserDefaults.standard.string(forKey: "pinnedDisplay"),
            let screen = NSScreen.screens.first(where: { $0.localizedName == name }) {
            Controller.shared.pin(to: screen)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        Controller.shared.restoreAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Open Display", #selector(toggle))
        add(menu, "New Desktop", #selector(newDesktop))
        add(menu, "Seed Current Desktop", #selector(seedCurrent))
        let pin = NSMenuItem(title: "Pin Display To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let pinnedName = UserDefaults.standard.string(forKey: "pinnedDisplay")
        for screen in NSScreen.screens {
            let i = NSMenuItem(
                title: screen.localizedName, action: #selector(pinTo(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = screen
            i.state = screen.localizedName == pinnedName ? .on : .off
            sub.addItem(i)
        }
        let none = NSMenuItem(title: "Unpin", action: #selector(unpin), keyEquivalent: "")
        none.target = self
        sub.addItem(none)
        pin.submenu = sub
        pin.isEnabled = NSScreen.screens.count > 1 || pinnedName != nil
        menu.addItem(pin)
        add(menu, "Settings…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: sel, keyEquivalent: key).target = self
    }

    @objc private func toggle() { Controller.shared.handle(Notify.prefixed("toggle")) }
    @objc private func newDesktop() { Controller.shared.newWorkspace() }
    @objc private func seedCurrent() { Controller.shared.seedCurrentDesktop() }
    @objc private func openSettings() { Controller.shared.openSettings() }
    @objc private func unpin() { Controller.shared.pin(to: nil) }
    @objc private func pinTo(_ item: NSMenuItem) {
        Controller.shared.pin(to: item.representedObject as? NSScreen)
    }
}
