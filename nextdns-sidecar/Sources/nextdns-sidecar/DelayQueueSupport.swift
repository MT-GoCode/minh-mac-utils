import Foundation

// Sidecar-local shims for the four free symbols the VENDORED DelayQueue.swift/MarkerIO.swift need
// (nowEpoch already lives in Core.swift). Copied from demonlock's Util.swift.

func loadJSON<T: Decodable>(_ path: String) -> T? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: d)
}

@discardableResult
func saveJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
    let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
    guard let d = try? e.encode(value) else { return false }
    return (try? d.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}

func logStderr(_ s: String) { logLine(s) }

/// Legacy decoder for the pre-DelayQueue {pending: {domain: {requestedAt, applyAt}}} registry.
enum Legacy {
    private struct KeyOnlyMap: Codable {
        struct Pending: Codable { var requestedAt: Double; var applyAt: Double }
        var pending: [String: Pending] = [:]
    }
    static func keyOnlyMap() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)? {
        { data in
            guard let r = try? JSONDecoder().decode(KeyOnlyMap.self, from: data) else { return nil }
            var rows: [String: DelayQueue.Item] = [:]
            var seq: UInt64 = 0
            for (k, p) in r.pending.sorted(by: { ($0.value.requestedAt, $0.key) < ($1.value.requestedAt, $1.key) }) {
                rows[k] = DelayQueue.Item(payload: k, requestedAt: p.requestedAt, applyAt: p.applyAt, seq: seq)
                seq += 1
            }
            return (rows, nil)
        }
    }
}
