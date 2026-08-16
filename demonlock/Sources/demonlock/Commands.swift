import Foundation

// MARK: - Gate

/// Privileged commands require real root (run via sudo). No osascript-admin path here — the
/// only escalation affordance is the agent's Disarm button.
func requireRoot(_ cmd: String) {
    if geteuid() != 0 {
        FileHandle.standardError.write(Data("demonlock \(cmd): requires sudo — run `sudo demonlock \(cmd) …`\n".utf8))
        exit(1)
    }
}

private func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

// MARK: - shared CLI contract for the no-sudo request commands

/// Uniform `--help` / `--status` / `--abort` handling — accepted BARE or `--`-prefixed — shared by
/// every no-sudo request command (release-valve, delaysetpolicy, delayzones, igotshitdueatmidnight).
/// Returns true when it consumed the arg (the caller should `return`); false to fall through to that
/// command's own verb (its request / enqueue / --set-*). Reserving these words as subcommands stops a
/// bare `status`/`help` from being mis-parsed as a payload (the bug that queued "status"/"help").
private func handleRequestFlags(_ first: String?, usage: String, abortMarker: String,
                                abortNote: String = "", status: () -> Void) -> Bool {
    switch first {
    case "--help", "help", "-h":
        print(usage)
    case "--status", "status":
        status()
    case "--abort", "abort":
        dropDelayMarker(abortMarker)
        print("✓ abort sent — cancels a pending request on the next tick.")
        if !abortNote.isEmpty { print("  " + abortNote) }
    default:
        return false
    }
    return true
}

/// `release-valve --status`: print the valve's published state (or a hint if the daemon isn't up).
private func printReleaseValveStatusCLI() {
    if let rv = StateStore.read()?.releaseValve { printReleaseValve(rv) }
    else { print("release valve: no state yet — is the enforcer running?") }
}

// MARK: - status (user)

func runStatus() {
    guard let s = StateStore.read() else {
        print("demonlock: no state yet — the enforcer isn't running. Install it and `sudo demonlock arm`.")
        return
    }
    let age = nowEpoch() - s.updatedEpoch
    print("demonlock" + (age > 5 ? "  ⚠️  state is \(Int(age))s stale — enforcer may be stuck" : ""))
    print("  enforced user : \(s.enforcedUser.isEmpty ? "(unset)" : s.enforcedUser)")
    print("  armed         : \(s.armed ? "ARMED" : "DISARMED")")
    print("  phase         : \(s.phase.uppercased())")
    if let v = s.verdict { print("  verdict       : \(v.uppercased())") }
    print("  reason        : \(s.reason)")
    if let ssh = s.sshAddr { print("  \(ssh)") }
    if let dl = s.countdownDeadlineEpoch { print("  countdown     : \(max(0, Int(dl - nowEpoch())))s remaining") }
    if let sn = s.snoozeUntilEpoch {
        let left = max(0, Int(sn - nowEpoch()))
        print("  snooze        : SNOOZED until \(TimeSpec.fmtWhen(sn))  " +
              "(\(left / 3600)h \(left % 3600 / 60)m left — enforcement stood down)")
    }
    print("  policy        : \(s.policyString.isEmpty ? "(none set)" : s.policyString)")
    if let t = s.tree { print("\n  policy evaluation  (✓ true · ✗ false · · unknown):\n" + t.asText(indent: 2)) }
    if !s.health.locationTrail.isEmpty { print("\n  location:\n" + s.health.locationTrail.joined(separator: "\n")) }
    if let rv = s.releaseValve { printReleaseValve(rv) }
    printDelayedStatus("policy", s.delayedPolicy)
    printDelayedStatus("zones", s.delayedZones)
    printDelayedStatus("gate-policy", s.delayedGatePolicy)
    if let sa = s.safeApps, !sa.pending.isEmpty {
        print("  safe-apps     : \(sa.pending.count) pending registration(s) — `demonlock safe-apps show`")
    }
    if let sp = s.snoozePresets {
        if let n = sp.invocationName, let a = sp.invocationApplyAtEpoch {
            print("  snooze-preset : '\(n)' invoked — stands down in \(TimeSpec.fmtLeft(a - nowEpoch()))")
        }
        if !sp.pendingAdds.isEmpty { print("  snooze-preset : \(sp.pendingAdds.count) pending add(s) — `demonlock snooze-preset show`") }
    }
    if let lb = s.lockbox {
        let unlocked = lb.entries.filter(\.unlocked).count
        let unlocking = lb.entries.filter { $0.unlockAtEpoch != nil }.count
        if unlocked > 0 || unlocking > 0 { print("  lockbox       : \(unlocked) unlocked, \(unlocking) unlocking — `demonlock password-lockbox show`") }
    }
}

/// A queued delayed-change line in `status` (only shown when something is pending).
private func printDelayedStatus(_ label: String, _ d: DelayedStatus?) {
    guard let d, d.pending else { return }
    let when = d.applyAtEpoch.map { TimeSpec.fmtWhen($0) } ?? "?"
    let left = d.applyAtEpoch.map { max(0, Int($0 - nowEpoch())) } ?? 0
    print("  delayed \(label) : QUEUED — lands \(when)  (\(left/3600)h \(left%3600/60)m left)")
    if let p = d.payloadPreview { print("                  \(p)") }
}

/// Release-valve section of `status`.
private func printReleaseValve(_ rv: RVStatus) {
    func left(_ e: Double?) -> String { e.map { let s = max(0, Int($0 - nowEpoch())); return "\(s/3600)h\(s%3600/60)m\(s%60)s" } ?? "?" }
    print("\n  release valve : ", terminator: "")
    if !rv.configured { print("not configured (set gate-policy + delay + max-request-duration)"); return }
    switch rv.phase {
    case "granted":  print("GRANTED — admin held, \(left(rv.grantExpiresEpoch)) left, then auto-revoked")
    case "delay":    print("REQUEST pending — in delay, eligible in \(left(rv.eligibleAtEpoch))")
    case "waiting":  print("REQUEST pending — eligible now, gate \(rv.windowOpen ? "OPEN → granting" : "closed, waiting")")
    default:         print("idle (no active request) — `demonlock admin-release-valve request \"<dur>\"`")
    }
    if let d = rv.delaySec, let u = rv.maxRequestDurationSec {
        print("                  delay \(Int(d/60))m · max grant \(Int(u/60))m" + (rv.requestedDurationSec.map { " · requested \(Int($0/60))m" } ?? ""))
    }
    if let wp = rv.gatePolicy { print("                  gate-policy: \(wp)") }
    if let t = rv.windowTree { print("\n  release-valve gate eval  (✓ true · ✗ false · · unknown):\n" + t.asText(indent: 2)) }
}

