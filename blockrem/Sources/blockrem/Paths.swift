import Foundation

/// Single source of truth for every on-disk path, launchd label, and identifier.
enum Paths {
    static let bundleID        = "com.blockrem"
    static let enforcerdLabel  = "com.blockrem.enforcerd"
    static let agentLabel      = "com.blockrem.agent"

    static let supportDir      = "/Library/Application Support/Blockrem"
    static let scheduleFile    = supportDir + "/schedule.json"   // [Alarm] — root-owned, sudo to change
    static let settingsFile    = supportDir + "/settings.json"   // per-machine (enforcedUser)
    static let snoozeFile      = supportDir + "/snooze"          // epoch or "null"
    static let activeFile      = supportDir + "/active.json"     // published each tick (the agent's read surface)
    static let logsDir         = supportDir + "/logs"
    static let enforcerdLog    = logsDir + "/enforcerd.log"

    static let appPath         = "/Applications/Blockrem.app"
    static let binaryPath      = appPath + "/Contents/MacOS/blockrem"
    static let cliWrapper      = "/usr/local/bin/blockrem"

    static let enforcerdPlist  = "/Library/LaunchDaemons/com.blockrem.enforcerd.plist"
    static let agentPlist      = "/Library/LaunchAgents/com.blockrem.agent.plist"
}
