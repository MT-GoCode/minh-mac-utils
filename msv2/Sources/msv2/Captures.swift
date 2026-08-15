import ScreenCaptureKit

// Live window thumbnails for the overlay and switcher. One-shot screenshots on a timer,
// only while a panel is visible — no persistent stream, no permanent recording
// indicator, zero idle cost. PURELY COSMETIC: needs Screen Recording, but tracking never
// touches this, so a denied permission just falls the tiles back to app icons.
@MainActor
final class Captures: ObservableObject {
    static let shared = Captures()
    @Published private(set) var images: [CGWindowID: CGImage] = [:]
    private var timer: Timer?
    private var running = false

    func start() {
        refreshNow()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.6, repeats: true) { _ in
            Task { @MainActor in Captures.shared.refreshNow() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop only if no panel still wants thumbnails.
    func stopIfIdle() {
        guard !Overlay.shared.isOpen, !Switcher.shared.isOpen else { return }
        timer?.invalidate()
        timer = nil
        images = [:]
    }

    private func wantedIDs() -> Set<CGWindowID> {
        var s = Set<CGWindowID>()
        if Overlay.shared.isOpen { for g in Overlay.shared.groups { s.formUnion(g.windows.map(\.id)) } }
        if Switcher.shared.isOpen { s.formUnion(Switcher.shared.candidates.map(\.id)) }
        return s
    }

    private func refreshNow() {
        guard !running else { return }
        running = true
        let wanted = wantedIDs()
        guard !wanted.isEmpty else { running = false; return }
        let px = Config.shared.data.thumbPx
        Task { @MainActor in
            defer { running = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false) else { return }
            var next = images.filter { wanted.contains($0.key) }   // drop gone windows
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for scw in content.windows where wanted.contains(scw.windowID) {
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, px / max(scw.frame.width, scw.frame.height, 1))
                        cfg.width = max(2, Int(scw.frame.width * scale))
                        cfg.height = max(2, Int(scw.frame.height * scale))
                        cfg.showsCursor = false
                        let img = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: scw),
                            configuration: cfg)
                        return (scw.windowID, img)
                    }
                }
                for await (id, img) in group where img != nil { next[id] = img }
            }
            images = next
        }
    }
}
