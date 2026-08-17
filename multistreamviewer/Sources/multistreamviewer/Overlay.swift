import AppKit
import SwiftUI

// Hold ⌘⌥ → a full-screen view of every desktop laid out spatially, each showing its
// windows. Release hides it (peek). It's a NAVIGATOR, not a space switch: nothing on the
// real screen moves — clicking a desktop just makes it current (and raises its window),
// clicking a window raises that window. The menu can also pin it open for mouse work.
@MainActor
final class Overlay: ObservableObject {
    static let shared = Overlay()

    @Published private(set) var groups: [GroupView] = []
    private var panel: NSPanel?
    private var pinned = false
    private var peek: DispatchWorkItem?

    var isOpen: Bool { panel != nil }

    /// ⌘⌥ held: show after a short quiet delay so ⌘⌥+key chords (⌘⌥I, ⌘⌥esc, …) don't
    /// flash it. Re-checks the modifiers are still down when the delay fires.
    func scheduleHeld() {
        guard !isOpen, peek == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.peek = nil
            guard CGEventSource.flagsState(.combinedSessionState)
                .isSuperset(of: [.maskCommand, .maskAlternate]) else { return }
            self?.present(pinned: false)
        }
        peek = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// ⌘⌥ released (or broken): cancel a pending peek, hide a held (non-pinned) overlay.
    /// While a rename is in progress the overlay stays put — otherwise letting go of the
    /// modifiers to type would close the very field you just opened.
    func cancelHeld() {
        peek?.cancel(); peek = nil
        if isOpen, !pinned, renamingID == nil { hide() }
    }

    func toggle() {
        if isOpen { hide() } else { present(pinned: true) }
    }

    func hide() {
        peek?.cancel(); peek = nil
        panel?.orderOut(nil)
        panel = nil
        pinned = false
        renamingID = nil
        Captures.shared.stopIfIdle()
    }

    func refresh() {
        guard isOpen else { return }
        groups = Engine.shared.view()
    }

    // actions from the view
    @Published var renamingID: UUID?

    func jump(to id: UUID) { Engine.shared.jump(to: id); hide() }
    func focus(_ w: Win) { Engine.shared.focusWindow(w.id); hide() }
    func newGroup() { Engine.shared.newGroup(); refresh() }
    func drop(_ wid: CGWindowID, on group: UUID) { Engine.shared.retag(wid, to: group); refresh() }
    func closeWindow(_ w: Win) { Engine.shared.closeWindow(w.id) }
    func killApp(_ w: Win) { Engine.shared.killApp(w.id) }
    func seed(_ id: UUID) { Engine.shared.seed(id) }
    func deleteGroup(_ id: UUID) { Engine.shared.deleteGroup(id); refresh() }
    func beginRename(_ id: UUID) { renamingID = id }

    /// Renaming keeps the overlay alive past the ⌘⌥ release; when it ends, honour that
    /// release (close) unless the keys are still down or the panel was pinned open.
    func endRename() {
        renamingID = nil
        let held = CGEventSource.flagsState(.combinedSessionState)
            .isSuperset(of: [.maskCommand, .maskAlternate])
        if !pinned, !held { hide() } else { refresh() }
    }

    func liveRename(_ id: UUID, _ name: String) {
        Engine.shared.rename(id, to: name)
        refresh()
    }

    private func present(pinned: Bool) {
        self.pinned = pinned
        groups = Engine.shared.view()
        let p = panel ?? Self.makePanel()
        panel = p
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
        Captures.shared.start()
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: OverlayView().environmentObject(Overlay.shared))
        return p
    }
}
