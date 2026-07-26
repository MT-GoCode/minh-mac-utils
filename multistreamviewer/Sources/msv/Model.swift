import AppKit
import ApplicationServices

struct Win: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect
}

// MARK: - Window enumeration

enum WinList {
    /// (normal windows manageable by us, native-fullscreen windows for the read-only strip)
    /// `normal` is front-to-back — index 0 is the frontmost window.
    static func snapshot() -> (normal: [Win], fullscreen: [Win]) {
        let displays = displayBounds()
        let excludes = (UserDefaults.standard.string(forKey: "excludeApps") ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let info =
            CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var normal: [Win] = []
        var fullscreen: [Win] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                let id = w[kCGWindowNumber as String] as? CGWindowID,
                let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let title = w[kCGWindowName as String] as? String, !title.isEmpty
            else { continue }
            let app = w[kCGWindowOwnerName as String] as? String ?? "?"
            if excludes.contains(where: { app.lowercased().contains($0) }) { continue }
            let rect = CGRect(
                x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            let win = Win(id: id, pid: pid, app: app, title: title, bounds: rect)
            // Native-fullscreen windows exactly cover a display (menu bar included).
            if displays.contains(where: { $0.equalTo(rect) }) {
                fullscreen.append(win)
            } else if (w[kCGWindowIsOnscreen as String] as? Bool) == true
                || Park.isParked(rect.origin) {
                // only real, visible windows — no hidden/minimized/ghost windows.
                // (our own parked windows count as visible even if macOS disagrees)
                normal.append(win)
            }
        }
        return (normal, fullscreen)
    }

    /// The focused window: frontmost app's first window in the onScreenOnly
    /// list (which IS documented front-to-back; optionAll's order is not).
    static func frontWindowID() -> CGWindowID? {
        guard let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid == frontPid,
                let id = w[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return id
        }
        return nil
    }

    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }
}

// MARK: - Off-screen parking

enum Park {
    /// Bottom-right of the whole display arrangement; parked windows keep 1px visible.
    static var point: CGPoint {
        let union = WinList.displayBounds().reduce(CGRect.null) { $0.union($1) }
        let u = union.isNull ? CGRect(x: 0, y: 0, width: 1440, height: 900) : union
        return CGPoint(x: u.maxX - 1, y: u.maxY - 1)
    }

    /// Is this window currently sitting at (or near) the parking spot?
    static func isParked(_ origin: CGPoint) -> Bool {
        let p = point
        return abs(origin.x - p.x) < 60 && abs(origin.y - p.y) < 60
    }
}

// MARK: - Accessibility primitives (the only way we touch other apps' windows)

enum AX {
    private static let getWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError) = {
        unsafeBitCast(
            dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow")!,
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    // Cross-app focus trio (AltTab/yabai/Hammerspoon technique). Public APIs
    // stopped moving key focus across apps in macOS 14 — activate() is advisory.
    private static let sky = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFrontProcess = unsafeBitCast(
        dlsym(sky, "_SLPSSetFrontProcessWithOptions")!,
        to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
    private static let postEventRecord = unsafeBitCast(
        dlsym(sky, "SLPSPostEventRecordTo")!,
        to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError).self)
    private static let processForPID = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_LAZY), "GetProcessForPID")!,
        to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)

    /// Synthetic left-click (down+up) event record aimed 1px outside the window:
    /// makes it the app's key window without clicking any content.
    private static func makeKey(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        var wid = wid
        var point = CGPoint(x: -1, y: -1)
        var bytes = [UInt8](repeating: 0, count: 0x100)  // record is 0xf8; extra zeroed slack
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        withUnsafeBytes(of: &point) { for (i, b) in $0.enumerated() { bytes[0x20 + i] = b } }
        bytes[0x08] = 0x01  // left mouse down
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02  // left mouse up
        _ = postEventRecord(&psn, &bytes)
    }

    static func element(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
            let els = ref as? [AXUIElement]
        else { return nil }
        for el in els {
            var got: CGWindowID = 0
            if getWindow(el, &got) == .success, got == wid { return el }
        }
        return nil
    }

    static func setFrame(pid: pid_t, wid: CGWindowID, _ frame: CGRect) {
        guard let el = element(pid: pid, wid: wid) else { return }
        var origin = frame.origin
        var size = frame.size
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
    }

    static func setOrigin(pid: pid_t, wid: CGWindowID, _ origin: CGPoint) {
        guard let el = element(pid: pid, wid: wid) else { return }
        var p = origin
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    static func raise(pid: pid_t, wid: CGWindowID) {
        var psn = ProcessSerialNumber()
        _ = processForPID(pid, &psn)
        _ = setFrontProcess(&psn, wid, 0x200)  // userGenerated: front process + this window
        makeKey(&psn, wid)                      // key focus follows (keystrokes go here)
        if let el = element(pid: pid, wid: wid) {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        }
    }

    static func close(pid: pid_t, wid: CGWindowID) {
        guard let el = element(pid: pid, wid: wid) else { return }
        var btn: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &btn)
        if let btn { AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) }
    }
}

