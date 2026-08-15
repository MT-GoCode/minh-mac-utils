import AppKit

struct Group: Identifiable, Hashable {
    let id: UUID
    var name: String
}

/// Read-only snapshot for UI.
struct GroupView: Identifiable {
    let id: UUID
    let name: String
    let index: Int
    let isCurrent: Bool
    let windows: [Win]
}

// msv2 never moves a window. A "desktop" is a GROUP — a filter over ⌘⇥: the switcher
// only offers windows in the same group as the one you're on. The engine stores groups,
// window→group, and the current group; everything else is derived from the live window
// list each tick. Nothing here can strand, shift, or mangle a window — the worst
// possible failure is a wrong tag, fixed by retagging.
@MainActor
final class Engine {
    static let shared = Engine()

    private(set) var groups: [Group] = []
    private(set) var currentID = UUID()
    private var assign: [CGWindowID: UUID] = [:]
    private var missing: [CGWindowID: Int] = [:]   // consecutive ticks absent from raw list
    private var mru: [UUID: [CGWindowID]] = [:]
    private var lastRawCount = 0
    private var graceUntil = Date.distantPast      // no prune/adopt/persist inside grace
    private var lastSaved = Data()
    private var signals: [DispatchSourceSignal] = []
    private var seedTarget: (id: UUID, until: Date)?   // new windows adopt here while live

    var onChange: (() -> Void)?                    // menu-bar refresh hook

    var currentIndex: Int { groups.firstIndex { $0.id == currentID } ?? 0 }

    // MARK: lifecycle

