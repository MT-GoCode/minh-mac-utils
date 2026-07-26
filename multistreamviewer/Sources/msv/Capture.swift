import ScreenCaptureKit

// One-shot window screenshots at 1 Hz, only while some panel is visible.
// No persistent streams → no permanent recording indicator, zero idle cost.
@MainActor
final class Captures: ObservableObject {
    static let shared = Captures()
    @Published private(set) var images: [CGWindowID: CGImage] = [:]
    private var timer: Timer?
    private var running = false

    func start() {
        refreshNow()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in Captures.shared.refreshNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshNow() {
        guard !running else { return }
        running = true
        let c = Controller.shared
        let wanted = Set(
            c.workspaces.flatMap(\.windows).map(\.id) + c.fullscreen.map(\.id)
                + c.switcherWindows.map(\.id))
        Task { @MainActor in
            defer { running = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
            else { return }
            let dim = UserDefaults.standard.object(forKey: "activeDim") as? Double ?? 720
            var new: [CGWindowID: CGImage] = images.filter { wanted.contains($0.key) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for scw in content.windows where wanted.contains(scw.windowID) {
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, dim / max(scw.frame.width, scw.frame.height, 1))
                        cfg.width = max(2, Int(scw.frame.width * scale))
                        cfg.height = max(2, Int(scw.frame.height * scale))
                        cfg.showsCursor = false
                        let img = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: scw),
                            configuration: cfg)
                        return (scw.windowID, img)
                    }
                }
                for await (id, img) in group {
                    if let img { new[id] = img }
                }
            }
            images = new
        }
    }
}