// MARK: - zones list (user, no GUI)

func runZoneList() {
    let zones = ZoneStore.load()
    if zones.isEmpty {
        print("no zones yet — create them with `demonlock zones` (the map).")
        return
    }
    let w = zones.map { $0.name.count }.max() ?? 0
    print("demonlock zones (\(zones.count)):")
    for z in zones {
        let pad = z.name.padding(toLength: max(w, 4), withPad: " ", startingAt: 0)
        switch z.shape {
        case .circle(let lat, let lon, let r):
            print(String(format: "  • %@   circle · r%.0fm @ %.5f, %.5f", pad, r, lat, lon))
        case .polygon(let pts):
            print("  • \(pad)   polygon · \(pts.count) points")
        }
    }
    print("\nUse a name verbatim in a policy, e.g. LOCATED_IN_ANY([\"\(zones[0].name)\"]).")
}

// MARK: - setpolicy (sudo)

func runSetPolicy(_ policy: String) {
    requireRoot("setpolicy")
    let p = policy.trimmingCharacters(in: .whitespacesAndNewlines)
    if p.isEmpty { fail("✗ no policy given. Example:\n  sudo demonlock setpolicy '(LOCATED_IN_ANY([\"office\"])) AND TIME_IS_ANY([MTWRF0700-2000])'") }
    let zones = ZoneStore.load()
    do {
        try PolicyEngine.validate(p, zones: zones)
    } catch {
        fail("✗ invalid policy: \(error)")
    }
    do { try PolicyStore.write(p) } catch { fail("✗ couldn't write policy: \(error)") }
    print("✓ policy set:\n  \(p)\n\nRun `demonlock status` to see how it evaluates right now.")
}

// MARK: - snooze helper

/// Write the snooze target, ensure ARMED (so the daemon re-arms itself at expiry — no sudo needed
/// then), and confirm. Used by `snooze` and the snooze-preset invocation: a snooze means "stand down,
/// THEN resume," so it implies armed. `arm` resumes NOW (cancels the snooze); `disarm` is indefinite.
private func applySnooze(until target: Date) {
    do { try SnoozeStore.set(target) } catch { fail("✗ couldn't write snooze: \(error)") }
    var armedNote = ""
    if !ArmStore.isArmed() {
        do { try ArmStore.set(true); armedNote = "  (re-armed it for you — don't run `arm`, it'd cancel this)" }
        catch { armedNote = "  ⚠️ couldn't arm — it won't resume; run `sudo demonlock arm`" }
    }
    print("✓ snoozed — stands down until \(TimeSpec.fmtWhen(target.timeIntervalSince1970)), then RE-ARMS automatically.\(armedNote)")
}

// MARK: - snooze (sudo)

private let snoozeMaxHours = Bounds.snoozeDurationMax / 3600   // baked ceiling (Settings.swift)

/// Stand down enforcement until a target time, like `snoozetonight` but flexible: `for <duration>`
/// (d/h/m/s) or `until <[day]HHMM>`. Capped at 18 hours. Reuses `nextHHMM` (shared with
/// `snoozetonight`) and the same `SnoozeStore` the daemon already honors + auto-clears (`arm` also
/// clears it). All times local.
func runSnooze(_ spec: String) {
    requireRoot("snooze")
    let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty {
        fail("✗ usage: sudo demonlock snooze \"for <duration>\" | \"until <[day]HHMM>\"\n" +
             "  e.g. sudo demonlock snooze \"for 90m\"   ·   sudo demonlock snooze \"until 0730\"\n" +
             "  (capped at \(Int(snoozeMaxHours)) hours)")
    }
    let target: Date
    do { target = try TimeSpec.parseTarget(s) } catch { fail("✗ \(error)") }
    let now = Date()
    guard target > now else { fail("✗ that time is already past — nothing to snooze.") }
    guard target <= now.addingTimeInterval(snoozeMaxHours * 3600) else {
        fail("✗ snooze is capped at \(Int(snoozeMaxHours)) hours — that target is further out. Pick a sooner time.")
    }
    applySnooze(until: target)
}

// MARK: - arm / disarm (sudo)

func runArm() {
    // arm TIGHTENS enforcement, so it's allowed WITHOUT admin via a passwordless sudoers grant. The
    // grant targets the go-w, root-owned BUNDLE binary (not the /usr/local/bin wrapper, whose dir could
    // be user-writable → arbitrary root) [review H4]. Run as you → re-exec through `sudo -n`.
    if geteuid() != 0 {
        let rc = Proc.run("/usr/bin/sudo", ["-n", Paths.binaryPath, "arm"])
        if rc != 0 { fail("✗ couldn't arm without admin — the passwordless grant may be missing (reinstall), or run `sudo demonlock arm`.") }
        exit(0)
    }
    do { try ArmStore.set(true) } catch { fail("✗ couldn't arm: \(error)") }
    var note = ""
    if SnoozeStore.until() != nil {            // arming means enforcement is truly live NOW
        try? SnoozeStore.set(nil)
        note = "  (cleared the active snooze)"
    }
    // arm is the panic button: it must ALSO close the release valve (cancel a pending request AND revoke
    // a live grant) + drop admin now, else a request would hand out sudo minutes after you armed, and
    // status would lie. Running as root here, so do it inline. [review M2]
    let user = Settings.load().enforcedUserName()   // login name (resolves a numeric-uid enforcedUser)
    ReleaseValve.hardReset(username: user)
    if let u = user { _ = Admin.revoke(u); note += "  (revoked admin + closed the release valve)" }
    print("✓ ARMED\(note) — after a \(Int(Settings.load().countdownSeconds))s countdown out of policy the enforcer force-closes your GUI apps (sshd/tmux survive). `sudo demonlock disarm` to stop.")
}

/// nosudo (no sudo): drop admin now. arm re-execs through the passwordless sudoers grant, so this does
/// too — it TIGHTENS (revoke only), so it's safe to allow without a password.
func runNoSudo() {
    if geteuid() != 0 {
        let rc = Proc.run("/usr/bin/sudo", ["-n", Paths.binaryPath, "nosudo"])
        if rc != 0 { fail("✗ couldn't drop admin without a password — the passwordless grant may be missing (reinstall), or run `sudo demonlock nosudo`.") }
        exit(0)
    }
    let user = Settings.load().enforcedUserName()
    ReleaseValve.hardReset(username: user)
    if let u = user { _ = Admin.revoke(u) }
    print("✓ admin dropped — release valve closed too. (Already-open login shells may keep cached group membership until you log out.)")
}

