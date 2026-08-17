import Foundation

func nowEpoch() -> Double { Date().timeIntervalSince1970 }

func logStderr(_ s: String) {
    let line = "[" + fmtWhen(nowEpoch(), "yyyy-MM-dd HH:mm:ss") + "] " + s + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

func loadJSON<T: Decodable>(_ path: String) -> T? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

func saveJSON<T: Encodable>(_ v: T, to path: String) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let d = try? e.encode(v) else { return }
    try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Render an absolute instant in the current tz for display (storage stays UTC epoch).
func fmtWhen(_ epoch: Double, _ format: String = "EEE yyyy-MM-dd HH:mm") -> String {
    let f = DateFormatter(); f.dateFormat = format
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

/// Remaining-time string for tables: 5400 → "1h30m", 310 → "5m10s", 40 → "40s".
func fmtLeft(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return "\(h)h\(m)m" }
    if m > 0 { return "\(m)m\(sec)s" }
    return "\(sec)s"
}

struct ForceError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
