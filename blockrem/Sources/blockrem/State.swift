import Foundation

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

enum ActiveStore {
    static func read() -> ActiveState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.activeFile)) else { return nil }
        return try? JSONDecoder().decode(ActiveState.self, from: data)
    }
    static func write(_ s: ActiveState) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.activeFile), options: .atomic)
    }
}