func runDisarm() {
    requireRoot("disarm")
    do { try ArmStore.set(false) } catch { fail("✗ couldn't disarm: \(error)") }
    print("✓ DISARMED — everything keeps running and the countdown still shows, but nothing gets killed.")
}

// MARK: - password-lockbox

private let lockboxUsage = """
usage:
  demonlock password-lockbox show               # names, unlock-delay, locked/unlocked, time-left
  demonlock password-lockbox unlock <name>      # after the entry's delay it becomes copyable (no sudo)
  demonlock password-lockbox abort <name>       # cancel a pending unlock / relock now
  demonlock password-lockbox copy <name>        # if unlocked: copy to clipboard (concealed) + relock
  demonlock password-lockbox add --name <n> --delay "<dur>"        # then paste the secret twice (no sudo)
  (this holds arbitrary secrets — NOT the admin password; admin is only via the release valve)
"""

func runLockbox(_ args: [String]) {
    let sub = args.first ?? "show"
    let rest = Array(args.dropFirst())
    switch sub {
    case "show", "list", "status", "--status": lockboxShow()
    case "unlock": lockboxMark(Paths.lbUnlockMarker, rest.first, "unlock")
    case "abort":  lockboxMark(Paths.lbAbortMarker, rest.first, "abort")
    case "copy":   lockboxCopy(rest.first)
    case "add":    lockboxAdd(rest)
    case "help", "--help", "-h": print(lockboxUsage)
    default: fail("✗ unknown subcommand '\(sub)'\n" + lockboxUsage)
    }
}

private func lockboxShow() {
    let rows = (StateStore.read()?.lockbox?.entries ?? []).map { e -> [String] in
        let status = e.unlocked ? "UNLOCKED" : (e.unlockAtEpoch.map { "unlocking in \(TimeSpec.fmtLeft($0 - nowEpoch()))" } ?? "locked")
        return [e.name, TimeSpec.fmtLeft(e.delaySec), status]
    }
    print(Table.section("PASSWORD LOCKBOX", ["name", "unlock-delay", "status"], rows))
}

private func lockboxMark(_ path: String, _ name: String?, _ verb: String) {
    guard let name, !name.isEmpty else { fail("✗ usage: demonlock password-lockbox \(verb) <name>") }
    dropDelayMarker(path, payload: name)
    print("✓ \(verb) '\(name)' sent.")
}

private func lockboxCopy(_ name: String?) {
    guard let name, !name.isEmpty else { fail("✗ usage: demonlock password-lockbox copy <name>") }
    let entries = StateStore.read()?.lockbox?.entries ?? []
    guard let e = entries.first(where: { $0.name == name }) else { fail("✗ no secret '\(name)'.") }
    guard e.unlocked else { fail("✗ '\(name)' is locked — `unlock \(name)` first, then copy after its delay.") }
    try? FileManager.default.removeItem(atPath: Paths.lbOutboxFile)
    dropDelayMarker(Paths.lbCopyMarker, payload: name)
    var secret: String?
    for _ in 0..<40 {   // poll the daemon's one-shot outbox (~2s)
        if let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.lbOutboxFile)), !d.isEmpty { secret = String(data: d, encoding: .utf8); break }
        usleep(50_000)
    }
    try? FileManager.default.removeItem(atPath: Paths.lbOutboxFile)
    guard let sec = secret else { fail("✗ couldn't retrieve '\(name)' — is the daemon running?") }
    #if canImport(AppKit)
    Lockbox.copyToConcealedPasteboard(sec)
    #endif
    print("✓ '\(name)' copied to the clipboard (concealed) and relocked. Paste it, then clear your clipboard.")
}

private func lockboxAdd(_ args: [String]) {
    guard let name = flagValue(args, "--name"), let delay = flagValue(args, "--delay") else {
        fail("✗ need --name <n> --delay \"<dur>\"\n" + lockboxUsage)
    }
    guard let delaySec = TimeSpec.parseDuration(delay) else { fail("✗ bad --delay — e.g. \"1h\".") }
    if let why = Lockbox.rejectReason(name, delaySec: delaySec) { fail("✗ \(why)") }
    let s1 = readSecret("Secret: "), s2 = readSecret("Again : ")
    guard !s1.isEmpty else { fail("✗ empty secret.") }
    guard s1 == s2 else { fail("✗ the two entries didn't match.") }
    let entry = LockboxEntry(name: name, secret: s1, delaySec: delaySec)
    if geteuid() == 0 {
        var all = LockboxStore.load(); all.removeAll { $0.name == name }; all.append(entry); LockboxStore.save(all)
        print("✓ added '\(name)' (unlock delay \(TimeSpec.fmtLeft(delaySec))).")
    } else {
        guard let data = try? JSONEncoder().encode(entry), let json = String(data: data, encoding: .utf8) else { fail("✗ couldn't encode") }
        dropDelayMarker(Paths.lbAddMarker, payload: json)
        chmod(Paths.lbAddMarker, 0o600)   // the marker holds the plaintext secret — not group/other-readable [review]
        print("✓ '\(name)' queued — added on the next tick (no sudo).")
    }
}

/// Read a line from the controlling terminal with echo OFF (for secrets).
private func readSecret(_ prompt: String) -> String {
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var old = termios(); tcgetattr(fd, &old)
    var raw = old; raw.c_lflag &= ~tcflag_t(ECHO); tcsetattr(fd, TCSAFLUSH, &raw)
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var out = "", ch: UInt8 = 0
    while read(fd, &ch, 1) == 1 { if ch == 0x0A || ch == 0x0D { break }; out.append(Character(UnicodeScalar(ch))) }
    tcsetattr(fd, TCSAFLUSH, &old)
    _ = "\n".withCString { write(fd, $0, 1) }
    return out
}

// MARK: - snooze-presets

