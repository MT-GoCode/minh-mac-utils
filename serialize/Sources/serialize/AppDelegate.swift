import Cocoa
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsStore.shared
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []
    private var aux: AuxWindowController?

    private var taskFieldView: TaskFieldView!
    private var hideItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildStatusItem()
        overlay.refresh()

        // live updates: any setting change rebuilds the overlay (delivered on the main runloop
        // after the new value is set, so geometry recomputes correctly)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.overlay.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - status bar menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                accessibilityDescription: "Serialize")
            btn.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self

        let fieldItem = NSMenuItem()
        taskFieldView = TaskFieldView()
        fieldItem.view = taskFieldView
        menu.addItem(fieldItem)
        menu.addItem(.separator())

        addAction(menu, "Modify Text in Window…", #selector(modifyText), "e")
        addAction(menu, "Settings…", #selector(openSettings), ",")
        menu.addItem(.separator())

        hideItem = NSMenuItem(title: "Hide", action: #selector(toggleHide), keyEquivalent: "h")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())

        addAction(menu, "Quit Serialize", #selector(quit), "q")

        statusItem.menu = menu
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        taskFieldView.sync()
        hideItem.title = overlay.isHidden ? "Show" : "Hide"
        DispatchQueue.main.async { [weak self] in
            guard let v = self?.taskFieldView else { return }
            v.window?.makeFirstResponder(v.field)   // ready to type the moment the menu opens
        }
    }

    // MARK: - actions

    @objc private func modifyText() { present(.editor) }
    @objc private func openSettings() { present(.settings) }
    @objc private func toggleHide() { overlay.setHidden(!overlay.isHidden) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func present(_ kind: AuxWindowController.Kind) {
        if aux == nil { aux = AuxWindowController() }
        aux?.show(kind)
    }
}
