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

    // MARK: - state (root-owned)

    struct Invocation: Codable { var name: String; var requestedAt: Double; var applyAt: Double; var targetAt: Double }
    struct AddPending: Codable { var preset: SnoozePreset; var requestedAt: Double; var applyAt: Double }
    struct SPState: Codable {
        var invocation: Invocation? = nil     // ONE in-flight invocation (a single snooze slot)
        var adds: [String: AddPending] = [:]  // name → pending delayed-add
        static func load() -> SPState {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.snoozePresetsStateFile)),
                  let s = try? JSONDecoder().decode(SPState.self, from: d) else { return SPState() }
            return s
        }
        func save() {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            if let d = try? e.encode(self) { try? d.write(to: URL(fileURLWithPath: Paths.snoozePresetsStateFile), options: .atomic) }
        }
    }

    struct Status: Codable {
        var invocationName: String?
        var invocationApplyAtEpoch: Double?
        var invocationTargetEpoch: Double?
        var pendingAdds: [AddView] = []
    }
    struct AddView: Codable { var name: String; var applyAtEpoch: Double }

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

    // MARK: - daemon tick

    @discardableResult
    static func tick(now: Double, enforcedUID: uid_t?, addDelaySec: Double) -> Status {
        var st = SPState.load()

        if let euid = enforcedUID {
            // invoke: start the single in-flight invocation (freeze the resolved target NOW).
            if let data = MarkerIO.consume(Paths.spInvokeMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if st.invocation == nil, let p = find(name), let target = try? TimeSpec.parseTarget(p.spec) {
                    st.invocation = Invocation(name: name, requestedAt: now,
                                               applyAt: now + Bounds.clamp(p.invokeDelaySec, Bounds.snoozePresetInvokeDelay),
                                               targetAt: target.timeIntervalSince1970)
                    st.save()
                }   // else: unknown preset, or one already in flight (idempotent — ignore)
            }
            if MarkerIO.consumeFlag(Paths.spInvokeAbort, enforcedUID: euid) { st.invocation = nil; st.save() }
            // remove (immediate, tightening): drop a preset.
            if let data = MarkerIO.consume(Paths.spRemoveMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                applyRemove(name: name); st.adds.removeValue(forKey: name); st.save()
            }
            // delayed-add abort.
            if let data = MarkerIO.consume(Paths.spAddAbort, enforcedUID: euid) {
                let arg = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if arg == "--all" { st.adds.removeAll() } else { st.adds.removeValue(forKey: arg) }
                st.save()
            }
            // delayed-add: queue a new preset.
            if let data = MarkerIO.consume(Paths.spAddMarker, enforcedUID: euid),
               let p = try? JSONDecoder().decode(SnoozePreset.self, from: data), rejectReason(p) == nil {
                st.adds[p.name] = AddPending(preset: p, requestedAt: now, applyAt: now + addDelaySec)
                st.save()
            }
        }

        // apply the invocation when due: stand down until the frozen target (if still future), then re-arm.
        if let inv = st.invocation, now >= inv.applyAt {
            if inv.targetAt > now {
                // Cap the stand-down at the snooze ceiling, same as the manual `snooze` command — an
                // "until" preset invoked in the small hours must not stand down for ~24h. [review]
                let capped = min(inv.targetAt, now + Bounds.snoozeDurationMax)
                try? SnoozeStore.set(Date(timeIntervalSince1970: capped))
                if !ArmStore.isArmed() { try? ArmStore.set(true) }   // snooze ⇒ stand down THEN resume
            }
            st.invocation = nil; st.save()
        }
        // apply pending adds when due.
        var changed = false
        for (name, a) in st.adds where now >= a.applyAt {
            if rejectReason(a.preset) == nil { applyAdd(a.preset) }
            st.adds.removeValue(forKey: name); changed = true
        }
        if changed { st.save() }

        return Status(invocationName: st.invocation?.name,
                      invocationApplyAtEpoch: st.invocation?.applyAt,
                      invocationTargetEpoch: st.invocation?.targetAt,
                      pendingAdds: st.adds.values.sorted { $0.preset.name < $1.preset.name }
                        .map { AddView(name: $0.preset.name, applyAtEpoch: $0.applyAt) })
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
