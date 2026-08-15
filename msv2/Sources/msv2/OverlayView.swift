import SwiftUI
import UniformTypeIdentifiers

// All desktops in spaced views, laid out by the progressive GridLayout: one desktop
// fills the screen, the "+" rides a thin edge bar (or a free cell) until the configured
// grid is full — only then does the view scroll. Cards: header (rename ✏, seed 🪄,
// delete 🗑), live-thumbnail tiles sized so every window fits, drag a tile onto another
// card to move the window, drag a header onto another card to reorder desktops.
struct OverlayView: View {
    @EnvironmentObject var o: Overlay
    @ObservedObject private var caps = Captures.shared
    @ObservedObject private var cfg = Config.shared

    var body: some View {
        GeometryReader { geo in
            let n = o.groups.count
            let l = GridLayout(n: n, w: cfg.gridW, h: cfg.gridH)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.55)
                    .onTapGesture { o.renamingID != nil ? o.endRename() : o.hide() }
                if l.scrolling {
                    scrolling(l, size: geo.size)
                } else {
                    fixed(l, size: geo.size, n: n)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func fixed(_ l: GridLayout, size: CGSize, n: Int) -> some View {
        let inset: CGFloat = 40
        let inner = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
        let (cells, plusRect) = l.frames(in: inner, n: n)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(o.groups.enumerated()), id: \.element.id) { i, g in
                if i < cells.count {
                    DesktopCard(g: g, caps: caps)
                        .frame(width: cells[i].width, height: cells[i].height)
                        .offset(x: inset + cells[i].minX, y: inset + cells[i].minY)
                }
            }
            PlusTarget(thin: l.plus == .bottomBar || l.plus == .rightBar)
                .frame(width: plusRect.width, height: plusRect.height)
                .offset(x: inset + plusRect.minX, y: inset + plusRect.minY)
        }
    }

    private func scrolling(_ l: GridLayout, size: CGSize) -> some View {
        let inset: CGFloat = 40
        let gap: CGFloat = 16
        let ch = (size.height - inset * 2 - gap * CGFloat(cfg.gridH - 1))
            / CGFloat(cfg.gridH)
        let cols = Array(repeating: GridItem(.flexible(), spacing: gap), count: l.cols)
        return ScrollView {
            LazyVGrid(columns: cols, spacing: gap) {
                ForEach(o.groups) { g in
                    DesktopCard(g: g, caps: caps).frame(height: ch)
                }
                PlusTarget(thin: false).frame(height: ch)
            }
            .padding(inset)
        }
    }
}

private struct DesktopCard: View {
    @EnvironmentObject var o: Overlay
    let g: GroupView
    @ObservedObject var caps: Captures
    @State private var hover = false
    @State private var targeted = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            windows
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(
                    targeted ? Color.accentColor
                        : (g.isCurrent ? Color.accentColor : .white.opacity(0.12)),
                    lineWidth: (targeted || g.isCurrent) ? 2 : 1)))
        .onHover { hover = $0 }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String else { return }
                Task { @MainActor in
                    if s.hasPrefix("group:"), let id = UUID(uuidString: String(s.dropFirst(6))) {
                        Engine.shared.reorder(id, before: g.id)
                        Overlay.shared.refresh()
                    } else if let wid = CGWindowID(s) {
                        Overlay.shared.drop(wid, on: g.id)
                    }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { o.jump(to: g.id) } label: {
                HStack(spacing: 8) {
                    Text("\(g.index + 1)")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(g.isCurrent ? Color.accentColor : .gray.opacity(0.4)))
                        .foregroundStyle(.white)
                    if o.renamingID == g.id {
                        TextField("name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .onChange(of: draft) { _, v in
                                if v.count > kMaxDesktopName {
                                    draft = String(v.prefix(kMaxDesktopName))
                                }
                                o.liveRename(g.id, draft)   // updates as you type
                            }
                            .onSubmit { o.endRename() }
                            .onExitCommand { o.endRename() }
                    } else {
                        Text(g.name).font(.system(size: 15, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag { NSItemProvider(object: "group:\(g.id.uuidString)" as NSString) }

            if hover, o.renamingID != g.id {
                headerButton("pencil") { draft = g.name; o.beginRename(g.id) }
                headerButton("wand.and.stars") { o.seed(g.id) }
                headerButton("trash", tint: .red) { o.deleteGroup(g.id) }
            }
            Text("\(g.windows.count)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Tiles sized so ALL windows fit inside the card: pick the column count whose
    /// resulting tile is largest, then hand each Tile its exact thumb height.
    private var windows: some View {
        GeometryReader { geo in
            let k = g.windows.count
            if k == 0 {
                Text("drop windows here").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let gap: CGFloat = 8
                let best = Self.bestColumns(k: k, size: geo.size, gap: gap)
                let rows = Int(ceil(Double(k) / Double(best)))
                let tileH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                let cols = Array(repeating: GridItem(.flexible(), spacing: gap), count: best)
                LazyVGrid(columns: cols, spacing: gap) {
                    ForEach(g.windows) { w in
                        Tile(w: w, image: caps.images[w.id],
                             thumbHeight: max(28, tileH - 30),
                             onActivate: { o.focus(w) },
                             onClose: { o.closeWindow(w) },
                             onKill: { o.killApp(w) })
                            .onDrag { NSItemProvider(object: "\(w.id)" as NSString) }
                    }
                }
            }
        }
    }

    private static func bestColumns(k: Int, size: CGSize, gap: CGFloat) -> Int {
        var best = 1
        var bestScore: CGFloat = 0
        for c in 1...max(1, k) {
            let r = Int(ceil(Double(k) / Double(c)))
            let w = (size.width - gap * CGFloat(c - 1)) / CGFloat(c)
            let h = (size.height - gap * CGFloat(r - 1)) / CGFloat(r)
            let score = min(w, h * 1.4)
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    private func headerButton(
        _ symbol: String, tint: Color = .secondary, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.4)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

private struct PlusTarget: View {
    @EnvironmentObject var o: Overlay
    let thin: Bool

    var body: some View {
        Button { o.newGroup() } label: {
            SwiftUI.Group {
                if thin {
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                        Text("New Desktop").font(.system(size: 13))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: thin ? 10 : 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}
