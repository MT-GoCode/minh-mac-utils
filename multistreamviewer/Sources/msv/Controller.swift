import AppKit
import SwiftUI

// Display snapshot handed to SwiftUI each sync.
struct Workspace: Identifiable, Hashable {
    let id: UUID
    var name: String
    var windows: [Win]
    var isActive: Bool
}

// The virtual-desktop engine. One real macOS desktop; "desktops" are our own
// window groups. Inactive groups are parked 1px off the bottom-right corner via
// Accessibility. Completely independent of native Spaces.
@MainActor
final class Controller: ObservableObject {
    static let shared = Controller()

    private struct WS {
        let id: UUID
        var name: String
        var windowIDs: [CGWindowID]
    }

    private var store: [WS]
    private var activeID: UUID
    private var offscreen: Set<CGWindowID> = []
    private var savedFrames: [CGWindowID: CGRect] = [:]
    private var pids: [CGWindowID: pid_t] = [:]
    private var seedTarget: (id: UUID, until: Date)?
    private var lastFocused: CGWindowID?
    private var mru: [CGWindowID] = []  // most-recently-used order, like Windows alt-tab

    @Published var workspaces: [Workspace] = []
    @Published var fullscreen: [Win] = []  // read-only glance strip
    @Published var editingID: UUID?
    @Published var switcherIndex: Int?     // nil = switcher hidden
    var switcherWindows: [Win] = []
    var draggedID: UUID?
    var dragWindow: CGWindowID?

    private var overlay: NSPanel?
    private var pinned: NSPanel?
    private var switcherPanel: NSPanel?
    var settings: NSWindow?

    // MARK: Lifecycle

    init() {
        // Names/order AND window→desktop assignments persist, keyed by CGWindowID
        // (see WSStore). Stale IDs (post-reboot) are dropped in the first sync().
        let recs = WSStore.records
        store = recs.map {
            WS(id: UUID(uuidString: $0.id) ?? UUID(), name: $0.name,
               windowIDs: ($0.windows ?? []).map(\.id))
        }
        if store.isEmpty { store = [WS(id: UUID(), name: "Desktop 1", windowIDs: [])] }
        // Restore each window's saved home frame so un-parking lands it correctly.
        for r in recs { for wr in r.windows ?? [] { savedFrames[wr.id] = wr.frame } }
        if let saved = WSStore.activeID, let m = store.first(where: { $0.id.uuidString == saved }) {
            activeID = m.id
        } else {
            activeID = store[0].id
        }
    }

