import Cocoa

/// Borderless non-activating panel. Floats above normal windows on every Space and over
/// fullscreen apps. Can never become key/main, so clicking it never activates Serialize.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar                                  // 25: above the menu bar + normal windows
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true                           // true click-through — never intercept clicks
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
