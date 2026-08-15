import AppKit

/// Desktop names are chips in a menu, a settings row and an overlay header — long ones
/// wreck all three, so they're capped at the source.
let kMaxDesktopName = 24

struct SeedCmd: Codable, Identifiable, Equatable {
    var id = UUID()
    var cmd: String
    var on: Bool
}

struct ConfigData: Codable, Equatable {
    var gridW = 3               // overview grid, columns (≥2)
    var gridH = 2               // overview grid, rows (≥2)
    var thumbPx = 600.0         // captured thumbnail long edge
    var appPriority: [String] = []   // substring per line; windows in a desktop sort by first match
    var excludeApps: [String] = []   // substring per line; matching apps are ignored entirely
    var seeds: [SeedCmd] = [
        SeedCmd(cmd: "open -na \"Google Chrome\" --args --new-window", on: true),
        SeedCmd(cmd: "open -a Terminal ~", on: true),
    ]
}

// User settings, JSON next to the state file. Saved on every change; safe defaults on
// any decode failure.
@MainActor
final class Config: ObservableObject {
    static let shared = Config()

    // NEVER write to `data` inside didSet — that re-enters the setter and recurses until
    // the stack overflows (SIGSEGV at launch). Clamping happens at read time instead.
    @Published var data: ConfigData {
        didSet { if data != oldValue { save() } }
    }

    var gridW: Int { min(8, max(2, data.gridW)) }
    var gridH: Int { min(8, max(2, data.gridH)) }

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("msv2/config.json")
    }

    init() {
        data = (try? Data(contentsOf: Self.file))
            .flatMap { try? JSONDecoder().decode(ConfigData.self, from: $0) } ?? ConfigData()
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(data).write(to: Self.file, options: .atomic)
    }

    func priorityRank(_ app: String) -> Int {
        let pr = data.appPriority.map { $0.lowercased() }.filter { !$0.isEmpty }
        return pr.firstIndex { app.lowercased().contains($0) } ?? pr.count
    }

    func isExcluded(_ app: String) -> Bool {
        let low = app.lowercased()
        return data.excludeApps.contains { !$0.isEmpty && low.contains($0.lowercased()) }
    }
}

// The overview's progressive grid. Grows the smaller dimension first (rows before
// columns on ties), capped at the configured W×H:
//   1 desktop  → fills the screen, "+" is a thin bar along the bottom (the next row)
//   2 desktops → stacked, "+" is a thin bar on the right (the next column)
//   3 desktops → 2×2 quadrants, "+" takes the free 4th cell
//   …until W×H is full — only then does the overview scroll ("+" becomes the next cell).
struct GridLayout {
    enum Plus: Equatable { case cell(Int), bottomBar, rightBar }
    let cols: Int
    let rows: Int
    let plus: Plus
    let scrolling: Bool

    init(n: Int, w: Int, h: Int) {
        let W = max(2, w), H = max(2, h)
        var c = 1, r = 1
        while c * r < n, c < W || r < H {
            if (r <= c && r < H) || c == W { r += 1 } else { c += 1 }
        }
        if c * r >= n + 1 {
            cols = c; rows = r; plus = .cell(n); scrolling = false
        } else if c < W || r < H {
            cols = c; rows = r
            plus = ((r <= c && r < H) || c == W) ? .bottomBar : .rightBar
            scrolling = false
        } else {
            cols = W
            rows = Int((Double(n + 1) / Double(W)).rounded(.up))
            plus = .cell(n)
            scrolling = true
        }
    }

    /// Fixed (non-scroll) placement: desktop cell rects + the "+" rect.
    func frames(in size: CGSize, n: Int, gap: CGFloat = 16, bar: CGFloat = 46)
        -> (cells: [CGRect], plusRect: CGRect) {
        var region = CGRect(origin: .zero, size: size)
        var plusRect = CGRect.zero
        switch plus {
        case .bottomBar:
            plusRect = CGRect(x: 0, y: size.height - bar, width: size.width, height: bar)
            region.size.height -= bar + gap
        case .rightBar:
            plusRect = CGRect(x: size.width - bar, y: 0, width: bar, height: size.height)
            region.size.width -= bar + gap
        case .cell: break
        }
        let cw = (region.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch = (region.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        func rect(_ i: Int) -> CGRect {
            CGRect(x: CGFloat(i % cols) * (cw + gap), y: CGFloat(i / cols) * (ch + gap),
                   width: cw, height: ch)
        }
        let cells = (0..<n).map(rect)
        if case .cell(let i) = plus { plusRect = rect(i) }
        return (cells, plusRect)
    }
}
