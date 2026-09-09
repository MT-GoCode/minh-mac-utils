import CoreLocation
import Foundation

/// One queued zone operation — the delayzones queue payload (ops, not snapshots: a snapshot taken
/// from disk at click time is why two queued edits silently cancelled each other on 2026-09-07).
struct ZoneOp: Codable, Equatable {
    var op: String                       // "add" | "del"
    var zone: Zone? = nil                // add
    var name: String? = nil              // del

    var opKey: String? {
        switch op {
        case "add": return zone.map { "add:\($0.name)" }
        case "del": return name.map { "del:\($0)" }
        default: return nil
        }
    }
    var zoneName: String? { op == "add" ? zone?.name : name }

    static func decode(_ payload: String) -> ZoneOp? {
        try? JSONDecoder().decode(ZoneOp.self, from: Data(payload.utf8))
    }
}

enum ZoneOps {
    /// Queue key for a payload line (nil ⇒ unkeyable, rejected).
    static func key(_ payload: String) -> String? { ZoneOp.decode(payload)?.opKey }

    /// Queue-time validation: decodable; name non-empty and newline-free (interior newlines would
    /// corrupt marker keys); add: sane geometry. Name COLLISION is checked at LANDING only — a
    /// queued del of the same name may land first (the edit flow).
    static func validateAtQueue(_ payload: String) -> Bool {
        guard let op = ZoneOp.decode(payload), let n = op.zoneName,
              !n.isEmpty, !n.contains("\n") else { return false }
        switch op.op {
        case "del": return true
        case "add":
            guard let z = op.zone else { return false }
            switch z.shape {
            case .circle(_, _, let r): return r > 0
            case .polygon(let pts):
                return pts.count >= 3 && isSimplePolygon(pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            }
        default: return false
        }
    }

    /// Landing: batched, two phases, no retry loop.
    /// Phase 1 folds ops in seq order into a copy of `live`; an op failing its OWN precondition is
    /// dropped there with a specific reason. Phase 2 is DIFFERENTIAL: the batch fails only if it
    /// introduces a NEW unresolved policy/gate reference beyond what the live state already dangles
    /// (absolute validation would drop every batch forever on an already-inconsistent machine).
    /// Joint projection: validated against the due doc if one is about to land; if the projection
    /// fails but the due doc is fine against LIVE zones, the DOC wins and the zone batch drops
    /// ("conflicts with landing policy") — landing one change beats destroying both.
    static func fold(due: [(key: String, payload: String)], live: [Zone],
                     livePolicy: String?, liveGatePolicy: String?,
                     duePolicyDoc: String?, dueGateDoc: String?)
        -> (final: [Zone]?, verdicts: [String: (ok: Bool, reason: String?)]) {

        var verdicts: [String: (ok: Bool, reason: String?)] = [:]
        var working = live
        var survivors: [String] = []

        // Phase 1 — per-op preconditions, seq order.
        for (k, payload) in due {
            guard let op = ZoneOp.decode(payload) else { verdicts[k] = (false, "undecodable"); continue }
            switch op.op {
            case "add":
                guard validateAtQueue(payload) else { verdicts[k] = (false, "bad geometry"); continue }
                guard let z = op.zone, !working.contains(where: { $0.name == z.name }) else {
                    verdicts[k] = (false, "name exists"); continue
                }
                working.append(z); survivors.append(k)
            case "del":
                guard let n = op.name, let i = working.firstIndex(where: { $0.name == n }) else {
                    verdicts[k] = (false, "no such zone (no-op)"); continue
                }
                working.remove(at: i); survivors.append(k)
            default:
                verdicts[k] = (false, "unknown op")
            }
        }
        guard !survivors.isEmpty else { return (nil, verdicts) }

        func unresolved(_ zs: [Zone], _ p: String?, _ g: String?) -> Set<String> {
            var refs: Set<String> = []
            if let p, let r = try? PolicyEngine.referencedZones(p) { refs.formUnion(r) }
            if let g, let r = try? PolicyEngine.referencedZones(g, allowInPolicy: true) { refs.formUnion(r) }
            let names = Set(zs.map(\.name))
            return refs.filter { !names.contains($0) }
        }
        let liveDangles = unresolved(live, livePolicy, liveGatePolicy)
        func dropBatch(_ reason: String) -> (final: [Zone]?, verdicts: [String: (ok: Bool, reason: String?)]) {
            var v = verdicts
            for k in survivors { v[k] = (false, reason) }
            return (nil, v)
        }

        // Phase 2 — differential, against the joint projection first.
        let projP = duePolicyDoc ?? livePolicy, projG = dueGateDoc ?? liveGatePolicy
        var newUnresolved = unresolved(working, projP, projG).subtracting(liveDangles)
        if newUnresolved.isEmpty {
            for k in survivors { verdicts[k] = (true, nil) }
            return (working, verdicts)
        }
        // Projection failed. If a due doc exists AND validates against LIVE zones, the doc wins.
        if duePolicyDoc != nil || dueGateDoc != nil {
            if unresolved(live, projP, projG).subtracting(liveDangles).isEmpty {
                return dropBatch("conflicts with landing policy")
            }
            // The due doc is broken against live zones too — it will drop at its own landing.
            // Retry differentially against the LIVE docs only.
            newUnresolved = unresolved(working, livePolicy, liveGatePolicy).subtracting(liveDangles)
            if newUnresolved.isEmpty {
                for k in survivors { verdicts[k] = (true, nil) }
                return (working, verdicts)
            }
        }
        return dropBatch("would orphan policy reference \(newUnresolved.sorted().map { "\"\($0)\"" }.joined(separator: ", "))")
    }

    /// A polygon is "simple" iff no two non-adjacent edges intersect (moved from ZonesUI; the UI
    /// converts its CLLocationCoordinate2D verts at the call site).
    static func isSimplePolygon(_ p: [CLLocationCoordinate2D]) -> Bool {
        guard p.count >= 3 else { return false }
        func segsIntersect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                           _ c: CLLocationCoordinate2D, _ d: CLLocationCoordinate2D) -> Bool {
            func ccw(_ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D, _ p3: CLLocationCoordinate2D) -> Bool {
                (p3.latitude - p1.latitude) * (p2.longitude - p1.longitude) >
                (p2.latitude - p1.latitude) * (p3.longitude - p1.longitude)
            }
            return ccw(a, c, d) != ccw(b, c, d) && ccw(a, b, c) != ccw(a, b, d)
        }
        let n = p.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                // skip adjacent edges (share a vertex), incl. the first/last wrap pair
                if abs(i - j) <= 1 || (i == 0 && j == n - 1) { continue }
                if segsIntersect(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n]) { return false }
            }
        }
        return true
    }
}