// MARK: - Seed commands (persisted checklist)

struct SeedCmd: Codable, Identifiable, Equatable {
    var id = UUID()
    var cmd: String
    var on: Bool
}

enum Seeds {
    static let defaults = [
        SeedCmd(cmd: "open -na \"Google Chrome\" --args --new-window", on: true),
        SeedCmd(cmd: "open -a Terminal ~", on: true),
        SeedCmd(cmd: "open -a Terminal ~", on: true),
    ]
    static var all: [SeedCmd] {
        get {
            UserDefaults.standard.data(forKey: "seedCmds")
                .flatMap { try? JSONDecoder().decode([SeedCmd].self, from: $0) } ?? defaults
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "seedCmds") }
    }
}

// MARK: - Workspace persistence (name/order + window→desktop assignments)
//
// Window identity across our own quit/relaunch is the CGWindowID: it's assigned
// by the WindowServer, not us, so it stays valid while the target window lives —
// independent of MSV restarting. That makes it a far more innate key than title.
// Its one limit: CGWindowIDs are unique only within a login session, so after a
// logout/reboot (or if a window was closed+reopened while we were down) the saved
// IDs match nothing and those windows fall back to Desktop 1 — same as before.
// `frame` is the window's saved on-screen home, so a parked window can be
// un-parked to where it belonged rather than dumped in the screen center.

struct WinRec: Codable {
    var id: CGWindowID
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    init(id: CGWindowID, frame: CGRect) {
        self.id = id
        x = Double(frame.origin.x); y = Double(frame.origin.y)
        w = Double(frame.width); h = Double(frame.height)
    }
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct WSRecord: Codable {
    var id: String
    var name: String
    var windows: [WinRec]?   // optional → old {id,name} payloads still decode
}

enum WSStore {
    static var records: [WSRecord] {
        get {
            UserDefaults.standard.data(forKey: "workspaces")
                .flatMap { try? JSONDecoder().decode([WSRecord].self, from: $0) }
                ?? [WSRecord(id: UUID().uuidString, name: "Desktop 1", windows: [])]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "workspaces") }
    }

    /// Which desktop was active at last persist, so we reopen showing the same one.
    static var activeID: String? {
        get { UserDefaults.standard.string(forKey: "activeWorkspace") }
        set { UserDefaults.standard.set(newValue, forKey: "activeWorkspace") }
    }
}

// MARK: - Grid layout: grow columns first, then rows (1→1×1, 2→hotdog, 3-4→2×2, 5-6→3×2)

func gridDims(_ n: Int) -> (cols: Int, rows: Int) {
    if n <= 1 { return (1, 1) }
    if n == 2 { return (1, 2) }
    let rows = Int(Double(n).squareRoot().rounded())
    return (Int((Double(n) / Double(rows)).rounded(.up)), rows)
}
