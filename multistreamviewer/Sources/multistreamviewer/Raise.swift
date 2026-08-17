import AppKit

// Cross-app focus. Public activate() stopped moving key focus across apps in macOS 14,
// so this uses the SkyLight trio (AltTab/yabai technique). Every private symbol is
// guard-let'd: if one vanishes in an OS update, raising degrades to the public path
// instead of crashing. A generation counter kills the stale-retry race: a retry from
// switch N never fires after the user has already switched to N+1.
@MainActor
enum Raise {
    private static func sym<T>(_ h: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
        dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
    }
    private static let own = dlopen(nil, RTLD_LAZY)
    private static let sky = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static let getWindow = sym(own, "_AXUIElementGetWindow",      // WindowTruth needs it too
        (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    private static let setFront = sym(sky, "_SLPSSetFrontProcessWithOptions",
        (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
    private static let postEvent = sym(sky, "SLPSPostEventRecordTo",
        (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError).self)
    private static let psnForPID = sym(own, "GetProcessForPID",
        (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)

    private static var generation = 0

    static func element(pid: pid_t, wid: CGWindowID) -> AXUIElement? {
        guard let getWindow else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let els = ref as? [AXUIElement] else { return nil }
        for el in els {
            var got: CGWindowID = 0
            if getWindow(el, &got) == .success, got == wid { return el }
        }
        return nil
    }

    /// Press a window's close button (a graceful close — dirty documents still prompt).
    static func close(pid: pid_t, wid: CGWindowID) {
        guard let el = element(pid: pid, wid: wid) else { return }
        var btn: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &btn)
        if let btn { AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) }
    }

    static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    static func raise(pid: pid_t, wid: CGWindowID) {
        generation += 1
        let g = generation
        if let setFront, let postEvent, let psnForPID {
            var psn = ProcessSerialNumber()
            _ = psnForPID(pid, &psn)
            _ = setFront(&psn, wid, 0x200)   // userGenerated: front process + this window
            makeKey(&psn, wid, postEvent)
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        if let el = element(pid: pid, wid: wid) {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        }
        // Verify focus actually moved; retry once — unless a newer raise superseded us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard g == generation,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
            else { return }
            if let el = element(pid: pid, wid: wid) {
                AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Synthetic left-click (down+up) aimed 1px outside the window: makes it the app's
    /// key window without touching any content.
    private static func makeKey(
        _ psn: inout ProcessSerialNumber, _ wid: CGWindowID,
        _ post: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)
    ) {
        var w = wid
        var pt = CGPoint(x: -1, y: -1)
        var b = [UInt8](repeating: 0, count: 0x100)
        b[0x04] = 0xf8
        b[0x3a] = 0x10
        withUnsafeBytes(of: &w) { for (i, x) in $0.enumerated() { b[0x3c + i] = x } }
        withUnsafeBytes(of: &pt) { for (i, x) in $0.enumerated() { b[0x20 + i] = x } }
        b[0x08] = 0x01
        _ = post(&psn, &b)
        b[0x08] = 0x02
        _ = post(&psn, &b)
    }
}
