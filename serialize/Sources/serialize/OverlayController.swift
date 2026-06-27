import Cocoa
import SwiftUI

/// Owns the single overlay panel: computes its frame per mode, swaps the SwiftUI content,
/// wires hide-on-hover (trapezoids) and space reservation (bars), and tracks hidden state.
final class OverlayController {
    private let settings = SettingsStore.shared
    private let panel = OverlayPanel()
    private let hover = HoverMonitor()
    private var hidden = false
    private var renderedPosition: OverlayPosition?   // which mode the hosting view is built for

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { refresh() }

    var isHidden: Bool { hidden }

    func setHidden(_ h: Bool) {
        hidden = h
        if h {
            panel.orderOut(nil)
            hover.stop()
            ReserveManager.shared.stop()
        } else {
            refresh()
        }
    }

    /// Rebuild everything for the current settings (position / font / notch offset / screen).
    func refresh() {
        guard !hidden else { return }
        let pos = settings.position
        let frame = frame(for: pos)

        // OverlayView observes settings, so text/font/size update themselves — only rebuild the
        // hosting view when the mode (shape) actually changes, to avoid flicker on size sliders.
        if renderedPosition != pos {
            panel.contentView = NSHostingView(rootView: OverlayView(position: pos))
            renderedPosition = pos
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // hide-on-hover only for the floating trapezoids
        if pos.isTrapezoid {
            hover.frame = frame
            hover.onEnter = { [weak self] in self?.panel.orderOut(nil) }   // instant hide
            hover.onExit  = { [weak self] in self?.panel.orderFrontRegardless() }
            hover.start()
        } else {
            hover.stop()
        }

        // space reservation only for the bars
        if pos.isBar, let screen = primaryScreen {
            ReserveManager.shared.start(strip: frame, position: pos, screen: screen)
        } else {
            ReserveManager.shared.stop()
        }
    }

    // MARK: - geometry

    private var primaryScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? primaryScreen
    }

    private var barHeight: CGFloat { CGFloat(settings.barThickness) }

    private func frame(for pos: OverlayPosition) -> NSRect {
        switch pos {
        case .topBar:
            guard let s = primaryScreen else { return .zero }
            let vf = s.visibleFrame, f = s.frame
            return NSRect(x: f.minX, y: vf.maxY - barHeight, width: f.width, height: barHeight)
        case .bottomBar:
            guard let s = primaryScreen else { return .zero }
            let vf = s.visibleFrame, f = s.frame
            return NSRect(x: f.minX, y: vf.minY, width: f.width, height: barHeight)
        case .topNotch:
            guard let s = notchScreen else { return .zero }
            let f = s.frame
            let w = CGFloat(settings.notchWidth), h = CGFloat(settings.notchHeight)
            return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        case .left:
            guard let s = primaryScreen else { return .zero }
            let f = s.frame
            let w = CGFloat(settings.sideWidth), h = CGFloat(settings.sideHeight)
            return NSRect(x: f.minX, y: f.midY - h / 2, width: w, height: h)
        case .right:
            guard let s = primaryScreen else { return .zero }
            let f = s.frame
            let w = CGFloat(settings.sideWidth), h = CGFloat(settings.sideHeight)
            return NSRect(x: f.maxX - w, y: f.midY - h / 2, width: w, height: h)
        }
    }
}
