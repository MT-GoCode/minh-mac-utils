import Cocoa

/// Hide-on-hover for the trapezoid modes. The panel is click-through (ignoresMouseEvents), so it
/// gets no tracking events. A global event monitor only fires when the foreground app is *another*
/// app — so it went blind whenever Serialize itself was frontmost (e.g. right after editing text).
/// Polling the cursor position instead works in every focus state. Cheap; only runs in trapezoid
/// modes. (NSEvent.mouseLocation is the live pointer, no permission needed.)
final class HoverMonitor {
    var frame: CGRect = .zero
    var onEnter: () -> Void = {}
    var onExit:  () -> Void = {}

    private var timer: Timer?
    private var inside = false

    func start() {
        stop()
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)   // keep firing during menu / window tracking too
        timer = t
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inside = false
    }

    private func check() {
        let now = frame.contains(NSEvent.mouseLocation)
        guard now != inside else { return }
        inside = now
        now ? onEnter() : onExit()
    }
}
