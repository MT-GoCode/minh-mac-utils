import AppKit

// CLI dispatch: subcommands post a Darwin notification to the running app.
// No arguments (or `run`) starts the menu-bar app itself.
enum Notify {
    static let prefix = "com.minh.msv."
    static func prefixed(_ s: String) -> String { prefix + s }
}

let args = CommandLine.arguments.dropFirst()

func post(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(Notify.prefixed(name) as CFString), nil, nil, true)
}

func runApp() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

if let cmd = args.first {
    switch cmd {
    case "show", "hide", "toggle", "new":
        post(cmd)
    case "switch":
        guard let arg = args.dropFirst().first,
            arg == "next" || Int(arg).map((1...32).contains) == true
        else {
            FileHandle.standardError.write("usage: msv switch <1-32|next>\n".data(using: .utf8)!)
            exit(2)
        }
        post("switch.\(arg)")
    case "run":
        runApp()
    default:
        FileHandle.standardError.write(
            "usage: msv [show|hide|toggle|new|switch N|next|run]\n".data(using: .utf8)!)
        exit(2)
    }
    exit(0)
} else {
    runApp()
}
