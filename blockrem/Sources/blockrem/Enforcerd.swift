import Foundation
import MacUtilsCore

/// The root daemon — sole owner of the schedule and the published active-state. Each tick it:
///   1. prunes onetime alarms whose window has fully passed,
///   2. computes the current block (honoring snooze) and publishes active.json,
///   3. runs a watchdog that re-bootstraps / kickstarts the GUI agent if the user unloaded or
///      killed it (KeepAlive handles plain crashes; bootout needs the re-bootstrap).
/// The schedule is user-owned (set/delete/snooze run without sudo) — root's job is purely to keep
/// the overlay alive: the app/daemon/plists are root-owned, and this system-domain daemon revives the
/// GUI agent if the user kills or boots it out (the daemon can't draw into a user session itself,
/// which is why the watchdog matters). So you can't quit the overlay or uninstall without sudo.
final class Enforcer {
    private var settings = Settings.load()
    private var lastWatchdog = Date.distantPast
    private static let watchdogSeconds = 5.0

    /// Memory-authoritative first-on latches (alarm id → fired epoch). Merged two-way with the
    /// on-disk `lastFiredEpoch` each tick: memory survives a silently failed save (which would
    /// otherwise refire every second — a rolling block outliving the 1h cap) and a CLI write that
    /// clobbered the latch; disk survives a daemon restart.
    private var fired: [Int: Double] = [:]

    func run() {
        if geteuid() != 0 { log("WARNING: not running as root — the watchdog (relaunch agent) will fail") }
        log("blockrem enforcerd starting (uid \(getuid()))")
        while true {
            autoreleasepool { tick() }
            Thread.sleep(forTimeInterval: max(settings.pollSeconds, 0.25))
        }
    }

    private func tick() {
        settings = Settings.load()
        let now = Date()

        // 1. Prune fully-past onetime alarms.
        var alarms = ScheduleStore.load()
        let pruned = alarms.filter { !$0.isExpiredOnetime(now: now) }
        if pruned.count != alarms.count { saveSchedule(pruned); alarms = pruned }
        // Drop latches of deleted alarms HERE, before the console/snooze early-returns — else
        // an id reused during a long snooze would inherit the old latch for the whole snooze.
        let scheduleIDs = Set(alarms.map { $0.id })
        fired = fired.filter { scheduleIDs.contains($0.key) }

        // Only guard the configured console session. If someone else is at the console (or nobody),
        // publish "inactive" and don't fight for an agent that isn't ours.
        guard let uid = consoleUID(), let target = settings.enforcedUID(), uid == target else {
            ActiveStore.write(.inactive())
            return
        }

        // 2. Snooze suppresses every block until its instant, then auto-clears.
        if let sn = SnoozeStore.until() {
            if now < sn {
                ActiveStore.write(.inactive(snoozeUntil: sn.timeIntervalSince1970))
                watchdog(uid: uid, now: now)
                return
            }
            try? SnoozeStore.set(nil)   // expired → clear
        }

        // 2.5 First-on alarms. Placement is load-bearing: this must sit AFTER the snooze
        // early-return above (snooze gates the trigger — deferred-fire semantics) and BEFORE
        // activeBlock() (the merged latch is what activeEnd reads).
        var mutated = false
        (fired, alarms, mutated) = mergeFirstOnLatches(fired: fired, alarms: alarms)
        let inUse = sessionInUse(SessionStore.read(), now: now.timeIntervalSince1970)
        for i in alarms.indices
        where firstOnShouldFire(alarms[i], now: now, inUse: inUse, snoozedUntil: nil) {
            let t = now.timeIntervalSince1970
            fired[alarms[i].id] = t
            alarms[i].lastFiredEpoch = t
            mutated = true
            log("first-on [\(alarms[i].id)] \"\(alarms[i].label)\" fired")
        }
        if mutated { saveSchedule(alarms) }

        // 3. Compute + publish the winning block.
        if let blk = activeBlock(alarms, now: now) {
            ActiveStore.write(ActiveState(updatedEpoch: now.timeIntervalSince1970, active: true,
                                          label: blk.label, endsEpoch: blk.endsEpoch, snoozeUntilEpoch: nil))
        } else {
            ActiveStore.write(.inactive())
        }

        watchdog(uid: uid, now: now)
    }

    /// Save the schedule and hand ownership back to the enforced user — a root-atomic write
    /// leaves the file root-owned in the user's dataDir, breaking the documented ownership story.
    private func saveSchedule(_ alarms: [Alarm]) {
        ScheduleStore.save(alarms)
        if let uid = settings.enforcedUID() {
            chown(Paths.scheduleFile, uid, gid_t(bitPattern: ~0))   // gid -1 = leave unchanged
        }
    }

    /// Keep the GUI agent alive. KeepAlive restarts a crashed/killed process on its own, but a user
    /// can `launchctl bootout gui/<uid>/…agent` WITHOUT sudo, which unloads the job entirely — so we
    /// re-bootstrap (a no-op when already loaded) and kickstart if no agent process is running.
    private func watchdog(uid: uid_t, now: Date) {
        guard now.timeIntervalSince(lastWatchdog) >= Self.watchdogSeconds else { return }
        lastWatchdog = now
        Proc.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", Paths.agentPlist])  // undo a bootout; harmless if loaded
        let running = !Proc.capture("/usr/bin/pgrep", ["-fu", "\(uid)", "Blockrem.app/Contents/MacOS/blockrem"])
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !running {
            log("agent not running → kickstart gui/\(uid)/\(Paths.agentLabel)")
            Proc.run("/bin/launchctl", ["kickstart", "gui/\(uid)/\(Paths.agentLabel)"])
        }
    }

    private func log(_ s: String) { logStderr(s) }
}