private let snoozePresetUsage = """
usage:
  demonlock snooze-preset show                 # presets + pending delayed-adds
  demonlock snooze-preset invoke <name>        # stand down after the preset's invoke-delay (one at a time)
  demonlock snooze-preset remove <name>        # immediate (removing tightens — no sudo)
  demonlock snooze-preset delayed-add --name <n> --duration "<spec>" --delay "<dur>"   # lands after the add-delay
  demonlock snooze-preset delayed-add abort <name> | --all
  sudo demonlock snooze-preset add --name <n> --duration "<spec>" --delay "<dur>"      # immediate
  sudo demonlock snooze-preset set-delay "<dur>"    # the delayed-add delay (baked-clamped)
  (<spec> is a snooze target: "for 90m" | "until 0500"; <dur> is the invoke delay, e.g. "1h")
"""

func runSnoozePreset(_ args: [String]) {
    let sub = args.first ?? "show"
    let rest = Array(args.dropFirst())
    switch sub {
    case "show", "list", "status", "--status": snoozePresetShow()
    case "invoke":               snoozePresetInvoke(rest.first)
    case "remove":               snoozePresetRemove(rest.first)
    case "add":                  snoozePresetAdd(rest, immediate: true)
    case "delayed-add":
        if rest.first == "abort" { snoozePresetAbort(Array(rest.dropFirst())) } else { snoozePresetAdd(rest, immediate: false) }
    case "abort":                // cancels the in-flight INVOCATION (delayed-adds use `delayed-add abort`)
        dropDelayMarker(Paths.spInvokeAbort)
        print("✓ abort sent — cancels the in-flight invocation on the next tick.")
    case "set-delay":            snoozePresetSetDelay(rest.joined(separator: " "))
    case "help", "--help", "-h": print(snoozePresetUsage)
    default: fail("✗ unknown subcommand '\(sub)'\n" + snoozePresetUsage)
    }
}

private func snoozePresetShow() {
    let inv = StateStore.read()?.snoozePresets
    let presets = SnoozePresets.effective()
    let rows = presets.map { p -> [String] in
        let active = (inv?.invocationName == p.name)
        let left = active ? TimeSpec.fmtLeft((inv?.invocationApplyAtEpoch ?? 0) - nowEpoch()) : "N/A"
        return [p.name, p.spec, TimeSpec.fmtLeft(p.invokeDelaySec), left]
    }
    print(Table.section("SNOOZE PRESETS", ["name", "target", "invoke-delay", "landing in"], rows))
    let delayH = Int(Bounds.clamp(Settings.load().snoozePresetAddDelaySec, Bounds.snoozePresetAddDelay) / 3600)
    let prows = (inv?.pendingAdds ?? []).map { [$0.name, TimeSpec.fmtLeft($0.applyAtEpoch - nowEpoch())] }
    print("\n" + Table.section("PENDING DELAYED-ADDS — land after \(delayH)h", ["name", "lands in"], prows))
}

private func snoozePresetInvoke(_ name: String?) {
    guard let name, !name.isEmpty else { fail("✗ usage: demonlock snooze-preset invoke <name>") }
    guard let p = SnoozePresets.find(name) else { fail("✗ no preset '\(name)' — see `demonlock snooze-preset show`.") }
    dropDelayMarker(Paths.spInvokeMarker, payload: name)
    print("✓ '\(name)' invoked — stands down (\(p.spec)) in \(TimeSpec.fmtLeft(Bounds.clamp(p.invokeDelaySec, Bounds.snoozePresetInvokeDelay))), then re-arms. One at a time; cancel with `snooze-preset abort` (via invoke-abort).")
}

private func snoozePresetRemove(_ name: String?) {
    guard let name, !name.isEmpty else { fail("✗ usage: demonlock snooze-preset remove <name>") }
    dropDelayMarker(Paths.spRemoveMarker, payload: name)
    print("✓ remove '\(name)' sent — applied on the next tick.")
}

private func snoozePresetAdd(_ args: [String], immediate: Bool) {
    guard let name = flagValue(args, "--name"), let dur = flagValue(args, "--duration"), let delay = flagValue(args, "--delay") else {
        fail("✗ need --name <n> --duration \"<spec>\" --delay \"<dur>\"\n" + snoozePresetUsage)
    }
    guard let invokeDelay = TimeSpec.parseDuration(delay) else { fail("✗ bad --delay — e.g. \"1h\", \"90m\".") }
    let p = SnoozePreset(name: name, spec: dur, invokeDelaySec: invokeDelay)
    if let why = SnoozePresets.rejectReason(p) { fail("✗ \(why)") }
    if immediate {
        requireRoot("snooze-preset add")
        SnoozePresets.applyAdd(p)
        SnoozePresets.clearPendingAdd(name: name)   // an immediate add cancels any pending delayed one
        print("✓ added preset '\(name)' (\(dur), invoke-delay \(TimeSpec.fmtLeft(invokeDelay))).")
    } else {
        guard let data = try? JSONEncoder().encode(p), let json = String(data: data, encoding: .utf8) else { fail("✗ couldn't encode the preset") }
        dropDelayMarker(Paths.spAddMarker, payload: json)
        let delayH = Int(Bounds.clamp(Settings.load().snoozePresetAddDelaySec, Bounds.snoozePresetAddDelay) / 3600)
        print("✓ queued preset '\(name)' — becomes available in \(delayH)h (no sudo). Cancel: `snooze-preset delayed-add abort \(name)`.")
    }
}

private func snoozePresetAbort(_ args: [String]) {
    let arg = args.first ?? ""
    guard arg == "--all" || !arg.isEmpty else { fail("✗ usage: demonlock snooze-preset delayed-add abort <name> | --all") }
    dropDelayMarker(Paths.spAddAbort, payload: arg)
    print("✓ abort sent for \(arg == "--all" ? "all pending adds" : "'\(arg)'").")
}

private func snoozePresetSetDelay(_ durText: String) {
    requireRoot("snooze-preset set-delay")
    guard let secs = TimeSpec.parseDuration(durText), secs > 0 else { fail("✗ bad delay — e.g. \"48h\".") }
    Settings.mutate { $0.snoozePresetAddDelaySec = secs }
    let eff = Int(Bounds.clamp(secs, Bounds.snoozePresetAddDelay) / 3600)
    print("✓ snooze-preset add-delay set to \(Int(secs/3600))h (effective \(eff)h after the baked clamp).")
}

// MARK: - safe-apps

