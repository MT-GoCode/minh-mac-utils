import AppKit
import SwiftUI

// The ⌘⇥ switcher, AltTab-style but scoped: it only offers windows in the current
// group. Hold ⌘, press ⇥ / ⇧⇥ / arrows to move the selection, release ⌘ to commit, esc
// to cancel. This is the whole point of multistreamviewer — no window is ever moved or hidden; the
// switcher simply filters what you can ⌘⇥ to.
@MainActor
final class Switcher: ObservableObject {
    static let shared = Switcher()

    @Published private(set) var candidates: [Win] = []
    @Published private(set) var index = 0
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    // MARK: open / step / commit / cancel

    func open() {
        // No "already open" guard: a missed release must never wedge it shut.
        Self.karabinerVar(1)
        candidates = Engine.shared.switcherScope()
        guard !candidates.isEmpty else {
            Self.karabinerVar(0)          // nothing to show — don't leave the gate stuck
            candidates = []
            return
        }
        index = candidates.count > 1 ? 1 : 0     // bare ⌘⇥ lands on the previous window
        if panel == nil { panel = Self.makePanel() }
        place()
        panel?.orderFrontRegardless()
        Captures.shared.start()
    }

    func step(_ delta: Int) {
        guard isOpen, !candidates.isEmpty else { return }
        let n = candidates.count
        index = ((index + delta) % n + n) % n
    }

    func arrow(_ dx: Int, _ dy: Int) {
        guard isOpen, !candidates.isEmpty else { return }
        let n = candidates.count
        let cols = Self.columns(n)
        if dx != 0 { step(dx); return }
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let col = index % cols
        var r = index / cols
        for _ in 0..<rows {
            r = ((r + dy) % rows + rows) % rows
            let j = r * cols + col
            if j < n { index = j; return }
        }
    }

    func commit() {
        defer { close() }
        guard candidates.indices.contains(index) else { return }
        pick(candidates[index])
    }

    /// Click/keyboard selection of a specific window.
    func pick(_ w: Win) {
        guard WindowTruth.list().contains(where: { $0.id == w.id }) else { close(); return }
        Raise.raise(pid: w.pid, wid: w.id)
        close()
    }

    /// Close/kill from the HUD without dismissing it — prune the tile, keep switching.
    func closeCandidate(_ w: Win) { Engine.shared.closeWindow(w.id); prune(w.id) }
    func killCandidate(_ w: Win) {
        let pid = w.pid
        Engine.shared.killApp(w.id)
        for c in candidates where c.pid == pid { prune(c.id) }
    }

    private func prune(_ wid: CGWindowID) {
        guard let i = candidates.firstIndex(where: { $0.id == wid }) else { return }
        candidates.remove(at: i)
        if candidates.isEmpty { close() }
        else if index >= i { index = max(0, min(index - (index > i ? 1 : 0), candidates.count - 1)) }
    }

    func cancel() { close() }

    private func close() {
        Self.karabinerVar(0)
        panel?.orderOut(nil)
        panel = nil
        candidates = []
        index = 0
        Captures.shared.stopIfIdle()
    }

    /// Called every engine tick: keep the candidate list in sync with reality while open
    /// (a window closing must remove its tile, not leave a committable ghost), and rescue
    /// a stuck-open switcher if ⌘ was released without us seeing the event.
    func maintainTick() {
        guard isOpen else { return }
        if !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
            commit()                 // release we missed → commit the current selection
            return
        }
        let live = Engine.shared.switcherScope()
        let liveIDs = Set(live.map(\.id))
        let sel = candidates.indices.contains(index) ? candidates[index].id : nil
        candidates = candidates.filter { liveIDs.contains($0.id) }
        if candidates.isEmpty { close(); return }
        index = sel.flatMap { s in candidates.firstIndex { $0.id == s } }
            ?? min(index, candidates.count - 1)
    }

    // MARK: panel

    private func place() {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        // visibleFrame, not frame: frame includes the menu bar and Dock, so centering on
        // it sits the HUD low. Mission Control fills the visible area; match it.
        let area = screen.visibleFrame
        let size = NSSize(width: area.width * 0.88, height: area.height * 0.86)
        panel?.setFrame(
            NSRect(x: area.midX - size.width / 2,
                   y: area.midY - size.height / 2,
                   width: size.width, height: size.height), display: true)
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: SwitcherView().environmentObject(Switcher.shared))
        return p
    }

    static func columns(_ n: Int) -> Int {
        if n <= 1 { return 1 }
        if n <= 4 { return n }
        return Int(Double(n).squareRoot().rounded(.up))
    }

    // MARK: Karabiner gate (only if installed) — pauses cmd+arrow terminal remaps while
    // arrows drive the switcher. No-op when Karabiner isn't present.
    private static let cli =
        "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    static func karabinerVar(_ v: Int) {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["--set-variables", "{\"msv_switcher\": \(v)}"]
        try? p.run()
    }
}
