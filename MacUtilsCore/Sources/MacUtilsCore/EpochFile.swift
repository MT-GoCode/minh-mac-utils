import Foundation

/// A one-value file holding an epoch (as text) or the literal `null` — the snooze-until store in
/// demonlock and blockrem. Missing/empty/`null`/non-positive ⇒ nil.
public enum EpochFile {
    public static func read(_ path: String) -> Date? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "null", let epoch = Double(t), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
    public static func write(_ date: Date?, to path: String) throws {
        try (date.map { String($0.timeIntervalSince1970) } ?? "null")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}
