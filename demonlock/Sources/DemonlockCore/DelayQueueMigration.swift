import Foundation

/// Per-surface legacy decoders for `QStateStore.file(_:legacyDecode:)` — each maps a pre-DelayQueue
/// state file into queue rows exactly once (the first save writes the new shape; an OLD binary
/// reading the new shape decodes nothing and clobbers on save — accepted, fail-closed: queued
/// loosenings vanish, nothing lands early). `lastAppliedAt` survives everywhere.
enum Legacy {
    private struct SingleSlot: Codable {
        struct Pending: Codable { var payload: String; var requestedAt: Double; var applyAt: Double }
        var pending: Pending?
        var lastAppliedAt: Double?
    }

    /// {payload, requestedAt, applyAt} single slot (delay-set-policy, gate-policy) → one row, seq 0.
    static func singleSlot(constKey: String) -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)? {
        { data in
            guard let s = try? JSONDecoder().decode(SingleSlot.self, from: data) else { return nil }
            var rows: [String: DelayQueue.Item] = [:]
            if let p = s.pending {
                rows[constKey] = DelayQueue.Item(payload: p.payload, requestedAt: p.requestedAt,
                                                 applyAt: p.applyAt, seq: 0)
            }
            return (rows, s.lastAppliedAt)
        }
    }

    /// Zones single slot: the legacy payload is a whole-file snapshot that would need a special
    /// apply path bypassing op validation — DROPPED + logged instead (the only thing that slot has
    /// ever held is the Sep-7 no-op set; a special path is creep and a validation bypass).
    static func zonesDropSnapshot() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)? {
        { data in
            guard let s = try? JSONDecoder().decode(SingleSlot.self, from: data) else { return nil }
            if s.pending != nil {
                logStderr("delayed-zones: legacy pending snapshot DROPPED by migration — re-queue as ops from the map")
            }
            return ([:], s.lastAppliedAt)
        }
    }

    private struct SafeAppsRegistry: Codable {
        struct Pending: Codable { var app: SafeApp; var requestedAt: Double; var applyAt: Double }
        var pending: [String: Pending] = [:]
    }

    /// safe-apps: nested `app` object re-encoded canonically (sorted keys) as the row payload, key = name.
    static func safeApps() -> (Data) -> (rows: [String: DelayQueue.Item], lastAppliedAt: Double?)? {
        { data in
            guard let r = try? JSONDecoder().decode(SafeAppsRegistry.self, from: data) else { return nil }
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            var rows: [String: DelayQueue.Item] = [:]
            var seq: UInt64 = 0
            for (name, p) in r.pending.sorted(by: { $0.value.requestedAt < $1.value.requestedAt }) {
                guard let d = try? enc.encode(p.app), let json = String(data: d, encoding: .utf8) else { continue }
                rows[name] = DelayQueue.Item(payload: json, requestedAt: p.requestedAt, applyAt: p.applyAt, seq: seq)
                seq += 1
            }
            return (rows, nil)
        }
    }

    private struct KeyOnlyMap: Codable {
        struct Pending: Codable { var requestedAt: Double; var applyAt: Double }
        var pending: [String: Pending] = [:]
    }

    /// sidecar delay-add (kept here as the TESTED REFERENCE for the sidecar's vendored copy —
    /// demonlock itself has no caller): legacy pending has NO payload field — payload := key.
    /// seq assigned in requestedAt order (ties broken by key for determinism).
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
