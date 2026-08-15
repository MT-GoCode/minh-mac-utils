import SwiftUI

// The AltTab-style HUD: a tile per candidate window, the selection highlighted, live
// thumbnails. Renders purely from Switcher + Captures published state.
struct SwitcherView: View {
    @EnvironmentObject var s: Switcher
    @ObservedObject private var caps = Captures.shared

    var body: some View {
        let cols = Switcher.columns(max(1, s.candidates.count))
        let grid = Array(repeating: GridItem(.flexible(), spacing: 14), count: cols)
        LazyVGrid(columns: grid, spacing: 14) {
            ForEach(Array(s.candidates.enumerated()), id: \.element.id) { i, w in
                Tile(w: w, selected: i == s.index, image: caps.images[w.id],
                     onActivate: { s.pick(w) },
                     onClose: { s.closeCandidate(w) },
                     onKill: { s.killCandidate(w) })
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}