private let safeAppsUsage = """
usage:
  demonlock safe-apps show                     # the spare list + pending delayed registrations
  sudo demonlock safe-apps register <bundle-id>                                   # root-owned (Regime A) — just the bundle
  sudo demonlock safe-apps register <bundle-id> --no-root-ownership --tid <TEAM>  # Developer-ID (Regime B)
  demonlock safe-apps delayed-register <bundle-id> [--no-root-ownership --tid <TEAM>]   # lands after the delay (no sudo)
  demonlock safe-apps delayed-register abort <name> | --all
  demonlock safe-apps remove <name>            # immediate (removing tightens — no sudo)
  sudo demonlock safe-apps set-delay "<dur>"   # delayed-register delay (clamped to the baked range)
  (root-owned needs ONLY the bundle id — its team is never checked. --no-root-ownership needs --tid.
   optional --name overrides the auto-derived handle; browsers + paseo desktop are blocklisted.)
"""

func runSafeApps(_ args: [String]) {
    let sub = args.first ?? "show"
    let rest = Array(args.dropFirst())
    switch sub {
    case "show", "list", "status", "--status": safeAppsShow()
    case "register":                            safeAppsRegister(rest, immediate: true)
    case "delayed-register":
        if rest.first == "abort" { safeAppsAbort(Array(rest.dropFirst())) } else { safeAppsRegister(rest, immediate: false) }
    case "remove":                              safeAppsRemove(rest.first)
    case "abort":                               safeAppsAbort(rest)
    case "set-delay":                           safeAppsSetDelay(rest.joined(separator: " "))
    case "help", "--help", "-h":                print(safeAppsUsage)
    default: fail("✗ unknown subcommand '\(sub)'\n" + safeAppsUsage)
    }
}

private func flagValue(_ args: [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// First bare (non-flag) token, skipping value-flags (--bid/--tid/--name) AND their values so a `--tid
/// XXXXXXXXXX` value can't be mistaken for the positional bundle id.
private func positionalArg(_ args: [String]) -> String? {
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--bid", "--tid", "--name": i += 2                 // flag + its value
        case let a where a.hasPrefix("-"): i += 1               // valueless flag (e.g. --no-root-ownership)
        default: return args[i]
        }
    }
    return nil
}

private func safeAppsShow() {
    let apps = SafeApps.effective()
    let rows = apps.map { [$0.name, $0.bid, $0.tid, $0.rootOwned ? "yes" : "no"] }
    print(Table.section("SAFE APPS — spared from the lockout kill", ["name", "bundle id", "team", "root-req"], rows))
    let delayH = Int(Bounds.clamp(Settings.load().safeAppsDelaySec, Bounds.safeAppsDelay) / 3600)
    let pend = StateStore.read()?.safeApps?.pending ?? []
    let prows = pend.map { [$0.name, $0.bid, TimeSpec.fmtLeft($0.applyAtEpoch - nowEpoch())] }
    print("\n" + Table.section("PENDING REGISTRATIONS — land after \(delayH)h", ["name", "bundle id", "lands in"], prows))
}

private func safeAppsRegister(_ args: [String], immediate: Bool) {
    let rootOwned = !args.contains("--no-root-ownership")
    // "you only need to specify the bundle": bid is --bid <id> OR the first bare positional token.
    guard let bid = flagValue(args, "--bid") ?? positionalArg(args), !bid.isEmpty else {
        fail("✗ need a bundle id: `safe-apps register <bundle-id>`\n" + safeAppsUsage)
    }
    // team id is ONLY needed (and only ever checked) for Regime B. Root-owned stores it empty.
    let tid: String
    if rootOwned {
        tid = flagValue(args, "--tid") ?? ""
    } else {
        guard let t = flagValue(args, "--tid") else {
            fail("✗ --no-root-ownership needs --tid <TEAM> (Regime B verifies the Apple Team ID)\n" + safeAppsUsage)
        }
        tid = t
    }
    let name = flagValue(args, "--name") ?? SafeApps.deriveName(bid)
    let app = SafeApp(name: name, bid: bid, tid: tid, rootOwned: rootOwned)
    if let why = SafeApps.rejectReason(app, settings: Settings.load()) { fail("✗ \(why)") }
    if immediate {
        requireRoot("safe-apps register")
        SafeApps.applyAdd(app)
        SafeApps.clearPending(bid: bid)   // an immediate register cancels any pending delayed one for this bid
        print("✓ registered '\(name)' (\(bid)) — spared now. Regime \(app.rootOwned ? "A (root-owned; team not checked)" : "B (Developer-ID \(tid))").")
    } else {
        guard let data = try? JSONEncoder().encode(app), let json = String(data: data, encoding: .utf8) else { fail("✗ couldn't encode the entry") }
        dropDelayMarker(Paths.saRegisterMarker, payload: json)
        let delayH = Int(Bounds.clamp(Settings.load().safeAppsDelaySec, Bounds.safeAppsDelay) / 3600)
        print("✓ queued '\(name)' — it becomes spared in \(delayH)h (no sudo). Watch: `demonlock safe-apps show` · cancel: `safe-apps delayed-register abort \(name)`.")
    }
}

private func safeAppsRemove(_ name: String?) {
    guard let name, !name.isEmpty else { fail("✗ usage: demonlock safe-apps remove <name>") }
    if let d = SafeApps.defaults.first(where: { $0.name == name }), SafeApps.unremovableBIDs.contains(d.bid) {
        fail("✗ '\(name)' (\(d.bid)) is unremovable — removing it would kill the agent on lockout.")
    }
    dropDelayMarker(Paths.saRemoveMarker, payload: name)
    print("✓ remove '\(name)' sent — applied on the next tick (no delay; removing only tightens).")
}

private func safeAppsAbort(_ args: [String]) {
    let arg = args.first ?? ""
    guard arg == "--all" || !arg.isEmpty else { fail("✗ usage: demonlock safe-apps delayed-register abort <name> | --all") }
    dropDelayMarker(Paths.saAbortMarker, payload: arg)
    print("✓ abort sent for \(arg == "--all" ? "all pending registrations" : "'\(arg)'").")
}

private func safeAppsSetDelay(_ durText: String) {
    requireRoot("safe-apps set-delay")
    guard let secs = TimeSpec.parseDuration(durText), secs > 0 else { fail("✗ bad delay — e.g. \"24h\", \"12h\".") }
    Settings.mutate { $0.safeAppsDelaySec = secs }
    let eff = Int(Bounds.clamp(secs, Bounds.safeAppsDelay) / 3600)
    print("✓ safe-apps delayed-register delay set to \(Int(secs/3600))h (effective \(eff)h after the baked \(Int(Bounds.safeAppsDelay.lowerBound/3600))–\(Int(Bounds.safeAppsDelay.upperBound/3600))h clamp).")
}

