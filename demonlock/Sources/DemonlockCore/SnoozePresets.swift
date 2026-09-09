import Foundation

/// A named snooze shortcut: `spec` is a "for <dur>" | "until <[day]HHMM>" TimeSpec, and `invokeDelaySec`
/// is how long AFTER you invoke it before the snooze actually lands (the commitment device). Replaces the
/// old `snoozetonight` / `igotshitdueatmidnight` commands with a configurable table.
struct SnoozePreset: Codable, Equatable {
    var name: String
    var spec: String
    var invokeDelaySec: Double
}

/// Effective preset list (defaults + user − removed), a SINGLE in-flight invocation (one snooze slot,
/// per Minh), and a name-keyed registry of pending delayed-adds. Daemon tick applies both.
enum SnoozePresets {
    /// Defaults reproduce the retired commands: "tonight" ≈ snoozetonight (05:00, 1h delay); "midnight"
    /// ≈ igotshitdueatmidnight (12:05 AM, 1.5h delay).
    static let defaults: [SnoozePreset] = [
        SnoozePreset(name: "tonight",  spec: "until 0500", invokeDelaySec: 1.0 * 3600),
        SnoozePreset(name: "midnight", spec: "until 0005", invokeDelaySec: 1.5 * 3600),
    ]

    static func effective(_ s: Settings = .load()) -> [SnoozePreset] {
        var byName: [String: SnoozePreset] = [:]
        for p in defaults { byName[p.name] = p }
        for p in s.snoozePresetsUser { byName[p.name] = p }
        for n in s.snoozePresetsRemoved { byName.removeValue(forKey: n) }
        return byName.values.sorted { $0.name < $1.name }
    }
    static func find(_ name: String, _ s: Settings = .load()) -> SnoozePreset? { effective(s).first { $0.name == name } }

    // MARK: - state (root-owned; composite file: TWO queues + migrated-legacy fields)

    struct Invocation: Codable { var name: String; var requestedAt: Double; var applyAt: Double; var targetAt: Double }
    struct AddPending: Codable { var preset: SnoozePreset; var requestedAt: Double; var applyAt: Double }

    /// snooze-presets.json container. Each DelayQueue owns a named sub-object; legacy fields are
    /// consumed by the first load and nil'd on save. COMPOSITE-FILE CONTRACT: every store closure
    /// re-loads the file and writes back only its own field — never a snapshot held across a
    /// sibling's save (which would silently erase the other queue's pending rows).
    struct SPFile: Codable {
        var invocation: Invocation? = nil            // legacy single slot
        var adds: [String: AddPending]? = nil        // legacy name-keyed map
        var invokeQ: DelayQueue.QState? = nil
        var addsQ: DelayQueue.QState? = nil
        static func load() -> SPFile { loadJSON(Paths.snoozePresetsStateFile) ?? SPFile() }
        func save() { saveJSON(self, to: Paths.snoozePresetsStateFile) }
    }

    private static func subStore(read: @escaping (SPFile) -> DelayQueue.QState?,
                                 migrate: @escaping (SPFile) -> DelayQueue.QState?,
                                 write: @escaping (inout SPFile, DelayQueue.QState) -> Void) -> DelayQueue.QStateStore {
        DelayQueue.QStateStore(
            load: {
                let f = SPFile.load()
                var st = read(f) ?? migrate(f) ?? DelayQueue.QState()
                st.fixSeq()
                return st
            },
            save: { st in
                var f = SPFile.load()                 // fresh — the sibling may have saved meanwhile
                write(&f, st)
                f.save()
            })
    }

    /// The invoke payload: name + the resolved target FROZEN at queue time (spec do-not-unify:
    /// "payload carries resolved targetAt, computed at queue time by app code" — main's semantics;
    /// deriving from the preset at landing would let a delayed-add that edits the preset retarget a
    /// pending invocation). The daemon can't trust a user-written targetAt blindly: queue-time
    /// validation recomputes it from the CURRENT preset spec with ±15m clock tolerance, so a forged
    /// far-future target is rejected while a legit CLI resolve seconds earlier passes. Re-invoking
    /// resolves a fresh targetAt ⇒ different payload ⇒ replace + full delay reset (stricter; the
    /// spec's requeue rule for different payloads).
    struct InvokePayload: Codable, Equatable { var name: String; var targetAt: Double }

