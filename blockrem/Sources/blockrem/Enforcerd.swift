import Foundation

/// The root daemon — sole owner of the schedule and the published active-state. Each tick it:
///   1. prunes onetime alarms whose window has fully passed,
///   2. computes the current block (honoring snooze) and publishes active.json,
///   3. runs a watchdog that re-bootstraps / kickstarts the GUI agent if the user unloaded or
///      killed it (KeepAlive handles plain crashes; bootout needs the re-bootstrap).
/// The schedule lives root-owned, so a non-root user can't add/remove/relabel a block — only
/// `sudo blockrem …` can. The blocker window itself runs in the user's GUI agent (the daemon
/// can't draw into a user session), which is why the watchdog matters.
final class Enforcer {
    private var settings = Settings.load()
    private var lastWatchdog = Date.distantPast
    private static let watchdogSeconds = 5.0

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
        if pruned.count != alarms.count { ScheduleStore.save(pruned); alarms = pruned }

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

        // 3. Compute + publish the winning block.
        if let blk = activeBlock(alarms, now: now) {
            ActiveStore.write(ActiveState(updatedEpoch: now.timeIntervalSince1970, active: true,
                                          label: blk.label, endsEpoch: blk.endsEpoch, snoozeUntilEpoch: nil))
        } else {
            ActiveStore.write(.inactive())
        }

        watchdog(uid: uid, now: now)
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

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
    }
}
