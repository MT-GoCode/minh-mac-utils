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
    var enforcerdLoaded = true
    var agentFeedFresh = false
    var agentReady = false
    var lastFixAgeSec: Double?
    var locState = "unknown"     // ok | notDetermined | denied | restricted | servicesOff | noFix
    var wifiOn = false
    var scanFresh = false
    var lastScanAgeSec: Double?
    var needsPermAsk = false
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
    var ts: Double               // when the agent emitted this
    var ready: Bool              // sensors initialized AND a valid current fix exists
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var bssids: [String]?        // nil ⇒ scan unavailable/redacted (location input = unknown)
    var locState: String         // ok | notDetermined | denied | restricted | servicesOff | noFix
    var wifiOn: Bool
    var scanTs: Double?
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
