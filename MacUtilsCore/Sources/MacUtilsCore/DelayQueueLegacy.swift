import Foundation

/// Migration decoders for pre-DelayQueue state files. Core carries only the shape shared by more
/// than one tool; each app adds its own in an `extension Legacy` (never a same-named enum).
public enum Legacy {
    private struct KeyOnlyMap: Codable {
        struct Pending: Codable { var requestedAt: Double; var applyAt: Double }
        var pending: [String: Pending] = [:]
    }

    /// `{pending: {key: {requestedAt, applyAt}}}` (the sidecar's delay-add registry): legacy pending
    /// has NO payload field — payload := key. seq assigned in requestedAt order (ties broken by key
    /// for determinism).
    public static func keyOnlyMap() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)? {
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
