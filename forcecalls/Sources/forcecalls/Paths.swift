import Foundation

/// Single source of truth for every on-disk path and launchd label.
///
/// TRUST SPLIT (demonlock's shape): `calls.json` is ROOT-owned and the daemon is its only writer, so
/// you can't hand-edit a forced call away. The CLI is no-sudo and talks to the daemon by dropping
/// markers in a USER-owned `inbox/`. Tightening (add) lands immediately; loosening (remove) is
/// delay-gated — the wait is the commitment device.
enum Paths {
    static let daemonLabel = "com.minh.forcecalls.daemon"

    static let supportDir  = "/Library/Application Support/Forcecalls"  // root-owned
    static let credsFile   = supportDir + "/creds.json"     // root:wheel 600 — SignalWire keys
    static let settingsFile = supportDir + "/settings.json" // root 644 — enforcedUser, delays
    static let callsFile   = supportDir + "/calls.json"     // root 644 — [ForcedCall], daemon writes
    static let stateFile   = supportDir + "/state.json"     // root 644 — fired history + pending removals
    static let logsDir     = supportDir + "/logs"
    static let daemonLog   = logsDir + "/daemon.log"

    /// User-owned drop box: the no-sudo CLI writes markers here, the daemon consumes them.
    static let inboxDir    = supportDir + "/inbox"

    static let binaryPath  = "/usr/local/libexec/forcecalls"
    static let cliWrapper  = "/usr/local/bin/forcecalls"
    static let daemonPlist = "/Library/LaunchDaemons/com.minh.forcecalls.daemon.plist"
}