    func start() {
        setKarabinerVar(0)  // clear a stuck switcher gate from any previous crash
        sync()
        restoreLayout()     // make physical park state match restored assignments
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in self.sync() }
        }
        // Whatever kills us, put every window back first.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Controller.shared.restoreAll()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    private var activeIdx: Int { store.firstIndex { $0.id == activeID } ?? 0 }
    private func idx(_ id: UUID) -> Int? { store.firstIndex { $0.id == id } }

    // MARK: Sync — discover new windows, drop closed ones, refresh frames

    func sync() {
        let snap = WinList.snapshot()
        let liveByID = Dictionary(uniqueKeysWithValues: snap.normal.map { ($0.id, $0) })
        let liveIDs = Set(snap.normal.map(\.id))

        for i in store.indices { store[i].windowIDs.removeAll { !liveIDs.contains($0) } }
        offscreen.formIntersection(liveIDs)
        savedFrames = savedFrames.filter { liveIDs.contains($0.key) }
        if let s = seedTarget, Date() > s.until { seedTarget = nil }

        let assigned = Set(store.flatMap(\.windowIDs))
        for w in snap.normal where !assigned.contains(w.id) {
            let target = seedTarget.flatMap { idx($0.id) } ?? activeIdx
            store[target].windowIDs.append(w.id)
            pids[w.id] = w.pid
            if store[target].id != activeID {
                savedFrames[w.id] = Park.isParked(w.bounds.origin)
                    ? Self.rescueFrame(w.bounds.size) : w.bounds
                park(w.id)
            } else if Park.isParked(w.bounds.origin) {
                // Apps spawn popups near their remembered frames and restore old
                // positions on relaunch — if that memory is our parking corner,
                // bring the window to the screen center instead of leaving it lost.
                let f = Self.rescueFrame(w.bounds.size)
                AX.setFrame(pid: w.pid, wid: w.id, f)
                savedFrames[w.id] = f
            } else {
                savedFrames[w.id] = w.bounds
            }
        }
        for w in snap.normal {
            pids[w.id] = w.pid
            // Never learn a parked/corner position as a window's "home" frame.
            if !offscreen.contains(w.id), !Park.isParked(w.bounds.origin) {
                savedFrames[w.id] = w.bounds
            }
        }
        if let front = WinList.frontWindowID(), liveIDs.contains(front),
            !offscreen.contains(front) {
            lastFocused = front
            mru = [front] + mru.filter { $0 != front }
        }
        mru.removeAll { !liveIDs.contains($0) }

        workspaces = store.map { ws in
            Workspace(id: ws.id, name: ws.name,
                      windows: order(ws.windowIDs.compactMap { liveByID[$0] }),
                      isActive: ws.id == activeID)
        }
        fullscreen = snap.fullscreen
        persist()   // keep assignments + frames + active desktop on disk each tick
    }

    /// At launch: reconcile the physical window layout with the just-restored
    /// assignments — park windows that belong to inactive desktops, and bring any
    /// active-desktop window that's still in the parking corner (i.e. we'd crashed,
    /// never running restoreAll()) back on-screen. Reads live bounds rather than
    /// `offscreen` (empty at launch) so it's correct whether we last quit cleanly
    /// (windows on-screen) or crashed (windows left parked).
    ///
    /// Self-retries: a target app's Accessibility tree isn't always ready the instant
    /// we launch, so a park move can silently no-op. We only mark a window `offscreen`
    /// once its bounds *confirm* it reached the corner; any still-unparked window is
    /// re-nudged a few times (~0.4s apart). Without this, a window that missed the
    /// one-shot park stayed on-screen AND got mis-tracked as parked (so later switches
    /// wouldn't re-park it).
    private func restoreLayout(attempt: Int = 0) {
        let liveByID = Dictionary(
            uniqueKeysWithValues: WinList.snapshot().normal.map { ($0.id, $0) })
        let activeSet = Set(store[activeIdx].windowIDs)
        var unconfirmed = false
        for wid in store.flatMap(\.windowIDs) {
            guard let pid = pids[wid], let w = liveByID[wid] else { continue }
            if activeSet.contains(wid) {
                if Park.isParked(w.bounds.origin) {   // crash-parked: bring it home
                    var f = savedFrames[wid] ?? Self.rescueFrame(w.bounds.size)
                    if Park.isParked(f.origin) { f = Self.rescueFrame(w.bounds.size) }
                    AX.setFrame(pid: pid, wid: wid, f)
                    savedFrames[wid] = f
                    unconfirmed = true            // verify the un-park landed too
                } else {
                    offscreen.remove(wid)
                }
            } else if Park.isParked(w.bounds.origin) {
                offscreen.insert(wid)             // confirmed parked
            } else {
                AX.setOrigin(pid: pid, wid: wid, Park.point)
                unconfirmed = true                // don't mark offscreen until it lands
            }
        }
        if unconfirmed && attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.restoreLayout(attempt: attempt + 1)
            }
        }
        sync()   // refresh published state after the moves
    }

    private func order(_ wins: [Win]) -> [Win] {
        let priority = (UserDefaults.standard.string(forKey: "appPriority") ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        func rank(_ w: Win) -> Int {
            priority.firstIndex { w.app.lowercased().contains($0) } ?? priority.count
        }
        return wins.sorted { (rank($0), $0.app, $0.id.description) < (rank($1), $1.app, $1.id.description) }
    }

    // MARK: Parking

    private func park(_ wid: CGWindowID) {
        guard !offscreen.contains(wid), let pid = pids[wid] else { return }
        AX.setOrigin(pid: pid, wid: wid, Park.point)
        offscreen.insert(wid)
    }

    private func unpark(_ wid: CGWindowID) {
        guard offscreen.contains(wid), let pid = pids[wid] else { return }
        var f = savedFrames[wid] ?? Self.rescueFrame(CGSize(width: 900, height: 600))
        if Park.isParked(f.origin) {  // corner-polluted saved frame: rescue to center
            f = Self.rescueFrame(f.size)
            savedFrames[wid] = f
        }
        AX.setFrame(pid: pid, wid: wid, f)
        offscreen.remove(wid)
    }

    /// A sane centered on-screen frame for a window we have no good home for.
    private static func rescueFrame(_ size: CGSize) -> CGRect {
        let b = CGDisplayBounds(CGMainDisplayID())
        let w = min(size.width, b.width * 0.85), h = min(size.height, b.height * 0.85)
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    /// Emergency + shutdown path: every window back to its saved frame.
    func restoreAll() {
        for wid in offscreen {
            if let pid = pids[wid], let f = savedFrames[wid] {
                AX.setFrame(pid: pid, wid: wid, f)
            }
        }
        offscreen.removeAll()
    }

    // MARK: Switching

    func activate(_ id: UUID) {
        guard let i = idx(id) else { return }
        activeID = id
        let visible = Set(store[i].windowIDs)
        for wid in store.flatMap(\.windowIDs) {
            visible.contains(wid) ? unpark(wid) : park(wid)
        }
        if let w = store[i].windowIDs.first(where: { $0 == lastFocused })
            ?? store[i].windowIDs.last {
            raise(w)
        }
        sync()
    }

    func activateIndex(_ n: Int) {
        guard store.indices.contains(n) else { return }
        activate(store[n].id)
    }

    func focus(_ w: Win) {
        if let ws = store.first(where: { $0.windowIDs.contains(w.id) }), ws.id != activeID {
            activate(ws.id)
        }
        raise(w.id)
        hideOverlay()
    }

    /// Fullscreen strip click: activate the app; macOS slides to its space.
    func jumpFullscreen(_ w: Win) {
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        hideOverlay()
    }

    private func raise(_ wid: CGWindowID) {
        guard let pid = pids[wid] else { return }
        AX.raise(pid: pid, wid: wid)
        lastFocused = wid
        mru = [wid] + mru.filter { $0 != wid }
        // verify focus actually moved; retry once if the app ignored the handoff
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                AX.raise(pid: pid, wid: wid)
            }
        }
    }

    // MARK: Workspace CRUD

    func newWorkspace() {
        store.append(WS(id: UUID(), name: "Desktop \(store.count + 1)", windowIDs: []))
        persist()
        sync()
    }

    /// Close desktop = close (not kill) every window in it, then remove it.
    func closeWorkspace(_ id: UUID) {
        guard store.count > 1, let i = idx(id) else { return }
        for wid in store[i].windowIDs {
            unpark(wid)  // let the app see its window on-screen before closing
            if let pid = pids[wid] { AX.close(pid: pid, wid: wid) }
        }
        let wasActive = id == activeID
        store.remove(at: i)
        persist()
        if wasActive { activate(store[0].id) } else { sync() }
    }

    func rename(_ id: UUID, _ name: String) {
        guard let i = idx(id), !name.isEmpty else { return }
        store[i].name = name
        persist()
        sync()
    }

    func reorder(dragged: UUID, before target: UUID) {
        guard let from = idx(dragged), idx(target) != nil, dragged != target else { return }
        let item = store.remove(at: from)
        store.insert(item, at: idx(target) ?? store.count)
        persist()
        sync()
    }

    func moveWindow(_ wid: CGWindowID, to wsID: UUID) {
        guard let from = store.firstIndex(where: { $0.windowIDs.contains(wid) }),
            let to = idx(wsID), store[from].id != wsID
        else { return }
        store[from].windowIDs.removeAll { $0 == wid }
        store[to].windowIDs.append(wid)
        store[to].id == activeID ? unpark(wid) : park(wid)
        sync()
    }

    private func persist() {
        WSStore.records = store.map { ws in
            WSRecord(id: ws.id.uuidString, name: ws.name,
                     windows: ws.windowIDs.map { WinRec(id: $0, frame: savedFrames[$0] ?? .zero) })
        }
        WSStore.activeID = activeID.uuidString
    }

    // MARK: Seeding — commands run here; new windows get tagged to the target

    func seedCurrentDesktop(_ commands: [String]? = nil) {
        for cmd in commands ?? Seeds.all.filter(\.on).map(\.cmd) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            try? p.run()
        }
    }

    func seed(_ id: UUID, commands: [String]? = nil) {
        seedTarget = (id, Date().addingTimeInterval(8))
        seedCurrentDesktop(commands)
    }

    func seedMany(_ jobs: [(UUID, [String])]) {
        guard let first = jobs.first else { return }
        seed(first.0, commands: first.1)
        let rest = Array(jobs.dropFirst())
        if !rest.isEmpty {
            // stagger only as long as needed to attribute each batch's new
            // windows to the right desktop (windows appear within ~2s of `open`)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.seedMany(rest) }
        }
    }

    // MARK: Window actions

    func closeWindow(_ w: Win) {
        AX.close(pid: w.pid, wid: w.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.sync() }
    }

    func killApp(_ w: Win) {
        NSRunningApplication(processIdentifier: w.pid)?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.sync() }
    }

    // MARK: cmd+tab switcher (driven by the event tap)

    /// Pause Karabiner terminal remaps (cmd+arrow → ctrl+A/E) while switching;
    /// their rules carry a variable_unless msv_switcher condition.
    private func setKarabinerVar(_ v: Int) {
        let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["--set-variables", "{\"msv_switcher\": \(v)}"]
        try? p.run()
    }

    func switcherOpen() {
        // no "already open" guard: a missed release must never wedge the switcher
        setKarabinerVar(1)
        sync()
        // MRU order, exactly like Windows: current window first, then history.
        let base = workspaces.first { $0.isActive }?.windows ?? []
        let rank = Dictionary(uniqueKeysWithValues: mru.enumerated().map { ($1, $0) })
        switcherWindows = base.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        guard !switcherWindows.isEmpty else { return }
        // bare cmd+tab lands on the previous window (index 1)
        switcherIndex = switcherWindows.count > 1 ? 1 : 0
        Captures.shared.start()
        if switcherPanel == nil { switcherPanel = Self.makePanel(SwitcherView()) }
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: min(900, screen.frame.width * 0.6),
                          height: min(560, screen.frame.height * 0.5))
        switcherPanel!.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: screen.frame.midY - size.height / 2,
                   width: size.width, height: size.height), display: true)
        switcherPanel!.orderFrontRegardless()
    }

    func switcherStep(_ delta: Int) {
        guard let i = switcherIndex, !switcherWindows.isEmpty else { return }
        switcherIndex = ((i + delta) % switcherWindows.count + switcherWindows.count)
            % switcherWindows.count
    }

    /// One linear list under the hood: ←/→ step ±1 wrapping through the whole
    /// list; ↑/↓ move by row wrapping vertically in the same column (Windows-style).
    func switcherArrow(dx: Int, dy: Int) {
        guard let i = switcherIndex else { return }
        let n = switcherWindows.count
        guard n > 0 else { return }
        if dx != 0 {
            switcherIndex = ((i + dx) % n + n) % n
            return
        }
        let (cols, _) = gridDims(n)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let col = i % cols
        var r = i / cols
        for _ in 0..<rows {  // skip rows that don't have this column (short last row)
            r = ((r + dy) % rows + rows) % rows
            let j = r * cols + col
            if j < n {
                switcherIndex = j
                return
            }
        }
    }

    func switcherCommit() {
        if let i = switcherIndex, switcherWindows.indices.contains(i) {
            raise(switcherWindows[i].id)
        }
        switcherClose()
    }

    func switcherCancel() { switcherClose() }

    /// Close/kill from inside the switcher: prune the grid in place, keep it open.
    func switcherCloseWindow(_ w: Win) {
        closeWindow(w)
        switcherPrune(w)
    }

    func switcherKillApp(_ w: Win) {
        killApp(w)
        for gone in switcherWindows.filter({ $0.pid == w.pid }) { switcherPrune(gone) }
    }

    private func switcherPrune(_ w: Win) {
        guard let i = switcherWindows.firstIndex(of: w) else { return }
        switcherWindows.remove(at: i)
        if switcherWindows.isEmpty {
            switcherClose()
        } else if let sel = switcherIndex {
            switcherIndex = min(sel > i ? sel - 1 : sel, switcherWindows.count - 1)
        }
    }

    private func switcherClose() {
        setKarabinerVar(0)
        switcherIndex = nil
        switcherWindows = []
        switcherPanel?.orderOut(nil)
        stopCapturesIfIdle()
    }

    var switcherActive: Bool { switcherIndex != nil }

    // MARK: Command dispatch (CLI / menu)

    func handle(_ name: String) {
        let cmd = name.replacingOccurrences(of: Notify.prefix, with: "")
        switch cmd {
        case "show": showOverlay()
        case "hide": hideOverlay()
        case "toggle": overlay?.isVisible == true ? hideOverlay() : showOverlay()
        case "new": newWorkspace()
        default:
            guard cmd.hasPrefix("switch.") else { return }
            let arg = String(cmd.dropFirst(7))
            if arg == "next" {
                activateIndex((activeIdx + 1) % max(1, store.count))
            } else if let n = Int(arg) {
                activateIndex(n - 1)
            }
        }
    }

    // MARK: Overlay / pinned panels

    func showOverlay() {
        guard overlay?.isVisible != true else { return }
        sync()
        Captures.shared.start()
        if overlay == nil { overlay = Self.makePanel(GridView()) }
        overlay!.setFrame(
            (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens[0]).frame, display: true)
        overlay!.orderFrontRegardless()
    }

    func hideOverlay() {
        overlay?.orderOut(nil)
        editingID = nil
        stopCapturesIfIdle()
    }

    private func stopCapturesIfIdle() {
        if overlay?.isVisible != true, pinned == nil, switcherIndex == nil {
            Captures.shared.stop()
        }
    }

    func pin(to screen: NSScreen?) {
        pinned?.orderOut(nil)
        pinned = nil
        UserDefaults.standard.set(screen?.localizedName, forKey: "pinnedDisplay")
        guard let screen else {
            stopCapturesIfIdle()
            return
        }
        sync()
        Captures.shared.start()
        let w = Self.makePanel(GridView())
        w.level = .floating
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        pinned = w
    }

    private static func makePanel(_ root: some View) -> NSPanel {
        let w = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.backgroundColor = NSColor.black.withAlphaComponent(0.93)
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.contentView = NSHostingView(rootView: root.environmentObject(Controller.shared))
        return w
    }

    // MARK: Settings window

    func openSettings() {
        if settings == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "MultiStreamViewer Settings"
            w.contentView = NSHostingView(rootView: SettingsView(c: self))
            w.isReleasedWhenClosed = false
            w.center()
            // Accessory apps can't win activation; become regular while open, then
            // revert. Window is discarded on close so each open starts fresh.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                    Controller.shared.settings = nil
                }
            }
            settings = w
        }
        NSApp.setActivationPolicy(.regular)
        settings!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSettings() { settings?.close() }
}