    /// The single in-flight invocation (constant key "invocation" ⇒ one slot).
    static func invokeQueue() -> DelayQueue {
        DelayQueue(kind: "snooze-invoke",
                   store: subStore(
                       read: { $0.invokeQ },
                       migrate: { f in
                           guard let inv = f.invocation else { return nil }
                           let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                           guard let d = try? enc.encode(InvokePayload(name: inv.name, targetAt: inv.targetAt)),
                                 let json = String(data: d, encoding: .utf8) else { return DelayQueue.QState() }
                           return DelayQueue.QState(pending: ["invocation": .init(payload: json,
                                    requestedAt: inv.requestedAt, applyAt: inv.applyAt, seq: 0)],
                                                    nextSeq: 1, lastAppliedAt: nil, recent: [])
                       },
                       write: { f, st in f.invokeQ = st; f.invocation = nil }),
                   requestMarker: Paths.spInvokeMarker, abortMarker: Paths.spInvokeAbort,
                   onFailure: .drop, payloadIsJSON: true, auditLog: Paths.queueAuditLog)
    }

    static let invokeTargetToleranceSec = 900.0

    static func decodeInvoke(_ line: String) -> InvokePayload? {
        try? JSONDecoder().decode(InvokePayload.self, from: Data(line.utf8))
    }

    static func addsQueue() -> DelayQueue {
        DelayQueue(kind: "snooze-preset-add",
                   store: subStore(
                       read: { $0.addsQ },
                       migrate: { f in
                           guard let adds = f.adds else { return nil }
                           guard !adds.isEmpty else { return DelayQueue.QState() }
                           let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                           var st = DelayQueue.QState()
                           for (name, a) in adds.sorted(by: { $0.value.requestedAt < $1.value.requestedAt }) {
                               guard let d = try? enc.encode(a.preset), let json = String(data: d, encoding: .utf8) else { continue }
                               st.pending[name] = .init(payload: json, requestedAt: a.requestedAt, applyAt: a.applyAt, seq: st.nextSeq)
                               st.nextSeq += 1
                           }
                           return st
                       },
                       write: { f, st in f.addsQ = st; f.adds = nil }),
                   requestMarker: Paths.spAddMarker, abortMarker: Paths.spAddAbort,
                   onFailure: .drop, payloadIsJSON: true, auditLog: Paths.queueAuditLog)
    }

    // MARK: - validation

