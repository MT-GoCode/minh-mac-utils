import Cocoa
import ApplicationServices

/// Bars-only "true reservation". macOS has no public API to shrink other apps' maximize area
/// (only Dock + menu bar reserve), so this is a focused mini window-manager: it watches every
/// regular app's windows via the Accessibility API and, whenever a window pokes into the
/// reserved strip, clamps it back out. Requires a one-time Accessibility grant (no sudo).
final class ReserveManager {
    static let shared = ReserveManager()

    private var active = false
    private var strip: CGRect = .zero        // reserved band, Cocoa global coords (bottom-left origin)
    private var availMinY: CGFloat = 0        // allowed window band on the bar's screen
    private var availMaxY: CGFloat = 0
    private var observers: [pid_t: AXObserver] = [:]

    // MARK: - lifecycle

    func start(strip: CGRect, position: OverlayPosition, screen: NSScreen) {
        stop()
        ensureTrusted()
        self.strip = strip
        let f = screen.frame
        if position == .topBar {            // band below the bar
            availMinY = f.minY
            availMaxY = strip.minY
        } else {                            // bottomBar: band above the bar
            availMinY = strip.maxY
            availMaxY = f.maxY
        }
        active = true

        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
    }

    func stop() {
        guard active || !observers.isEmpty else { return }
        active = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, obs) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers.removeAll()
    }

    @discardableResult
    func ensureTrusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - app observers

    @objc private func appLaunched(_ note: Notification) {
        guard active,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        // give the app a beat to create its windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attach(app) }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }

    private let events = [
        kAXWindowResizedNotification, kAXWindowMovedNotification,
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationActivatedNotification,
    ]

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, observers[pid] == nil else { return }
        let appEl = AXUIElementCreateApplication(pid)

        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, _, refcon in
            let mgr = Unmanaged<ReserveManager>.fromOpaque(refcon!).takeUnretainedValue()
            mgr.clamp(element)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in events {
            AXObserverAddNotification(observer, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        for w in windows(of: appEl) { clamp(w) }
    }

    // MARK: - clamping

    /// Push a window out of the reserved strip. Idempotent: a window already inside the allowed
    /// band yields no write, so our own resize doesn't re-trigger an endless loop.
    private func clamp(_ win: AXUIElement) {
        guard active, let axr = axFrame(win) else { return }
        let c = toCocoa(axr)
        guard c.intersects(strip) else { return }

        var r = c
        let availH = availMaxY - availMinY
        if r.height > availH { r.size.height = availH }
        if r.maxY > availMaxY { r.origin.y = availMaxY - r.height }
        if r.minY < availMinY { r.origin.y = availMinY }

        if abs(r.origin.y - c.origin.y) > 1 || abs(r.height - c.height) > 1 {
            axSet(win, frame: toAX(r))
        }
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return [] }
        return arr
    }

    // MARK: - AX frame get/set + coordinate flip

    private func axFrame(_ win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)   // AX/top-left coords
    }

    private func axSet(_ win: AXUIElement, frame: CGRect) {
        var pos = frame.origin, size = frame.size
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        }
    }

    /// Height of the screen anchored at the global origin — the reference for the AX↔Cocoa flip.
    private var flipHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
    }
    private func toCocoa(_ ax: CGRect) -> CGRect {
        CGRect(x: ax.minX, y: flipHeight - ax.maxY, width: ax.width, height: ax.height)
    }
    private func toAX(_ c: CGRect) -> CGRect {
        CGRect(x: c.minX, y: flipHeight - c.maxY, width: c.width, height: c.height)
    }
}