// MARK: - admin-release-valve

private let rvUsage = """
usage:
  # config (sudo; each subcommand sets one field):
  sudo demonlock admin-release-valve set-gate-policy "<expr>"          # WHEN a grant may open (policy + IN_POLICY)
  sudo demonlock admin-release-valve set-delay "<dur>"                 # wait after request before eligible (≥ floor)
  sudo demonlock admin-release-valve set-max-request-duration "<dur>"  # ceiling on a request's grant length
  # use (no sudo; all three set first):
  demonlock admin-release-valve request "<dur>"     # ask for admin: granted after the delay, at the next open
                                                    #   gate, for <dur> (≤ max). Idempotent while pending.
  demonlock admin-release-valve status              # phase / countdown / gate eval
  demonlock admin-release-valve abort               # cancel a pending request OR close a live grant now
  # extend a LIVE grant (sudo — you only hold admin during a grant, so this can't bootstrap one):
  sudo demonlock admin-release-valve i-still-need-sudo "for <dur>" | "until <HHMM>"   # ≤ 1h more, in-window only
"""

func runReleaseValve(_ args: [String]) {
    let sub = args.first ?? ""
    let rest = Array(args.dropFirst()).joined(separator: " ")
    switch sub {
    case "", "help", "--help", "-h":   print(rvUsage)
    case "status", "--status":         printReleaseValveStatusCLI()
    case "abort", "--abort":
        dropDelayMarker(Paths.rvAbortMarker)
        print("✓ abort sent — cancels a pending request and closes a live grant on the next tick.")
    case "request", "--request":                rvRequest(rest)
    case "i-still-need-sudo":                    rvExtend(rest)
    case "set-gate-policy":                      rvSetGatePolicy(rest)
    case "set-delay":                            rvSetDelay(rest)
    case "set-max-request-duration":             rvSetMaxDuration(rest)
    case "delay-set-gate-policy":                rvDelayGatePolicy(rest)
    default: fail("✗ unknown subcommand '\(sub)'\n" + rvUsage)
    }
}

/// request "<dur>" (no sudo): drop a request marker whose contents are the requested grant duration.
/// Idempotent while pending (updates the duration; the daemon won't reset the frozen delay).
private func rvRequest(_ durText: String) {
    let cfg = ReleaseValveConfig.load()
    guard cfg.isComplete else {
        fail("✗ release-valve isn't configured — set gate-policy, delay, and max-request-duration first (sudo):\n" + rvUsage)
    }
    guard let secs = TimeSpec.parseDuration(durText.trimmingCharacters(in: .whitespacesAndNewlines)), secs > 0 else {
        fail("✗ a duration is required: `demonlock admin-release-valve request \"1h\"` (≤ \(Int(cfg.effectiveMaxDuration/60))m).")
    }
    let st = ReleaseValveState.load()
    if st.isGranted { fail("✗ admin is already granted — extend with i-still-need-sudo, or `abort` first.") }
    let capped = min(secs, cfg.effectiveMaxDuration)
    dropDelayMarker(Paths.rvRequestMarker, payload: "\(Int(capped))s")
    if st.isIdle {
        print("✓ requested \(Int(capped/60))m of admin — granted after ~\(Int(cfg.effectiveDelay/60))m, at the next open gate.")
    } else {
        print("✓ updated the pending request to \(Int(capped/60))m (the delay is unchanged).")
    }
    print("  Watch: `demonlock status`  ·  cancel: `demonlock admin-release-valve abort`")
}

/// i-still-need-sudo (SUDO): extend a LIVE grant by ≤ Bounds.rvExtendMax, only while the gate is open.
/// Requires sudo, which you only have during a grant — so it can extend but never bootstrap admin.
private func rvExtend(_ spec: String) {
    requireRoot("admin-release-valve i-still-need-sudo")
    let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
    let extra: Double
    if let d = TimeSpec.parseDuration(s) { extra = d }
    else if let t = try? TimeSpec.parseTarget(s) { extra = t.timeIntervalSinceNow }
    else { fail("✗ usage: sudo demonlock admin-release-valve i-still-need-sudo \"for 45m\" | \"until 1730\"") }
    guard extra > 0 else { fail("✗ that time is already past.") }
    let capped = min(extra, Bounds.rvExtendMax)

    var st = ReleaseValveState.load()
    guard st.isGranted else { fail("✗ no live admin grant to extend — request one first (`admin-release-valve request \"1h\"`).") }
    // The gate must be OPEN right now (from the daemon's published eval) — no extending after you leave.
    guard let rv = StateStore.read()?.releaseValve, rv.windowOpen else {
        fail("✗ the gate is closed right now — i-still-need-sudo only works inside the window.")
    }
    st.grantExpiresAt = nowEpoch() + capped
    ReleaseValveState.write(st)
    print("✓ extended — admin now held for \(Int(capped/60))m more (from now).")
}

private func rvSetGatePolicy(_ expr: String) {
    requireRoot("admin-release-valve set-gate-policy")
    let s = expr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { fail("✗ give a gate-policy expression (IN_POLICY allowed).") }
    do { try PolicyEngine.validate(s, zones: ZoneStore.load(), allowInPolicy: true) } catch { fail("✗ invalid gate policy: \(error)") }
    var cfg = ReleaseValveConfig.load(); cfg.gatePolicy = s
    do { try cfg.save() } catch { fail("✗ couldn't write config: \(error)") }
    rvPrintConfig(cfg)
}

private func rvSetDelay(_ durText: String) {
    requireRoot("admin-release-valve set-delay")
    guard let secs = TimeSpec.parseDuration(durText), secs >= 0 else { fail("✗ bad delay — e.g. \"1h\", \"90m\".") }
    var cfg = ReleaseValveConfig.load(); cfg.delaySec = secs
    do { try cfg.save() } catch { fail("✗ couldn't write config: \(error)") }
    if secs < Bounds.rvRequestDelayMin { print("  note: below the \(Int(Bounds.rvRequestDelayMin/60))m floor — the floor is enforced at request time.") }
    rvPrintConfig(cfg)
}