    static func rejectReason(_ p: SnoozePreset) -> String? {
        let n = p.name
        guard (1...24).contains(n.count), n.allSatisfy({ ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" }) else {
            return "name must be 1–24 chars of [a-z0-9-]"
        }
        guard let target = try? TimeSpec.parseTarget(p.spec) else {
            return "spec must be \"for <dur>\" or \"until <[day]HHMM>\" (e.g. \"for 90m\", \"until 0500\")"
        }
        // Cap the resulting stand-down at the snooze ceiling (mainly guards "for <dur>"; "until" is a
        // wall-clock time, at most ~a day out — also capped).
        if target.timeIntervalSinceNow > Bounds.snoozeDurationMax {
            return "that snooze would exceed the \(Int(Bounds.snoozeDurationMax/3600))h ceiling"
        }
        if !Bounds.snoozePresetInvokeDelay.contains(p.invokeDelaySec) {
            return "invoke delay must be \(Int(Bounds.snoozePresetInvokeDelay.lowerBound/3600))–\(Int(Bounds.snoozePresetInvokeDelay.upperBound/3600))h"
        }
        return nil
    }

    // MARK: - daemon tick (calls consumeMarkers then applyDue on BOTH queues itself)

    static func tick(now: Double, enforcedUID: uid_t?, addDelaySec: Double)
        -> (invoke: DelayQueue.QStatus, adds: DelayQueue.QStatus) {
        // Immediate remove (tightening): drop the preset now, and kill any same-name pending
        // delayed-add directly in the root-owned queue store (consistent with safe-apps/lockbox;
        // works for old CLIs too).
        if let euid = enforcedUID, let name = MarkerIO.consumeLast(Paths.spRemoveMarker, enforcedUID: euid) {
            applyRemove(name: name)
            rootCancelPendingAdd(name: name)
        }

        let invQ = invokeQueue(), addQ = addsQueue()
        let settings = Settings.load()
        invQ.consumeMarkers(now: now, enforcedUID: enforcedUID,
                            delaySec: { line in Bounds.clamp(decodeInvoke(line).flatMap { find($0.name, settings) }?.invokeDelaySec
                                                             ?? Bounds.snoozePresetInvokeDelay.lowerBound,
                                                             Bounds.snoozePresetInvokeDelay) },
                            key: { line in decodeInvoke(line).flatMap { find($0.name, settings) } != nil ? "invocation" : nil },
                            validate: { line in
                                // QUEUE-time only: the frozen targetAt must match what the CURRENT
                                // preset spec resolves to right now (±tolerance) — rejects a forged
                                // target while accepting the CLI's seconds-earlier resolve.
                                guard let p = decodeInvoke(line), let preset = find(p.name, settings),
                                      let expect = try? TimeSpec.parseTarget(preset.spec, from: Date(timeIntervalSince1970: now))
                                else { return false }
                                // ONE-sided: only a target FURTHER out than the spec resolves now is
                                // forgery. An earlier one (daemon was down; an "until" rolled past)
                                // is harmless — shorter snooze, or skipped at apply if already past.
                                return p.targetAt - expect.timeIntervalSince1970 <= invokeTargetToleranceSec
                            })
        addQ.consumeMarkers(now: now, enforcedUID: enforcedUID,
                            delaySec: { _ in addDelaySec },
                            key: { line in (try? JSONDecoder().decode(SnoozePreset.self, from: Data(line.utf8)))?.name },
                            validate: { line in
                                (try? JSONDecoder().decode(SnoozePreset.self, from: Data(line.utf8)))
                                    .map { rejectReason($0) == nil } ?? false
                            })

        // LANDING validate is looser (decodable + preset still exists): the tolerance check is
        // queue-time only — 36h later "targetAt ≈ resolve-now" would always fail. The frozen
        // targetAt is honored verbatim, capped at the ceiling.
        let invStatus = invQ.applyDue(now: now, validate: { line in
            decodeInvoke(line).flatMap { find($0.name, settings) } != nil
        }) { due in
            Dictionary(uniqueKeysWithValues: due.map { d in
                guard let p = decodeInvoke(d.payload), find(p.name, settings) != nil
                else { return (d.key, (false, String?.some("preset vanished or payload undecodable"))) }
                if p.targetAt > now {
                    // Cap the stand-down at the snooze ceiling, same as the manual `snooze` command.
                    let capped = min(p.targetAt, now + Bounds.snoozeDurationMax)
                    try? SnoozeStore.set(Date(timeIntervalSince1970: capped))
                    if !ArmStore.isArmed() { try? ArmStore.set(true) }   // snooze ⇒ stand down THEN resume
                }
                return (d.key, (true, nil))
            })
        }
        let addStatus = addQ.applyDue(now: now,
                                      validate: { line in
                                          (try? JSONDecoder().decode(SnoozePreset.self, from: Data(line.utf8)))
                                              .map { rejectReason($0) == nil } ?? false
                                      }) { due in
            Dictionary(uniqueKeysWithValues: due.map { d in
                guard let p = try? JSONDecoder().decode(SnoozePreset.self, from: Data(d.payload.utf8))
                else { return (d.key, (false, String?.some("undecodable"))) }
                applyAdd(p)
                return (d.key, (true, nil))
            })
        }
        return (invStatus, addStatus)
    }

    /// ROOT-only (immediate `add` CLI path): cancel a pending delayed-add directly in the root-owned
    /// state file — root cannot route through the user-owned inbox (the daemon's owner check would
    /// reject a root-written marker).
    static func rootCancelPendingAdd(name: String) {
        addsQueue().rootCancel(keys: [name], now: nowEpoch(), reason: "superseded by immediate add/remove")
        var f = SPFile.load()
        if f.adds?.removeValue(forKey: name) != nil { f.save() }   // pre-migration legacy row
    }

    static func applyAdd(_ p: SnoozePreset) {
        Settings.mutate { s in
            s.snoozePresetsUser.removeAll { $0.name == p.name }
            s.snoozePresetsUser.append(p)
            s.snoozePresetsRemoved.removeAll { $0 == p.name }
        }
    }


    static func applyRemove(name: String) {
        Settings.mutate { s in
            if s.snoozePresetsUser.contains(where: { $0.name == name }) {
                s.snoozePresetsUser.removeAll { $0.name == name }
            } else if defaults.contains(where: { $0.name == name }) {
                if !s.snoozePresetsRemoved.contains(name) { s.snoozePresetsRemoved.append(name) }
            }
        }
    }
}
