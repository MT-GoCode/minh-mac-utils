import Foundation

/// The one aligned-column renderer, shared by every `show`/`list`/`status` table (safe-apps,
/// snooze-presets, zones, pending-request lists). Keeps all of demonlock's tabular output identical.
enum Table {
    /// Render `rows` under `headers` as left-aligned columns separated by two spaces, with a rule.
    /// Cells are padded to the widest value in their column; over-wide cells are not truncated
    /// (readability over strictness — these tables are short). Missing trailing cells render blank.
    static func render(_ headers: [String], _ rows: [[String]], indent: Int = 0) -> String {
        let cols = headers.count
        guard cols > 0 else { return "" }
        var widths = headers.map { $0.count }
        for r in rows {
            for i in 0..<cols where i < r.count { widths[i] = max(widths[i], r[i].count) }
        }
        let pad = String(repeating: " ", count: indent)
        func line(_ cells: [String]) -> String {
            let parts = (0..<cols).map { i -> String in
                let s = i < cells.count ? cells[i] : ""
                // Pad on the right; never chop (padding(toLength:) would truncate a longer cell).
                return s + String(repeating: " ", count: max(0, widths[i] - s.count))
            }
            return pad + parts.joined(separator: "  ")
        }
        var out = line(headers) + "\n"
        out += pad + (0..<cols).map { String(repeating: "─", count: widths[$0]) }.joined(separator: "  ") + "\n"
        for r in rows { out += line(r) + "\n" }
        return out
    }

    /// A titled table; if `rows` is empty, prints the title + an "(none)" line instead of an empty grid.
    static func section(_ title: String, _ headers: [String], _ rows: [[String]], indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        if rows.isEmpty { return "\(pad)\(title)\n\(pad)  (none)\n" }
        return "\(pad)\(title)\n" + render(headers, rows, indent: indent + 2)
    }
}
