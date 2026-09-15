import Foundation
import MacUtilsCore

/// Published by the root daemon every tick; the agent's ONLY read surface. The agent renders
/// purely from this — it never reads the schedule itself, so all timing truth stays root-owned.
/// If the agent can't read this (missing/garbage), it FAILS OPEN (no blocker) — a blocker bug
/// must never trap you; recovery is always "the block just lifts," never "you're stuck."
struct ActiveState: Codable {
    var updatedEpoch: Double
    var active: Bool
    var label: String
    var endsEpoch: Double          // when the current block ends (drives the countdown)
    var snoozeUntilEpoch: Double?  // for `list`/status display

    static func inactive(snoozeUntil: Double? = nil) -> ActiveState {
        ActiveState(updatedEpoch: nowEpoch(), active: false, label: "", endsEpoch: 0, snoozeUntilEpoch: snoozeUntil)
    }
}

/// Written by the GUI agent (the only process that can see the user session's lock/display
/// state), read by the daemon to gate first-on alarms. Stale/missing ⇒ NOT in use — never fire
/// where nothing could render the block.
struct SessionState: Codable {
    var updatedEpoch: Double
    var locked: Bool
    var displayAsleep: Bool
}

enum SessionStore {
    static func read() -> SessionState? { loadJSON(Paths.sessionFile) }
    static func write(_ s: SessionState) { saveJSON(s, to: Paths.sessionFile) }
}

/// The pure in-use conjunction (freshness ∧ unlocked ∧ display on), separated for `_selftest`.
func sessionInUse(_ s: SessionState?, now: Double) -> Bool {
    guard let s, now - s.updatedEpoch <= 90 else { return false }
    return !s.locked && !s.displayAsleep
}

enum ActiveStore {
    static func read() -> ActiveState? { loadJSON(Paths.activeFile) }
    static func write(_ s: ActiveState) { saveJSON(s, to: Paths.activeFile) }
}
