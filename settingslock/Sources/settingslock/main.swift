// settingslock — slam System Settings shut the instant it shows the FileVault
// detail pane, so the FileVault recovery key can never be revealed there.
//
// Why a watcher works here even though a recovery key is a static secret: seeing
// the key takes reach-the-pane → click "Show" → Touch ID / password (~1s+). A
// 100 ms detector kills System Settings the moment the FileVault pane *renders*,
// long before "Show" can be clicked. Detection keys on the pane's own content
// (the "FileVault" heading / "Recovery Key" label) via the Accessibility tree,
// so it fires whether you drilled in through Privacy & Security OR jumped
// straight there from search.
//
//   settingslock status   is the watcher running?
//   settingslock dump      print what it sees on the current Settings pane (tuning)
//   settingslock watch     the detector (run by launchd in your GUI session)
//   settingslock guard     the root watchdog that keeps `watch` alive

import Foundation
import AppKit
import ApplicationServices

let SETTINGS_BUNDLE = "com.apple.systempreferences"

// The System Settings WINDOW TITLE becomes exactly "FileVault" when the FileVault
// pane is shown — whether you drilled in through Privacy & Security or jumped
// straight there from search. Matching the title is cheap (one attribute, no
// tree walk) and precise: it fires ONLY on the FileVault pane, never the parent
// list (whose title is "Privacy & Security"). Run `settingslock dump` to confirm.
let TITLE_TRIGGERS = ["FileVault"]

let WATCH_LABEL = "com.settingslock.watch"
let WATCH_PLIST = "/Library/LaunchAgents/\(WATCH_LABEL).plist"
let HEARTBEAT   = "/tmp/settingslock.heartbeat"
let POLL_SECONDS = 0.1

// Root-owned armed flag (world-readable so the user-session watcher can read it;
// only root can write it). Fail-secure: anything other than "0" means armed, so
// a missing/garbled flag keeps protecting rather than silently opening up.
let ARMED_DIR  = "/usr/local/etc/settingslock"
let ARMED_FILE = "/usr/local/etc/settingslock/armed"

func isArmed() -> Bool {
    guard let s = try? String(contentsOfFile: ARMED_FILE, encoding: .utf8) else { return true }
    return s.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
}

// ── helpers ────────────────────────────────────────────────────────────────

func log(_ m: String) {
    FileHandle.standardError.write(Data(("[settingslock] " + m + "\n").utf8))
}

@discardableResult
func sh(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func consoleUID() -> uid_t {
    var st = stat()
    return stat("/dev/console", &st) == 0 ? st.st_uid : 0
}

// ── Accessibility ──────────────────────────────────────────────────────────

func settingsFrontmostPID() -> pid_t? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == SETTINGS_BUNDLE else { return nil }
    return app.processIdentifier
}

func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? (v as AnyObject) : nil
}

func axText(_ el: AXUIElement) -> [String] {
    var out: [String] = []
    for a in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
        if let s = axCopy(el, a as String) as? String, !s.isEmpty { out.append(s) }
    }
    return out
}

/// True if any System Settings window's title matches a trigger. Cheap (titles
/// only) and precise — the title is "FileVault" exactly on the FileVault pane.
func fileVaultShowing(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let windows = axCopy(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return false }
    for w in windows {
        if let t = axCopy(w, kAXTitleAttribute as String) as? String {
            for trig in TITLE_TRIGGERS where t.localizedCaseInsensitiveContains(trig) { return true }
        }
    }
    return false
}

// ── commands ───────────────────────────────────────────────────────────────

func runWatch() {
    if !AXIsProcessTrusted() {
        // Best-effort: pops the "open Accessibility settings" prompt.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        log("watch: NOT yet trusted for Accessibility — add /usr/local/bin/settingslock in "
            + "System Settings ▸ Privacy & Security ▸ Accessibility. Re-checking each tick.")
    }
    log("watch started (poll \(Int(POLL_SECONDS * 1000)) ms)")
    let timer = Timer(timeInterval: POLL_SECONDS, repeats: true) { _ in
        try? String(Date().timeIntervalSince1970).write(toFile: HEARTBEAT, atomically: true, encoding: .utf8)
        guard AXIsProcessTrusted() else { return }      // blind without permission
        guard let pid = settingsFrontmostPID() else { return }   // only walk when Settings is up front
        if fileVaultShowing(pid: pid) && isArmed() {
            log("FileVault pane detected — killing System Settings (pid \(pid))")
            kill(pid, SIGKILL)
        }
    }
    RunLoop.current.add(timer, forMode: .common)
    RunLoop.current.run()
}

