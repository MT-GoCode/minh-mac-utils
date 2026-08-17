import AppKit

struct Win: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let app: String        // process name — available without any permission
    let title: String      // needs Screen Recording; empty without it (labels degrade, nothing else)
    let bounds: CGRect
    let onscreen: Bool
}

// Window enumeration. Identity is the CGWindowID from the RAW list — a window that is
// minimized, ⌘H-hidden, or on another native Space stays in the raw list with
// onscreen=false: it keeps its group assignment and reappears in the switcher when it
// returns. Titles are cosmetic only; tracking never depends on them.
enum WindowTruth {
    /// Windows you'd ⌘⇥ to — the raw list, minus the app furniture that looks identical to it.
    @MainActor
    static func list() -> [Win] { switchable(raw()) }

    /// Layer-0 windows of regular apps, big enough to be something the user arranged.
    @MainActor
    private static func raw() -> [Win] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var out: [Win] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                           width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.width >= 100, r.height >= 60 else { continue }   // focus proxies, tooltips
            let app = w[kCGWindowOwnerName as String] as? String ?? "?"
            guard !Config.shared.isExcluded(app) else { continue }
            out.append(Win(id: id, pid: pid,
                           app: app,
                           title: w[kCGWindowName as String] as? String ?? "",
                           bounds: r,
                           onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) == true))
        }
        return out
    }

    // MARK: furniture

    // Geometry cannot answer this. Chrome's ⌘F bar is a level-0 403×84 window, its print
    // dialog is 1174×774, its password bubble 320×319 — real windows by every field
    // CGWindowList exposes. macOS only tells the truth through Accessibility, and in just
    // two places: whether the owning app lists the window in kAXWindows at all, and the
    // subrole it reports there. Measured on this machine:
    //
    //   listed, AXStandardWindow → a window (all 11 real ones, across 8 apps)
    //   listed, AXUnknown        → find bar, print dialog, permission bubbles
    //   not listed               → the save and open panels, which are AXSheet *children*
    //                              of their parent window and so appear in no window list
    //
    // AltTab's allow-list also accepts AXDialog, because macOS reports minimized and
    // ⌘H-hidden windows with that subrole. multistreamviewer never needs to: only ONSCREEN windows are
    // ever judged here, and a minimized or hidden window is offscreen by definition. The
    // plain subrole is therefore enough — and it also drops the standalone AXDialog file
    // panels that AltTab's wider list lets through.
    private static let switchableSubrole = kAXStandardWindowSubrole

    // macOS 26 has a third file-panel shape that reports an ordinary AXStandardWindow and
    // gives itself away only by its identifier. Not seen on this machine (Chrome uses the
    // sheet shape), but this Mac runs 26.5 and it costs one attribute in a read we already
    // make — and if it does appear, it is exactly the bug this file exists to fix.
    private static let panelIdentifiers: Set<String> = ["open-panel", "save-panel"]

    // Verdicts, cached per window id. A subrole is fixed at birth, so a KEEP is permanent.
    // A DROP is deliberately *not* cached: the one way this fails badly is a window that
    // CGWindowList reports before its app has registered it with AX — judged once at that
    // instant and remembered, it would stay invisible to ⌘⇥ for its whole life. Re-checking
    // costs one AX sweep of one app per tick, and only while something is actually dropped.
    private static var isWindow: [CGWindowID: Bool] = [:]

    /// Offscreen windows are never judged. They are tagged but never displayed, and they
    /// are precisely the ones AX legitimately omits: another Space, minimized, ⌘H-hidden,
    /// plus the helper windows Electron apps and zoom.us park offscreen. Judging them would
    /// buy nothing and would risk dropping a window that is only resting.
    @MainActor
    private static func switchable(_ wins: [Win]) -> [Win] {
        let live = Set(wins.map(\.id))
        isWindow = isWindow.filter { live.contains($0.key) }
        var unjudgeable: Set<pid_t> = []
        for pid in Set(wins.filter { $0.onscreen && isWindow[$0.id] != true }.map(\.pid))
        where !classify(pid) {
            unjudgeable.insert(pid)
        }
        return wins.filter {
            !$0.onscreen || isWindow[$0.id] == true || unjudgeable.contains($0.pid)
        }
    }

    /// One AX sweep of an app, recording a verdict for every window it admits to having.
    /// Returns false if the app could not be asked at all — a wedged app, or multistreamviewer running
    /// before the Accessibility grant. That must never empty the switcher, so the caller
    /// leaves that app's windows alone rather than dropping them.
    @MainActor
    private static func classify(_ pid: pid_t) -> Bool {
        guard let getWindow = Raise.getWindow else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)     // a wedged app must not stall the tick
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let els = ref as? [AXUIElement] else { return false }
        for el in els {
            var wid: CGWindowID = 0
            guard getWindow(el, &wid) == .success else { continue }
            // && short-circuits, so the identifier costs a round-trip only for the windows
            // that already look real.
            isWindow[wid] = string(el, kAXSubroleAttribute) == switchableSubrole
                && !panelIdentifiers.contains(string(el, kAXIdentifierAttribute) ?? "")
        }
        return true
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v as? String
    }

    /// Frontmost app's first *real* window in the onScreenOnly list (documented
    /// front-to-back). Skipping furniture matters here too: with the find bar open it is
    /// the frontmost window, and calling that "the front window" would point group-follow
    /// and the switcher's scope at something that belongs to no group.
    @MainActor
    static func frontWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        let mine = Set(list().lazy.filter { $0.pid == pid }.map(\.id))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in info
        where (w[kCGWindowLayer as String] as? Int) == 0
            && (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            if let wid = w[kCGWindowNumber as String] as? CGWindowID, mine.contains(wid) {
                return wid
            }
        }
        return nil
    }

    /// `multistreamviewer windows` — every on-screen candidate and whether the switcher takes it. The
    /// check for everything above: open Chrome's ⌘F bar, or a save dialog, and it must
    /// print DROP while the window it belongs to still prints KEEP.
    @MainActor
    static func debugDump() -> String {
        let all = raw()
        let kept = Set(switchable(all).map(\.id))
        return all.filter(\.onscreen).map {
            [kept.contains($0.id) ? "KEEP" : "DROP", "\($0.id)", $0.app,
             "\(Int($0.bounds.width))x\(Int($0.bounds.height))", $0.title]
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
