import Foundation

// MARK: - Annotated policy evaluation tree (published for UI/status)

/// One node of the evaluated policy. `result` is three-valued: true / false / nil(unknown).
struct EvalNode: Codable {
    var kind: String            // AND | OR | NOT | LOCATED_IN_ANY | FOUND_IN_NEARBY_BSSID | TIME_IS_ANY
    var label: String
    var result: Bool?           // true=green, false=red, nil=gray(unknown)
    var detail: String?
    var children: [EvalNode]

    init(kind: String, label: String, result: Bool?, detail: String? = nil, children: [EvalNode] = []) {
        self.kind = kind; self.label = label; self.result = result
        self.detail = detail; self.children = children
    }
}

// MARK: - Health (for status + UI, computed by the daemon from the feed)

struct Health: Codable {
    var agentFeedFresh = false   // transport: is the agent process reporting? (anti-kill)
    var fixReason: String?       // why location is not driving an allow (re-confirming / left-the-Wi-Fi / too-fuzzy)
    var locState = "unknown"     // ok | reduced | notDetermined | denied | restricted | noFix
    var needsPermAsk = false
    var locationTrail: [String] = []   // the per-tick decision map (the user-facing detail; see locationTrail())
}

// MARK: - Published snapshot (state.json — the single UI/status read surface)

struct StateSnapshot: Codable {
    var updatedEpoch: Double
    var lastCheckEpoch: Double
    var armed: Bool
    var snoozeUntilEpoch: Double?
    var enforcedUser: String
    var phase: String            // initializing | monitoring | countdown | snoozed | standby
    var verdict: String?         // allow | block | nil
    var reason: String
    var countdownDeadlineEpoch: Double?
    var countdownSeconds: Double
    var pollSeconds: Double
    var policyString: String
    var tree: EvalNode?
    var insideZones: [String]
    var health: Health
}

// MARK: - Feed payload (agent → root over the trusted socket)

struct FeedPayload: Codable {
    // Raw sensor truth — the agent reports; the ROOT enforcer is the sole judge and sole
    // state-holder (held fix + anchor live root-side so the user can't forge them).
    var ts: Double               // when the agent emitted this packet
    var lat: Double?             // latest ACCEPTED fix (measured after the agent's launch/wake epoch —
    var lon: Double?             //   the agent rejects Apple's cached re-deliveries at the source)
    var acc: Double?             // horizontalAccuracy (m), REAL value — negative = invalid (Apple sentinel)
    var fixTs: Double?           // the fix's REAL CoreLocation timestamp — the enforcer's "new fix?" key
    var bssids: [String]?        // current scan, all MACs (policy input). nil ⇒ scan unavailable/redacted
    var locState: String         // ok | reduced | notDetermined | denied | restricted | noFix
    var scanTs: Double?
}

// MARK: - Held fix (root-owned, persisted — survives reboot/sleep so login needs nothing special)

/// The one location truth, and a DURABLE high-water record. `fixTs` is both the last adopted
/// fix's CoreLocation timestamp AND the adoption high-water mark: we adopt only a STRICTLY
/// newer fix, so a fix whose grace expired can never be re-adopted from the agent's unchanging
/// stream (the resurrection fail-open). The record is therefore never deleted — `graceUntil`
/// carries its trust:
///   • nil               → anchor confirms → trusted.
///   • set, now < it      → anchor lost, coasting (still trusted) until a newer fix or expiry.
///   • set, now ≥ it      → expired → NOT trusted (fail-closed), but kept as the high-water tombstone.
/// `graceUntil` is persisted (absolute wall-clock) so a reboot can't reset the coast window.
struct HeldFix: Codable {
    var lat: Double
    var lon: Double
    var fixTs: Double
    var acc: Double              // horizontalAccuracy at adoption (status display)
    var anchor: [String]         // stable BSSIDs seen at adoption; the liveness signal
    var graceUntil: Double?

    func trusted(now: Double) -> Bool { graceUntil.map { now < $0 } ?? true }
}

enum HeldFixStore {
    static func read() -> HeldFix? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.heldFixFile)) else { return nil }
        return try? JSONDecoder().decode(HeldFix.self, from: data)
    }
    static func write(_ h: HeldFix) {
        guard let data = try? JSONEncoder().encode(h) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.heldFixFile), options: .atomic)
    }
}

// MARK: - Small root-owned scalar files

enum ArmStore {
    /// Missing/unreadable armed file ⇒ fail-closed ⇒ treated as ARMED.
    static func isArmed() -> Bool {
        guard let s = try? String(contentsOfFile: Paths.armedFile, encoding: .utf8) else { return true }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
    static func set(_ armed: Bool, to path: String = Paths.armedFile) throws {
        try (armed ? "1" : "0").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

enum SnoozeStore {
    static func until() -> Date? {
        guard let s = try? String(contentsOfFile: Paths.snoozeFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != "null", let epoch = Double(t), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
    static func set(_ date: Date?, to path: String = Paths.snoozeFile) throws {
        try (date.map { String($0.timeIntervalSince1970) } ?? "null")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}

enum PolicyStore {
    static func text() -> String? {
        guard let s = try? String(contentsOfFile: Paths.policyFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func write(_ s: String, to path: String = Paths.policyFile) throws {
        try s.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

enum StateStore {
    static func read() -> StateSnapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.stateFile)) else { return nil }
        return try? JSONDecoder().decode(StateSnapshot.self, from: data)
    }
    static func write(_ snap: StateSnapshot) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(snap) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.stateFile), options: .atomic)
    }
}