    func start() {
        load()
        Switcher.karabinerVar(0)                   // clear a stuck gate from any crash
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in Engine.shared.tick() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Engine.shared.graceUntil = Date().addingTimeInterval(3) }
        }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler {
                Switcher.karabinerVar(0)
                exit(0)
            }
            s.resume()
            signals.append(s)
        }
        tick()
    }

    // MARK: ops

    /// Jump to a group: raise its most recent window (which also makes it current via
    /// the focus-follow in tick). An empty group just becomes the adoption target.
    func jump(to id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        currentID = id
        let wins = windowsOf(id)
        var pick: Win?
        for m in mru[id] ?? [] {
            if let w = wins.first(where: { $0.id == m }) {
                pick = w
                break
            }
        }
        if let w = pick ?? wins.first {
            Raise.raise(pid: w.pid, wid: w.id)
        }
        persistIfChanged()
        onChange?()
    }

    func jumpToIndex(_ n: Int) {
        guard groups.indices.contains(n) else { return }
        jump(to: groups[n].id)
    }

    func jumpNext() { jumpToIndex((currentIndex + 1) % max(1, groups.count)) }

    func newGroup() {
        let g = Group(id: UUID(), name: "Desktop \(groups.count + 1)")
        groups.append(g)
        currentID = g.id                           // new windows now land here
        persistIfChanged()
        onChange?()
    }

    /// Live-renaming: called on every keystroke, so it must be cheap and tolerant. An
    /// all-whitespace draft is ignored (the old name stands) rather than rejected, so
    /// clearing the field and retyping works.
    func rename(_ id: UUID, to name: String) {
        let clean = String(name.prefix(kMaxDesktopName))
        guard let i = groups.firstIndex(where: { $0.id == id }),
              !clean.trimmingCharacters(in: .whitespaces).isEmpty,
              groups[i].name != clean else { return }
        groups[i].name = clean
        persistIfChanged()
        onChange?()
    }

    func sendFocused(toIndex n: Int) {
        guard groups.indices.contains(n), let f = WindowTruth.frontWindowID() else { return }
        assign[f] = groups[n].id
        persistIfChanged()
        onChange?()
    }

    func retag(_ wid: CGWindowID, to id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        assign[wid] = id
        persistIfChanged()
    }

    /// Overlay/switcher clicked a window: raise it and make its group current.
    func focusWindow(_ wid: CGWindowID) {
        guard let w = WindowTruth.list().first(where: { $0.id == wid }) else { return }
        if let g = assign[wid] { currentID = g }
        Raise.raise(pid: w.pid, wid: w.id)
        onChange?()
    }

    func closeWindow(_ wid: CGWindowID) {
        guard let w = WindowTruth.list().first(where: { $0.id == wid }) else { return }
        Raise.close(pid: w.pid, wid: w.id)
    }

    func killApp(_ wid: CGWindowID) {
        guard let w = WindowTruth.list().first(where: { $0.id == wid }) else { return }
        Raise.quit(pid: w.pid)
    }

    /// Everything into the current group — the "un-lose my tags" lever.
    func gatherAll() {
        for wid in assign.keys { assign[wid] = currentID }
        persistIfChanged()
        onChange?()
    }

    /// Delete a desktop AND gracefully close every window in it (dirty documents get
    /// their save dialog and survive into the current desktop).
    func deleteGroup(_ id: UUID) {
        guard groups.count > 1, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        for w in WindowTruth.list() where assign[w.id] == id && w.onscreen {
            Raise.close(pid: w.pid, wid: w.id)
        }
        groups.remove(at: i)
        if currentID == id { currentID = groups[0].id }
        for (wid, g) in assign where g == id { assign[wid] = currentID }
        persistIfChanged()
        onChange?()
    }

    /// Reorder desktops (overview drag of a card header onto another card).
    func reorder(_ dragged: UUID, before target: UUID) {
        guard dragged != target,
              let from = groups.firstIndex(where: { $0.id == dragged }) else { return }
        let item = groups.remove(at: from)
        let to = groups.firstIndex(where: { $0.id == target }) ?? groups.count
        groups.insert(item, at: to)
        persistIfChanged()
        onChange?()
    }

    /// Run the enabled seed commands; windows that appear in the next 8s are tagged to
    /// `id`. Time-window attribution because `open`-launched apps aren't our children —
    /// so avoid opening unrelated windows during those seconds.
    func seed(_ id: UUID, commands: [String]? = nil) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let cmds = commands ?? Config.shared.data.seeds.filter(\.on).map(\.cmd)
        for cmd in cmds where !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            try? p.run()
        }
        seedTarget = (id, Date().addingTimeInterval(8))
    }

    /// Seed several desktops in one go, staggered just enough that each batch's windows
    /// are attributed to the right desktop before the next batch starts.
    func seedMany(_ jobs: [(UUID, [String])]) {
        guard let first = jobs.first else { return }
        seed(first.0, commands: first.1)
        let rest = Array(jobs.dropFirst())
        guard !rest.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.seedMany(rest)
        }
    }

    /// Overview + menu counts. On-screen only — same rule the switcher uses — so the two
    /// never disagree. Off-screen windows (minimized, hidden, other Space, and the extra
    /// layer-0 helper windows Electron apps like Claude keep around) stay assigned but
    /// aren't shown; they reappear when they come back on screen. Windows sort by the
    /// settings priority list, then app, then id.
    func view() -> [GroupView] {
        let wins = WindowTruth.list()
        return groups.enumerated().map { i, g in
            let mine = wins.filter { assign[$0.id] == g.id && $0.onscreen }
                .sorted {
                    (Config.shared.priorityRank($0.app), $0.app, $0.id)
                        < (Config.shared.priorityRank($1.app), $1.app, $1.id)
                }
            return GroupView(id: g.id, name: g.name, index: i, isCurrent: g.id == currentID,
                             windows: mine)
        }
    }

    /// The switcher's candidate list: windows sharing the focused window's group
    /// (falling back to the current group), on-screen only, MRU order with the actual
    /// front window forced to the head — so index 1 is always "the previous window",
    /// never a half-second-stale guess.
    func switcherScope() -> [Win] {
        let raw = WindowTruth.list()
        let front = WindowTruth.frontWindowID()
        let scope = front.flatMap { assign[$0] } ?? currentID
        let wins = raw.filter { assign[$0.id] == scope && $0.onscreen }
        var order = mru[scope] ?? []
        if let f = front, assign[f] == scope {
            order = [f] + order.filter { $0 != f }
        }
        var rank: [CGWindowID: Int] = [:]
        for (i, wid) in order.enumerated() { rank[wid] = i }
        return wins.sorted { (rank[$0.id] ?? .max, $0.id) < (rank[$1.id] ?? .max, $1.id) }
    }

    // MARK: tick — bookkeeping only; no window is ever moved

    func tick() {
        let now = Date()
        let raw = WindowTruth.list()
        // A mass disappearance is a degraded snapshot (permission flap, mid-reconfig),
        // not the user closing everything. Don't act on it.
        if lastRawCount >= 5, raw.count * 5 < lastRawCount * 2 {
            NSLog("msv2: window list collapsed (%d → %d), skipping tick",
                  lastRawCount, raw.count)
            return
        }
        lastRawCount = raw.count
        let live = Set(raw.map(\.id))
        let inGrace = now < graceUntil

        for wid in assign.keys where !live.contains(wid) { missing[wid, default: 0] += 1 }
        missing = missing.filter { !live.contains($0.key) }
        if let s = seedTarget, now > s.until || !groups.contains(where: { $0.id == s.id }) {
            seedTarget = nil
        }
        if !inGrace {
            for (wid, count) in missing where count >= 2 {
                assign.removeValue(forKey: wid)
                missing.removeValue(forKey: wid)
                mru = mru.mapValues { $0.filter { $0 != wid } }
            }
            let adopt = seedTarget?.id ?? currentID   // seeding redirects adoption
            for w in raw where assign[w.id] == nil {
                assign[w.id] = adopt
            }
        }

        // Focus-follow: landing on a window of another group (native ⌘⇥ still works,
        // Dock clicks, notification clicks) makes that group current.
        if let f = WindowTruth.frontWindowID(), let g = assign[f] {
            currentID = g
            mru[g] = [f] + (mru[g] ?? []).filter { $0 != f }
        }

        Switcher.shared.maintainTick()
        Overlay.shared.refresh()
        SettingsWindow.shared.refresh()
        if !inGrace { persistIfChanged() }
        onChange?()
    }

    private func windowsOf(_ id: UUID) -> [Win] {
        WindowTruth.list().filter { assign[$0.id] == id && $0.onscreen }
    }

    // MARK: persistence — atomic, session-fingerprinted, backed up

    private struct Saved: Codable {
        var boot: Int
        var groups: [SavedGroup]
        var current: String
        var assign: [String: String]
        struct SavedGroup: Codable {
            var id: String
            var name: String
        }
    }

    private static var stateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("msv2")
    }
    private static var stateFile: URL { stateDir.appendingPathComponent("state.json") }

    private static func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Int(tv.tv_sec)
    }

    private func load() {
        let decode = { (url: URL) -> Saved? in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }
        let saved = decode(Self.stateFile)
            ?? decode(Self.stateFile.appendingPathExtension("bak"))
        if let s = saved {
            groups = s.groups.map { Group(id: UUID(uuidString: $0.id) ?? UUID(), name: $0.name) }
            if groups.isEmpty { groups = [Group(id: UUID(), name: "Desktop 1")] }
            currentID = groups.first { $0.id.uuidString == s.current }?.id ?? groups[0].id
            // CGWindowIDs are only meaningful within one boot session; stale ones could
            // collide with fresh windows and kidnap them into old groups.
            if s.boot == Self.bootTime() {
                for (k, v) in s.assign {
                    if let wid = CGWindowID(k), let g = UUID(uuidString: v),
                       groups.contains(where: { $0.id == g }) {
                        assign[wid] = g
                    }
                }
            }
        } else {
            groups = [Group(id: UUID(), name: "Desktop 1")]
            currentID = groups[0].id
        }
    }

    private func persistIfChanged() {
        let s = Saved(
            boot: Self.bootTime(),
            groups: groups.map { .init(id: $0.id.uuidString, name: $0.name) },
            current: currentID.uuidString,
            assign: Dictionary(uniqueKeysWithValues: assign.map { ("\($0.key)", $0.value.uuidString) }))
        guard let data = try? JSONEncoder().encode(s), data != lastSaved else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.stateDir, withIntermediateDirectories: true)
        let bak = Self.stateFile.appendingPathExtension("bak")
        if fm.fileExists(atPath: Self.stateFile.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: Self.stateFile, to: bak)   // last-good survives a bad write
        }
        try? data.write(to: Self.stateFile, options: .atomic)
        lastSaved = data
    }
}
