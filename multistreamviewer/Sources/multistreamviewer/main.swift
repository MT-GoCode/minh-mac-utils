import AppKit

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
    case "windows":
        // Runs in this process, not the running app — so the terminal needs Accessibility,
        // same as any AX read.
        MainActor.assumeIsolated { print(WindowTruth.debugDump()) }
    default:
        die("usage: multistreamviewer [run|show|hide|toggle|settings|new|gather|next|switch <N|next>|send <N>|windows]")
    }
    exit(0)
} else {
    runApp()
}
