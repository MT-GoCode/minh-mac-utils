import Foundation

/// Results of a `testcall` file under this reserved key, which can't collide with a real call id
/// (those are stringified Ints).
let kTestKey = "test"

/// What the CLI asks for, as it travels through a marker.
struct AddRequest: Codable {
    var name: String
    var destination: String
    var schedule: String
}

/// A queued removal. `requestedAt` is stamped by the DAEMON, never by the CLI, so the delay can't be
/// backdated by writing an old timestamp into a marker.
struct PendingRemoval: Codable {
    var callID: Int
    var name: String
    var requestedAt: Double
    var applyAt: Double
}

/// Root-owned daemon state, kept separate from `calls.json` so a tick's bookkeeping can never race
/// with a config change.
struct DaemonState: Codable {
    var lastFired: [String: Double]      // callID -> the occurrence epoch we already dialled
    var pendingRemovals: [PendingRemoval]
    var lastResult: [String: String]     // callID -> human outcome of the most recent dial
    var lastResultAt: [String: Double]

    init(lastFired: [String: Double] = [:], pendingRemovals: [PendingRemoval] = [],
         lastResult: [String: String] = [:], lastResultAt: [String: Double] = [:]) {
        self.lastFired = lastFired
        self.pendingRemovals = pendingRemovals
        self.lastResult = lastResult
        self.lastResultAt = lastResultAt
    }

    // Lenient: a missing key falls back to empty so the file can gain fields without breaking installs.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastFired        = (try? c.decode([String: Double].self, forKey: .lastFired)) ?? [:]
        pendingRemovals  = (try? c.decode([PendingRemoval].self, forKey: .pendingRemovals)) ?? []
        lastResult       = (try? c.decode([String: String].self, forKey: .lastResult)) ?? [:]
        lastResultAt     = (try? c.decode([String: Double].self, forKey: .lastResultAt)) ?? [:]
    }

    static func load() -> DaemonState { loadJSON(Paths.stateFile) ?? DaemonState() }
    func save() { saveJSON(self, to: Paths.stateFile) }
}

enum Daemon {

    static func run() -> Never {
        try? FileManager.default.createDirectory(atPath: Paths.logsDir, withIntermediateDirectories: true)
        logStderr("forcecalls daemon up (pid \(getpid()))")
        while true {
            tick()
            Thread.sleep(forTimeInterval: max(1, Settings.load().pollSeconds))
        }
    }

