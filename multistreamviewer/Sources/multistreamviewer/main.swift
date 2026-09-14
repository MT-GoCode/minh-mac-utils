import AppKit
import MSVCore

// CLI verbs post Darwin notifications to the running app:
//   multistreamviewer [run] | new | next | gather | switch <N|next> | send <N>
enum Notify {
    static let prefix = "com.minh.multistreamviewer."
    static func prefixed(_ s: String) -> String { prefix + s }
}

func post(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(Notify.prefixed(name) as CFString), nil, nil, true)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Diagnose "alive but dead" in 5 seconds: is the app running, is its heartbeat fresh, is the
/// tap alive. Runs in this CLI process — no permissions needed.
func runStatus() -> Never {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "multistreamviewer.app/Contents/MacOS/multistreamviewer"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let pids = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .split(separator: "\n").compactMap { Int32($0) }.filter { $0 != getpid() }
    guard let pid = pids.first else {
        print("not running — launchd should revive it within ~30s; check: launchctl print gui/\(getuid())/com.minh.multistreamviewer.agent")
        exit(1)
    }
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/multistreamviewer/health.json")
    guard let data = try? Data(contentsOf: url),
          let h = try? JSONDecoder().decode(Health.self, from: data) else {
        // Normal for the first ~30s after launch; suspicious after that (unwritable state dir?)
        let et = Process()
        et.executableURL = URL(fileURLWithPath: "/bin/ps")
        et.arguments = ["-o", "etime=", "-p", "\(pid)"]
        let ep = Pipe(); et.standardOutput = ep
        try? et.run(); et.waitUntilExit()
        let etime = (String(data: ep.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let young = etime.count <= 5 && etime.hasPrefix("00:")   // "00:SS" = under a minute
        print("running (pid \(pid)) but no health file\(young ? " yet (written every 30s)" : " — state dir unwritable?")")
        exit(young ? 0 : 1)
    }
    let now = Date().timeIntervalSince1970
    if now - h.updatedEpoch > 90 {
        print("running (pid \(pid)) but heartbeat stale (\(Int(now - h.updatedEpoch))s) — main thread hung? (a Mac that just woke reads stale briefly)")
        exit(1)
    }
    if !h.tapAlive {
        print("running (pid \(pid)) but tap DEAD — check System Settings ▸ Accessibility for multistreamviewer")
        exit(1)
    }
    var note = ""
    if now - h.lastTickEpoch > 90 {
        note = " — engine tick stalled \(Int(now - h.lastTickEpoch))s (degraded window list?)"
    }
    print("running (pid \(pid)), tap alive, \(h.windowCount) windows in \(h.groupCount) desktops (current: \(h.currentGroup))\(note)")
    exit(0)
}

func runApp() -> Never {
    // Single instance: two taps would double-consume ⌘⇥. A lock file we can't open
    // (e.g. left root-owned) must not block startup — degrade to no lock.
    let lockFD = open("/tmp/multistreamviewer-\(getuid()).lock", O_CREAT | O_RDWR, 0o644)
    if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        die("multistreamviewer: already running")
    }
    // NOTE: permissions are NOT checked here. A menu-bar app launched from Finder has no
    // stderr, so exiting on a missing grant looks like "nothing happened" and leaves no
    // way to fix it. AppDelegate starts the UI first, then waits for Accessibility.
    MainActor.assumeIsolated {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let verbs = ["new", "gather", "show", "hide", "toggle", "settings", "switch.next"]
            + (1...32).map { "switch.\($0)" } + (1...32).map { "send.\($0)" }
        for verb in verbs {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let n = name?.rawValue as String? else { return }
                    DispatchQueue.main.async { handleVerb(n) }
                },
                Notify.prefixed(verb) as CFString, nil, .deliverImmediately)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
    exit(0)
}

@MainActor
func handleVerb(_ name: String) {
    let verb = name.replacingOccurrences(of: Notify.prefix, with: "")
    switch verb {
    case "new": Engine.shared.newGroup()
    case "gather": Engine.shared.gatherAll()
    case "show", "toggle": Overlay.shared.toggle()
    case "hide": Overlay.shared.hide()
    case "settings": SettingsWindow.shared.show()
    default:
        if verb == "switch.next" {
            Engine.shared.jumpNext()
        } else if verb.hasPrefix("switch."), let n = Int(verb.dropFirst(7)) {
            Engine.shared.jumpToIndex(n - 1)
        } else if verb.hasPrefix("send."), let n = Int(verb.dropFirst(5)) {
            Engine.shared.sendFocused(toIndex: n - 1)
        }
    }
}

let args = CommandLine.arguments.dropFirst()
if let cmd = args.first {
    func intArg(_ what: String) -> Int {
        guard let a = args.dropFirst().first, let n = Int(a), (1...32).contains(n)
        else { die("usage: multistreamviewer \(what) <1-32>") }
        return n
    }
    switch cmd {
    case "new", "gather", "show", "hide", "toggle", "settings":
        post(cmd)
    case "next":
        post("switch.next")
    case "switch":
        if args.dropFirst().first == "next" { post("switch.next") }
        else { post("switch.\(intArg("switch"))") }
    case "send":
        post("send.\(intArg("send"))")
    case "run":
        runApp()
    case "status":
        runStatus()
    case "windows":
        // Runs in this process, not the running app — so the terminal needs Accessibility,
        // same as any AX read.
        MainActor.assumeIsolated { print(WindowTruth.debugDump()) }
    default:
        die("usage: multistreamviewer [run|status|show|hide|toggle|settings|new|gather|next|switch <N|next>|send <N>|windows]")
    }
    exit(0)
} else {
    runApp()
}
