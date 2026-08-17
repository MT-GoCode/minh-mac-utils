import Foundation

/// Single source of truth for every on-disk path, launchd label, and identifier.
enum Paths {
    static let bundleID        = "com.minh.blockrem"
    static let enforcerdLabel  = "com.minh.blockrem.enforcerd"
    static let agentLabel      = "com.minh.blockrem.agent"

    static let supportDir      = "/Library/Application Support/Blockrem"   // root-owned (uninstall needs sudo)
    static let settingsFile    = supportDir + "/settings.json"   // per-machine (enforcedUser) — root-owned
    static let activeFile      = supportDir + "/active.json"     // published each tick (the agent's read surface)
    static let logsDir         = supportDir + "/logs"
    static let enforcerdLog    = logsDir + "/enforcerd.log"

    // User-managed data: set/delete/snooze run WITHOUT sudo, so these live in a subdir owned by the
    // enforced user (atomic writes need a writable dir). The app/daemon/plists stay root-owned, so
    // you still can't UNINSTALL or stop the daemon without sudo — only manage your own alarms.
    static let dataDir         = supportDir + "/data"
    static let scheduleFile    = dataDir + "/schedule.json"      // [Alarm]
    static let snoozeFile      = dataDir + "/snooze"             // epoch or "null"

    static let appPath         = "/Applications/Blockrem.app"
    static let binaryPath      = appPath + "/Contents/MacOS/blockrem"
    static let cliWrapper      = "/usr/local/bin/blockrem"

    static let enforcerdPlist  = "/Library/LaunchDaemons/com.minh.blockrem.enforcerd.plist"
    static let agentPlist      = "/Library/LaunchAgents/com.minh.blockrem.agent.plist"
}
