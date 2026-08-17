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
    var phase: String            // standby | monitoring | countdown | locked | snoozed
    var verdict: String?         // allow | block | nil
    var reason: String
    var countdownDeadlineEpoch: Double?
    var countdownSeconds: Double
    var pollSeconds: Double
    var policyString: String
    var tree: EvalNode?
    var insideZones: [String]
    var sshAddr: String?         // "minh@192.168.1.42 · mac.local" — shown so you can SSH in to disarm
    var health: Health
    var releaseValve: RVStatus?  // the delay-gated admin-grant valve (nil ⇒ never configured)
    var delayedPolicy: DelayedStatus? = nil   // a queued `delay-set-policy` change (nil ⇒ none ever queued)
    var delayedZones: DelayedStatus? = nil    // a queued zones-map change (nil ⇒ none ever queued)
    var delayedGatePolicy: DelayedStatus? = nil  // a queued release-valve gate-policy change
    var safeApps: SafeApps.Status? = nil            // pending delayed safe-app registrations
    var snoozePresets: SnoozePresets.Status? = nil  // in-flight invocation + pending delayed-adds
    var lockbox: Lockbox.Status? = nil              // password-lockbox lock state (names only, no secrets)
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
    var guiPids: [Int32]         // PIDs of the user's .regular GUI apps (NOT the agent) — the LOCKED
                                 // kill list. Root SIGKILLs these so distractions die but the sensor lives.
}

// MARK: - Held fix (root-owned, persisted — survives reboot/sleep so login needs nothing special)

/// The one location truth — a DURABLE, root-owned record persisted across reboot/sleep so login/wake
/// need nothing special and the user can't forge it. `fixTs` is the adopted fix's CoreLocation timestamp
/// AND the adoption high-water mark: only a STRICTLY-newer fix is adopted, so a re-streamed stale fix
/// can't masquerade as new. The record is never deleted; ONE timer carries its trust —
///
///   the fix is **LIVE** (usable by the policy) iff `now < confirmedUntil`.
///
/// Every positive **confirmation** — a new fix, or the anchor still overlapping the live scan — pushes
/// `confirmedUntil = now + graceSeconds`. Anything that ISN'T confirmation (Wi-Fi off, anchor mismatch,
/// agent dead, agent starting, just-woke) simply stops pushing, so the timer runs out → STALE → location
/// unknown → fail-closed. One timer, one meaning; every "no signal" case coasts the same way. See MODEL.md.
///
/// The anchor is a FROZEN snapshot taken once at adoption (never grown — growing it post-adoption let an
/// offline move poison it). It's RICH because the agent feeds the union of BSSIDs seen in the last
/// scanWindowSeconds, and a full sweep returns both radios of a dual-band router at once.
struct HeldFix: Codable {
    var lat: Double
    var lon: Double
    var fixTs: Double
    var acc: Double              // horizontalAccuracy at adoption (status display)
    var anchor: [String]         // stable BSSIDs seen at adoption; the liveness signal (frozen snapshot)
    var confirmedUntil: Double   // wall-clock; the fix is LIVE iff now < this (persisted, reboot-safe)

    func live(now: Double) -> Bool { now < confirmedUntil }
}

enum HeldFixStore {
    static func read() -> HeldFix? { loadJSON(Paths.heldFixFile) }
    static func write(_ h: HeldFix) { saveJSON(h, to: Paths.heldFixFile) }
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
    static func read() -> StateSnapshot? { loadJSON(Paths.stateFile) }
    static func write(_ snap: StateSnapshot) { saveJSON(snap, to: Paths.stateFile) }
}
