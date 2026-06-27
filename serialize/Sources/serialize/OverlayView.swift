import SwiftUI

/// Pitch-black shape + centered white task text. One view drives all five modes.
struct OverlayView: View {
    @ObservedObject var settings = SettingsStore.shared
    let position: OverlayPosition

    var body: some View {
        ZStack {
            background
            Text(settings.taskText.isEmpty ? " " : settings.taskText)
                .font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(lineLimit)            // overflow → tail-truncated with "…"
                .truncationMode(.tail)
                .padding(textPadding)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var background: some View {
        let fill = Group {
            if settings.gradient { ShiftingBackground(level: settings.gradientBrightness) } else { Color.black }
        }
        switch position {
        case .topBar, .bottomBar: fill
        case .topNotch:           fill.clipShape(TabShape(edge: .top))
        case .left:               fill.clipShape(TabShape(edge: .leading))
        case .right:              fill.clipShape(TabShape(edge: .trailing))
        }
    }

    // bars: one line. topNotch: a couple lines then "…". sides: tall box, text wraps down.
    private var lineLimit: Int? {
        switch position {
        case .topBar, .bottomBar: return 1
        case .topNotch:           return 2
        case .left, .right:       return Int(settings.sideHeight / max(settings.fontSize, 8)) + 2
        }
    }

    private var textPadding: EdgeInsets {
        switch position {
        case .topBar, .bottomBar:
            return EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16)
        case .topNotch:
            // push text down so it clears the notch / physical camera block
            return EdgeInsets(top: settings.notchOffset + 8, leading: 30, bottom: 12, trailing: 30)
        case .left:
            return EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 30)
        case .right:
            return EdgeInsets(top: 14, leading: 30, bottom: 14, trailing: 14)
        }
    }
}

/// Drifting + hue-shifting vibrant-dark gradient. Heavily blurred so the colors melt into each
/// other (no hard lines), and the whole thing pulses on a slow curve — mostly vibrant, dipping
/// briefly to black "every now and then". Capped opacity keeps white text readable. Driven by
/// TimelineView(.animation), so it only consumes cycles while the gradient setting is on.
struct ShiftingBackground: View {
    var level: Double = 0.9                                     // brightness control, 0…1.6
    // Base palette is all HOT (red / orange / magenta / pink). The hue then mostly sits still
    // (stays hot) and only occasionally swings into cool — so it reads hot ~most of the time
    // without hand-picking each frame.
    private let colors = [
        Color(red: 0.78, green: 0.10, blue: 0.12),   // red
        Color(red: 0.72, green: 0.30, blue: 0.04),   // orange
        Color(red: 0.72, green: 0.07, blue: 0.42),   // magenta
        Color(red: 0.80, green: 0.10, blue: 0.30),   // crimson-pink
    ]
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let a = CGFloat((sin(t * 0.15) + 1) / 2)            // slow direction drift
            let b = CGFloat((cos(t * 0.11) + 1) / 2)
            let s = (sin(t * 0.32) + 1) / 2                     // 0…1
            let pulse = pow(s, 0.42)                            // mostly bright, brief dips to ~black

            // pseudo-random-ish swing (two out-of-phase sines). pow() squashes it toward 0, so the
            // hue dwells on the hot base most of the time and rarely makes a big cool excursion.
            let raw = (sin(t * 0.07) + sin(t * 0.029) * 0.6) / 1.6   // ~ -1…1, irregular
            let hueDeg = (raw < 0 ? -1.0 : 1.0) * pow(abs(raw), 2.2) * 230

            ZStack {
                Color.black
                LinearGradient(colors: colors,
                               startPoint: UnitPoint(x: a, y: 0),
                               endPoint: UnitPoint(x: 1 - a, y: 1 - b * 0.35))
                    .hueRotation(.degrees(hueDeg))
                    .brightness(max(0, level - 1.0) * 0.35)     // lift luminance once past 1.0
                    .saturation(1.0 + max(0, level - 1.0) * 0.5)
                    .scaleEffect(1.3)                           // oversize so blur doesn't darken edges
                    .blur(radius: 42)                           // melt the color boundaries
                    .opacity(min(1.0, pulse * level))           // brightness scales opacity too
            }
        }
    }
}
