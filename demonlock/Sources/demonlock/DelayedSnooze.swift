import Foundation

/// "I got shit due at midnight" — a self-serve, DELAY-GATED snooze. You request it (no sudo); the
/// daemon stamps the time with its own clock, waits 1.5h, then stands enforcement down until 12:05 AM
/// tonight and re-arms at expiry (exactly like `snoozetonight`, just delayed + no-sudo). The 1.5h wait
/// is the commitment device: impulse-you can't escape *now* — you eat the lockout until the delay is
/// up — but a genuine late deadline still gets relief, and it kicks in even mid-lockout (the snooze is
/// written at the top of the tick, so that same tick stands you down and clears the countdown).
///
/// Same trust split as the release valve: root-owned lifecycle state; a marker in the user-owned
/// inbox; the daemon stamps the real request time, so the delay can't be backdated. No timers — all
/// disk state, driven by the enforcer tick.

struct DelayedSnoozeState: Codable {
    var requestedAt: Double? = nil    // daemon clock at acceptance (not backdatable)
    var applyAt: Double? = nil        // requestedAt + 1.5h (frozen at request time)
    var targetAt: Double? = nil       // the 12:05 AM to snooze until — FROZEN at request time (see below)
    var lastAppliedAt: Double? = nil  // when a snooze last landed (drives the "active" notification)

    var isIdle: Bool { requestedAt == nil }

    static func load() -> DelayedSnoozeState {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.delayedSnoozeFile)),
              let s = try? JSONDecoder().decode(DelayedSnoozeState.self, from: d) else { return DelayedSnoozeState() }
        return s
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(self) { try? d.write(to: URL(fileURLWithPath: Paths.delayedSnoozeFile), options: .atomic) }
    }
}

// Published status (status CLI + agent panel + apply notification).
struct DelayedSnoozeStatus: Codable {
    var pending: Bool
    var applyAtEpoch: Double?
    var targetEpoch: Double?      // the frozen 12:05 AM this will snooze until
    var lastAppliedEpoch: Double?
}

enum DelayedSnooze {
    static let delaySec: Double = 90 * 60   // 1.5h
    static let targetHHMM = "0005"          // 12:05 AM

    /// Drive the request one tick: consume markers (abort first, then request), and once the 1.5h is
    /// up write the snooze (until the next 12:05 AM) + ensure armed so it resumes. Returns the status
    /// to publish. Runs at the top of the tick so an applied snooze stands the user down this tick.
    static func tick(now: Double) -> DelayedSnoozeStatus {
        let fm = FileManager.default
        var st = DelayedSnoozeState.load()

        if fm.fileExists(atPath: Paths.dsnAbortMarker) {
            try? fm.removeItem(atPath: Paths.dsnAbortMarker)
            if !st.isIdle { st = DelayedSnoozeState(lastAppliedAt: st.lastAppliedAt); st.save() }
        }
        if fm.fileExists(atPath: Paths.dsnRequestMarker) {
            try? fm.removeItem(atPath: Paths.dsnRequestMarker)
            if st.isIdle {
                // Freeze BOTH the apply time AND the 12:05 AM target at request time. Freezing the
                // target is what fails the loophole closed: request too late (within 1.5h of midnight)
                // and by apply time the target is already past → no snooze, rather than rolling to the
                // NEXT midnight and handing out a ~24h stand-down.
                st.requestedAt = now; st.applyAt = now + delaySec
                st.targetAt = nextHHMM(targetHHMM).timeIntervalSince1970
                st.save()
                log("igotshitdueatmidnight: request accepted (snooze in \(Int(delaySec/60))m, until 12:05 AM)")
            }
        }
        if let applyAt = st.applyAt, now >= applyAt {
            let lastApplied = st.lastAppliedAt
            if let t = st.targetAt, t > now {
                try? SnoozeStore.set(Date(timeIntervalSince1970: t))
                if !ArmStore.isArmed() { try? ArmStore.set(true) }   // snooze ⇒ stand down THEN resume
                st = DelayedSnoozeState(lastAppliedAt: now)
                log("igotshitdueatmidnight: SNOOZE until 12:05 AM")
            } else {
                st = DelayedSnoozeState(lastAppliedAt: lastApplied)   // target already passed → no relief
                log("igotshitdueatmidnight: requested too late — 12:05 AM already passed, no snooze")
            }
            st.save()
        }

        return DelayedSnoozeStatus(pending: !st.isIdle, applyAtEpoch: st.applyAt,
                                   targetEpoch: st.targetAt, lastAppliedEpoch: st.lastAppliedAt)
    }

    private static func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
    }
}