    static func tick() {
        let s = Settings.load()
        let now = nowEpoch()
        var calls = CallStore.load()
        var st = DaemonState.load()
        var callsDirty = false

        // 1. Replay the inbox in the order the requests were made.
        if let euid = s.enforcedUID() {
            for m in MarkerIO.drainAll(enforcedUID: euid) {
                switch m.kind {
                case "add":
                    // Tightening lands immediately — only loosening is delay-gated.
                    guard let d = m.body.data(using: .utf8),
                          let req = try? JSONDecoder().decode(AddRequest.self, from: d) else {
                        logStderr("add: unparseable marker — ignored"); continue
                    }
                    // Re-validate daemon-side: the CLI already checked, but the inbox is user-writable
                    // and a hand-rolled marker must not be able to install a malformed schedule.
                    guard let spec = try? ScheduleSpec.parse(req.schedule),
                          let dest = try? validateDestination(req.destination),
                          !req.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                        logStderr("add: rejected invalid request '\(req.name)'"); continue
                    }
                    guard !calls.contains(where: { $0.name == req.name }) else {
                        logStderr("add: '\(req.name)' already exists — ignored"); continue
                    }
                    calls.append(ForcedCall(id: CallStore.nextID(calls), name: req.name,
                                            destination: dest, schedule: spec))
                    callsDirty = true
                    logStderr("add: '\(req.name)' \(dest) \(spec.raw)")

                case "remove":
                    guard let id = Int(m.body), let call = calls.first(where: { $0.id == id }) else {
                        logStderr("remove: no such call id '\(m.body)' — ignored"); continue
                    }
                    guard !st.pendingRemovals.contains(where: { $0.callID == id }) else {
                        // A repeat request must not shorten the wait; leave the original standing.
                        logStderr("remove: '\(call.name)' already queued — leaving the original deadline")
                        continue
                    }
                    st.pendingRemovals.append(PendingRemoval(callID: id, name: call.name,
                                                            requestedAt: now, applyAt: now + s.removeDelaySec))
                    logStderr("remove: '\(call.name)' queued — lands in \(fmtLeft(s.removeDelaySec))")

                case "testcall":
                    // Deliberately the SAME call path as a scheduled fire — same leg order, same
                    // LaML, same endpoint — so a passing test means the real thing works. It just
                    // skips the schedule and isn't recorded against any forced call.
                    guard let dest = try? validateDestination(m.body) else {
                        logStderr("testcall: rejected invalid destination '\(m.body)'"); continue
                    }
                    guard let creds = Creds.load() else {
                        st.lastResult[kTestKey] = "FAILED no credentials — reinstall to set them"
                        st.lastResultAt[kTestKey] = nowEpoch()
                        logStderr("testcall: no credentials at \(Paths.credsFile)")
                        continue
                    }
                    let tr = SignalWire.placeCall(creds: creds, destination: dest)
                    st.lastResult[kTestKey] = (tr.ok ? "ok " : "FAILED ") + tr.detail
                    st.lastResultAt[kTestKey] = nowEpoch()
                    logStderr("testcall -> \(dest): \(tr.ok ? "ok" : "FAILED") \(tr.detail)")

                case "abort":
                    if st.pendingRemovals.isEmpty {
                        logStderr("abort: nothing queued")
                    } else {
                        logStderr("abort: dropped \(st.pendingRemovals.count) pending removal(s)")
                        st.pendingRemovals.removeAll()
                    }

                default: break
                }
            }
        }

        // 2. Land any removal whose wait is over.
        let due = st.pendingRemovals.filter { now >= $0.applyAt }
        for p in due {
            if calls.contains(where: { $0.id == p.callID }) {
                calls.removeAll { $0.id == p.callID }
                callsDirty = true
                logStderr("removal APPLIED: '\(p.name)'")
            }
            st.lastFired.removeValue(forKey: String(p.callID))
            st.lastResult.removeValue(forKey: String(p.callID))
            st.lastResultAt.removeValue(forKey: String(p.callID))
        }
        st.pendingRemovals.removeAll { now >= $0.applyAt }

        if callsDirty { CallStore.save(calls) }

        // 3. Fire any occurrence that is due and hasn't been dialled.
        for call in calls {
            guard let occ = call.schedule.mostRecentOccurrence(now: Date(timeIntervalSince1970: now)) else { continue }
            guard now - occ <= s.graceSeconds else { continue }
            let key = String(call.id)
            if st.lastFired[key] == occ { continue }

            // Stamp BEFORE anything else. If the process dies mid-request, the worst case is one
            // missed call — never a loop that redials your mother every five seconds. Stamping also
            // applies to a presence skip: a call declined at 20:45 must not fire at 03:00 because
            // you got up for a glass of water.
            st.lastFired[key] = occ
            st.save()

            // Don't ring someone if you're not there to talk to them.
            let presence = Presence.check(enforcedUser: s.enforcedUser, maxIdle: s.requireActiveSeconds)
            guard presence.present else {
                st.lastResult[key] = "skipped — \(presence.reason)"
                st.lastResultAt[key] = nowEpoch()
                logStderr("skip '\(call.name)': \(presence.reason)")
                st.save()
                continue
            }

            guard let creds = Creds.load() else {
                st.lastResult[key] = "FAILED no credentials — reinstall to set them"
                st.lastResultAt[key] = nowEpoch()
                logStderr("fire '\(call.name)': no credentials at \(Paths.credsFile)")
                st.save()
                continue
            }
            let r = SignalWire.placeCall(creds: creds, destination: call.destination)
            st.lastResult[key] = (r.ok ? "ok " : "FAILED ") + r.detail
            st.lastResultAt[key] = nowEpoch()
            logStderr("fire '\(call.name)' -> \(call.destination): \(r.ok ? "ok" : "FAILED") \(r.detail)")
        }

        st.save()
    }
}
