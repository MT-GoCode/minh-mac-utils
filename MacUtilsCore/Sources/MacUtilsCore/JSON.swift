import Foundation

/// Decode a Codable from a JSON file. nil if absent, unreadable, or corrupt (callers fall back to a
/// default). The one place the load pattern lives.
public func loadJSON<T: Decodable>(_ path: String) -> T? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

/// Encode + ATOMICALLY write a Codable to a JSON file (sorted keys; pretty optional), then optionally
/// chmod it. Best-effort → returns success. The one place the save pattern lives.
@discardableResult
public func saveJSON<T: Encodable>(_ value: T, to path: String, mode: mode_t? = nil, pretty: Bool = false) -> Bool {
    let e = JSONEncoder(); e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard let d = try? e.encode(value) else { return false }
    guard let m = mode else {
        return (try? d.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
    // Restricted mode (e.g. lockbox secrets, 0600): create the temp with the FINAL mode from the start,
    // then rename — never the atomic-write-then-chmod pattern, which leaves a umask-0644 window in which
    // the file is briefly world/group-readable (a secret leak).
    let tmp = path + ".tmp.\(getpid())"
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, m)
    if fd < 0 { return false }
    let wrote = d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var base = raw.baseAddress else { return true }   // empty payload
        var left = raw.count
        while left > 0 {
            let n = write(fd, base, left)
            if n <= 0 { return false }
            base = base.advanced(by: n); left -= n
        }
        return true
    }
    close(fd)
    guard wrote, rename(tmp, path) == 0 else { unlink(tmp); return false }
    return true
}

public extension KeyedDecodingContainer {
    /// Lenient field decode: a missing key OR a wrong-typed value falls back to `default`, so a
    /// settings file can evolve without breaking old installs. Same `try?` semantics every tool
    /// hand-wrote in its `init(from:)`.
    func lenient<T: Decodable>(_ key: Key, default d: T) -> T {
        (try? decode(T.self, forKey: key)) ?? d
    }
}