private func rvSetMaxDuration(_ durText: String) {
    requireRoot("admin-release-valve set-max-request-duration")
    guard let secs = TimeSpec.parseDuration(durText), secs > 0 else { fail("✗ bad duration — e.g. \"1h\", \"30m\".") }
    var cfg = ReleaseValveConfig.load(); cfg.maxRequestDurationSec = secs
    do { try cfg.save() } catch { fail("✗ couldn't write config: \(error)") }
    if secs > Bounds.rvMaxRequestDurationCeil { print("  note: above the \(Int(Bounds.rvMaxRequestDurationCeil/3600))h ceiling — the ceiling is enforced at request time.") }
    rvPrintConfig(cfg)
}

/// delay-set-gate-policy "<expr>" | abort | status | set-delay "<dur>" (last is sudo). A no-sudo delayed
/// change to the release-valve gate policy, landing after gatePolicyDelaySec.
private func rvDelayGatePolicy(_ arg: String) {
    let s = arg.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty || s == "status" || s == "--status" {
        if let pc = DelayedState.load(Paths.delayedGatePolicyFile).pending {
            print("delayed gate-policy: QUEUED — lands \(TimeSpec.fmtWhen(pc.applyAt))  (\(TimeSpec.fmtLeft(pc.applyAt - nowEpoch())) left)\n  \(pc.payload)")
        } else { print("delayed gate-policy: none queued.") }
        return
    }
    if s == "abort" || s == "--abort" { dropDelayMarker(Paths.dgpAbortMarker); print("✓ abort sent — cancels a queued gate-policy change next tick."); return }
    if s.hasPrefix("set-delay") {
        requireRoot("admin-release-valve delay-set-gate-policy set-delay")
        let dur = String(s.dropFirst("set-delay".count)).trimmingCharacters(in: .whitespaces)
        guard let secs = TimeSpec.parseDuration(dur), secs > 0 else { fail("✗ bad delay — e.g. \"36h\".") }
        Settings.mutate { $0.gatePolicyDelaySec = secs }
        print("✓ gate-policy delay set to \(Int(secs/3600))h (clamped to \(Int(Bounds.gatePolicyDelay.lowerBound/3600))–\(Int(Bounds.gatePolicyDelay.upperBound/3600))h).")
        return
    }
    do { try PolicyEngine.validate(s, zones: ZoneStore.load(), allowInPolicy: true) } catch { fail("✗ invalid gate policy: \(error)") }
    dropDelayMarker(Paths.dgpRequestMarker, payload: s)
    let delayH = Int(Bounds.clamp(Settings.load().gatePolicyDelaySec, Bounds.gatePolicyDelay) / 3600)
    print("✓ queued — the release-valve gate policy changes in \(delayH)h (no sudo). abort: `admin-release-valve delay-set-gate-policy abort`.")
}

private func rvPrintConfig(_ cfg: ReleaseValveConfig) {
    func fmtDur(_ s: Double?) -> String { s.map { "\(Int($0/3600))h\(Int($0.truncatingRemainder(dividingBy: 3600)/60))m" } ?? "(unset)" }
    print("✓ release-valve config:")
    print("    gate-policy          : \(cfg.gatePolicy ?? "(unset)")")
    print("    request-delay        : \(fmtDur(cfg.delaySec))  (floor \(Int(Bounds.rvRequestDelayMin/60))m)")
    print("    max-request-duration : \(fmtDur(cfg.maxRequestDurationSec))  (ceiling \(Int(Bounds.rvMaxRequestDurationCeil/3600))h)")
    print(cfg.isComplete ? "  all set — `demonlock admin-release-valve request \"<dur>\"` is ready." :
                           "  ⚠️  still missing a field; request won't work until all three are set.")
}

// MARK: - delaysetpolicy (NO sudo — queues a policy that lands after 36h)

private let dspUsage = """
usage (no sudo — the change lands after a fixed delay, no sudo needed then either):
  demonlock delaysetpolicy "<policy>"   # queue a new allow-policy; applies in 36h (validated now AND
                                        #   again at apply time). Re-queueing resets the 36h.
  demonlock delaysetpolicy --status     # show what's queued and when it lands
  demonlock delaysetpolicy --abort      # cancel a queued change
  demonlock delaysetpolicy --help       # this help   (--status / --abort / --help also work bare)
"""

func runDelaySetPolicy(_ args: [String]) {
    if handleRequestFlags(args.first, usage: dspUsage, abortMarker: Paths.dspAbortMarker,
                          status: printDelayedPolicyStatus) { return }
    let delayH = Int(DelayedChange.policyDelaySec / 3600)
    let p = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if p.isEmpty { print(dspUsage); return }
    if p.hasPrefix("--") { fail("✗ unknown option '\(args[0])'.\n" + dspUsage) }
    do { try PolicyEngine.validate(p, zones: ZoneStore.load()) } catch { fail("✗ invalid policy: \(error)\n\n(fix it, then re-queue.)") }
    if let cur = DelayedState.load(Paths.delayedPolicyFile).pending {
        print("⚠️  replacing an already-queued policy (its \(delayH)h timer restarts):\n    \(cur.payload)\n")
    }
    dropDelayMarker(Paths.dspRequestMarker, payload: p)
    print("✓ queued — this policy applies in \(delayH)h (re-validated then). It takes effect with NO sudo.")
    print("  Watch it: `demonlock status`  ·  cancel: `demonlock delaysetpolicy --abort`")
}

/// Print the queued delayed-policy state (from the published snapshot, else the on-disk pending file).
private func printDelayedPolicyStatus() {
    let delayH = Int(DelayedChange.policyDelaySec / 3600)
    if let pc = DelayedState.load(Paths.delayedPolicyFile).pending {
        let left = max(0, Int(pc.applyAt - nowEpoch()))
        print("delayed policy: QUEUED — lands \(TimeSpec.fmtWhen(pc.applyAt))" +
              "  (\(left/3600)h \(left%3600/60)m left)")
        print("  \(pc.payload)")
    } else {
        print("delayed policy: none queued.  Queue one with `demonlock delaysetpolicy \"<policy>\"` (lands in \(delayH)h).")
    }
}

private let dzUsage = """
usage (no sudo — a zones change is CREATED from the map's "Save in 36h"; here you view / cancel it):
  demonlock delayzones --status   # show a queued zones change and when it lands
  demonlock delayzones --abort    # cancel a queued zones change
  demonlock delayzones --help     # this help   (--status / --abort / --help also work bare)
"""