/// Root watchdog: if the user boots out the watch agent, put it back. (KeepAlive
/// restarts a crash but NOT a bootout — this closes that escape.)
func runGuard() {
    log("guard started")
    while true {
        let uid = consoleUID()
        if uid >= 501 {
            if sh("/bin/launchctl", ["print", "gui/\(uid)/\(WATCH_LABEL)"]) != 0 {
                _ = sh("/bin/launchctl", ["bootstrap", "gui/\(uid)", WATCH_PLIST])
                _ = sh("/bin/launchctl", ["kickstart", "gui/\(uid)/\(WATCH_LABEL)"])
                log("guard: watch agent was missing — re-bootstrapped it")
            }
        }
        sleep(1)
    }
}

func runDump() {
    var pid = settingsFrontmostPID()
    if pid == nil {
        print("Open System Settings to the pane you want, focusing it within 3s…")
        for _ in 0..<30 { usleep(100_000); if let p = settingsFrontmostPID() { pid = p; break } }
    }
    guard let pid else { print("System Settings is not frontmost — aborting."); return }
    guard AXIsProcessTrusted() else {
        print("This binary isn't Accessibility-trusted yet. Grant `settingslock` (or your terminal)")
        print("Accessibility in System Settings ▸ Privacy & Security ▸ Accessibility, then retry.")
        return
    }
    var seen = Set<String>()
    func walk(_ el: AXUIElement, _ d: Int) {
        if d > 20 { return }
        for s in axText(el) where !s.isEmpty { seen.insert(s) }
        if let kids = axCopy(el, kAXChildrenAttribute as String) as? [AXUIElement] {
            for k in kids { walk(k, d + 1) }
        }
    }
    walk(AXUIElementCreateApplication(pid), 0)
    print("=== AX text on this Settings pane (pick TRIGGERS from these) ===")
    for s in seen.sorted() { print("  \(s)") }
}

func runStatus() {
    let raw = (try? String(contentsOfFile: HEARTBEAT, encoding: .utf8)) ?? ""
    let ts = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let alive = Date().timeIntervalSince1970 - ts < 3
    print("enforcement: \(isArmed() ? "ARMED" : "DISARMED")")
    print("watcher: \(alive ? "RUNNING" : "NOT running")")
    print("title triggers: \(TITLE_TRIGGERS.joined(separator: ", "))")
    if alive {
        print("(if Settings still reaches FileVault, the binary likely lacks Accessibility —")
        print(" grant it in Privacy & Security ▸ Accessibility, then `settingslock dump` to tune)")
    }
}

// Root-gated arm/disarm: flips the root-owned flag the watcher reads each time
// it would act. disarm leaves both daemons running — it just stands the watcher
// down — same model as your other tools.
func setArmedCLI(_ on: Bool) {
    if geteuid() != 0 {
        // arm TIGHTENS (enables blocking) → allowed WITHOUT admin via a passwordless sudoers grant;
        // re-exec through `sudo -n` and the elevated copy does it. disarm LOOSENS → no grant, stays gated.
        if on {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "/usr/local/bin/settingslock", "arm"]
            do {
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 {
                    print("settingslock: couldn't arm without admin — the passwordless grant may be missing (reinstall), or run `sudo settingslock arm`")
                    exit(1)
                }
                exit(0)
            } catch {
                print("settingslock: failed to elevate arm: \(error.localizedDescription)"); exit(1)
            }
        }
        print("settingslock: disarm requires root — use `sudo settingslock disarm`")
        exit(1)
    }
    _ = sh("/bin/mkdir", ["-p", ARMED_DIR])
    do { try (on ? "1" : "0").write(toFile: ARMED_FILE, atomically: true, encoding: .utf8) }
    catch { print("settingslock: failed to write \(ARMED_FILE): \(error.localizedDescription)"); exit(1) }
    _ = sh("/usr/sbin/chown", ["root:wheel", ARMED_FILE])
    _ = sh("/bin/chmod", ["644", ARMED_FILE])
    print(on ? "settingslock: ARMED — the FileVault pane will be slammed shut"
             : "settingslock: DISARMED — watcher stands down (still running, just won't act)")
}

// ── dispatch ───────────────────────────────────────────────────────────────

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
switch cmd {
case "watch":  runWatch()
case "guard":  runGuard()
case "dump":   runDump()
case "status": runStatus()
case "arm":    setArmedCLI(true)
case "disarm": setArmedCLI(false)
default:
    print("""
    settingslock — kill System Settings the instant it shows the FileVault pane.

      settingslock status        is it armed / running?
      settingslock arm           enable blocking (no admin — arming only tightens)
      sudo settingslock disarm   stand down (admin — loosening stays gated)
      settingslock dump          AX text of the current Settings pane (trigger tuning)
      settingslock watch         the detector agent (launchd, your GUI session)
      settingslock guard         the root watchdog that keeps `watch` alive
    """)
}
