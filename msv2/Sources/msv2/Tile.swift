import SwiftUI

// One window as a live thumbnail. Shared by the switcher and the overview.
// - hover → outline + a ✕ close / ⏻ quit pair in the top-right
// - click the body → activate (raise) the window
// - selected (switcher keyboard cursor) → accent outline
// Thumbnails come from Captures (Screen Recording); absent → app icon fallback.
struct Tile: View {
    let w: Win
    var selected: Bool = false
    let image: CGImage?
    var thumbHeight: CGFloat = 108
    let onActivate: () -> Void
    let onClose: () -> Void
    let onKill: () -> Void

    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onActivate) {
                VStack(spacing: 4) {
                    thumb
                    if thumbHeight >= 52 { caption }   // too small for a legible label
                }
                .padding(5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hover {
                HStack(spacing: 4) {
                    circle("xmark", .secondary, onClose)
                    circle("power", .red, onKill)
                }
                .padding(6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            selected ? Color.accentColor : (hover ? Color.white.opacity(0.6) : .clear),
            lineWidth: selected ? 2.5 : 1.5))
        .onHover { hover = $0 }
        .help("\(w.app) — \(w.title)")
    }

    private var caption: some View {
        let label = w.title.isEmpty ? w.app : w.title
        return HStack(spacing: 5) {
            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var thumb: some View {
        SwiftUI.Group {
            if let image {
                Image(image, scale: 1, label: Text(w.app))
                    .resizable().aspectRatio(contentMode: .fit)
            } else {
                let side = min(56, thumbHeight * 0.7)
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func circle(_ symbol: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.black.opacity(0.55)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private var icon: NSImage {
        NSRunningApplication(processIdentifier: w.pid)?.icon
            ?? NSWorkspace.shared.icon(forFile: "/Applications")
    }
}