private func printDelayZonesStatus() {
    if let pc = DelayedState.load(Paths.delayedZonesFile).pending {
        let left = max(0, Int(pc.applyAt - nowEpoch()))
        print("delayed zones: QUEUED — lands \(TimeSpec.fmtWhen(pc.applyAt))  (\(left/3600)h \(left%3600/60)m left)")
        print("  cancel with `demonlock delayzones --abort`")
    } else {
        print("delayed zones: none queued.  Queue one from the map (`demonlock zones` → add → \"Save in 36h\").")
    }
}

/// delayzones (NO sudo): a queued zones change is CREATED from the map ("Save in 36h"); here you can
/// only view or cancel it. Bare `delayzones` shows status; unknown args → usage.
func runDelayZones(_ args: [String]) {
    if handleRequestFlags(args.first, usage: dzUsage, abortMarker: Paths.dzAbortMarker,
                          status: printDelayZonesStatus) { return }
    if let a = args.first { fail("✗ unknown argument '\(a)'.\n" + dzUsage) }
    printDelayZonesStatus()
}

/// Drop a delayed-change marker in the user-owned inbox (non-root). `payload` (the new policy/zones)
/// becomes the request marker's contents; the daemon reads, validates, and stamps the real time itself.
func dropDelayMarker(_ path: String, payload: String = "") {
    do { try Data(payload.utf8).write(to: URL(fileURLWithPath: path)) }
    catch { fail("✗ couldn't write the marker (\(path)). Is the inbox present? Try reinstalling demonlock.\n  \(error)") }
}

// MARK: - perm-ask (user)

func runPermAsk() {
    print("Demonlock's agent needs Location permission (it runs as your user).")
    if let h = StateStore.read()?.health {
        print("  current: location=\(h.locState), needs-permission=\(h.needsPermAsk ? "YES" : "no")")
    }
    print("Opening System Settings ▸ Privacy & Security ▸ Location Services — turn ON \"Demonlock\".")
    Proc.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"])
    print("")
    print("The settings-guard also needs ACCESSIBILITY (to slam FileVault / Device Management panes).")
    print("Opening Privacy & Security ▸ Accessibility — turn ON \"Demonlock\" there too.")
    Proc.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
}

// MARK: - test-lockout (user) — do the lockout kill on demand, to verify it works

func runTestLockout(_ args: [String]) {
    let go = args.contains("--go")
    let targets = SensorFeeder.guiKillTargets(excludingPID: getpid()).sorted { $0.name < $1.name }
    if targets.isEmpty { print("test-lockout: nothing to close — no non-spared GUI apps are running right now."); return }
    print("test-lockout: a real lockout would SIGKILL these \(targets.count) app(s):")
    for t in targets { print("  • \(t.name)  (pid \(t.pid))") }
    print("  spared apps, Apple menubar items, and sshd/tmux survive. (A test never does the nuclear WindowServer kill.)")
    guard go else {
        print("\nDRY RUN — nothing closed. Re-run with --go to actually close them:\n  demonlock test-lockout --go")
        return
    }
    print("\nclosing now…")
    for t in targets where t.pid > 1 { kill(t.pid, SIGKILL) }
    print("✓ done — that's exactly the per-app kill a real lockout performs.")
}

// MARK: - help

func printHelp() {
    print("""
    demonlock — conditional macOS locker

    USAGE: demonlock <command>

    USER COMMANDS (no sudo):
      status              Arm state, phase, verdict, reason, policy, zones, health + every subsystem
      zones               Map of your zones. Add/Delete a zone — each asks: now (admin) or in 36h.
      zones list          Print zone names + shapes (no map) — `list-zones` also works
      scan                Continuously scan nearby Wi-Fi (SSID + BSSID) until Ctrl+C
      perm-ask            (Re)grant the Location permission the agent needs
      arm                 Turn enforcement ON (also drops admin + closes the release valve)
      nosudo              Drop admin now (revoke) + close the release valve
      admin-release-valve request "<dur>"   Ask for delay-gated admin (`… status` / `… abort`;
                          `… i-still-need-sudo` extends a live grant — sudo, in-window). See `… help`.
      safe-apps …         Manage the lockout spare list (show / delayed-register / remove). `… help`.
      snooze-preset …     Named snooze shortcuts (show / invoke / delayed-add). `… help`.
      password-lockbox …  Delay-gated secret store (show / unlock / copy / add). `… help`.
      delay-set-policy "<expr>"   Queue a new allow-policy that lands after the delay (no sudo).
      delayzones --status|--abort  View / cancel a zones change queued from the map's "Save in 36h".
      help                This help

    SUDO COMMANDS (require `sudo`):
      setpolicy "<expr>"  Set the allow-policy (validated before it takes effect)
      disarm              Turn enforcement OFF (everything keeps running; countdown just no-ops)
      snooze "<spec>"     Stand down "for <duration>" | "until <[day]HHMM>" (capped 18h), then RE-ARM.
                          e.g. sudo demonlock snooze "for 90m"  ·  sudo demonlock snooze "until 0730"
      admin-release-valve set-gate-policy "<expr>" | set-delay "<dur>" | set-max-request-duration "<dur>"
                          Configure the release valve (gate uses policy syntax + IN_POLICY). Then
                          `admin-release-valve request "<dur>"` (no sudo) works.
      safe-apps register … | snooze-preset add … | password-lockbox add …   Immediate variants.

    POLICY LANGUAGE  (the ALLOW condition — combine with AND / OR / NOT / parentheses):
      LOCATED_IN_ANY(["zone name", ...])
          true when inside any named zone (circle or polygon)
      FOUND_IN_NEARBY_BSSID(["aa:bb:cc:dd:ee:ff", ...])
          true when any pinned access-point hardware address is in range
      TIME_IS_ANY([M0900-1700, *1000-1800, ...])
          true when now is in a window; days M T W R F S U (R=Thu, U=Sun) or * = all 7;
          HHMM 0000-2400, start < end (no midnight wrap — split into two windows)
      IN_POLICY   (release-valve window policy ONLY)
          true when the MAIN policy currently allows — e.g.
          sudo demonlock admin-release-valve set-gate-policy "IN_POLICY AND TIME_IS_ANY([*1000-1100])"

      example:
        sudo demonlock setpolicy '(LOCATED_IN_ANY(["office"]) OR FOUND_IN_NEARBY_BSSID(["a4:97:33:5f:aa:b6"])) AND TIME_IS_ANY([MTWRF0700-2000])'

    The verdict is three-valued: a missing sensor only blocks you when it actually changes the
    answer — fail-closed only when the policy is genuinely indeterminate.
    """)
}
