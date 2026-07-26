import Foundation

/// Single source of truth for every on-disk path, launchd label, and identifier.
enum Paths {
    static let bundleID        = "com.demonlock"
    static let enforcerdLabel  = "com.demonlock.enforcerd"
    static let agentLabel      = "com.demonlock.agent"

    static let supportDir      = "/Library/Application Support/Demonlock"
    static let policyFile      = supportDir + "/policy.txt"
    static let zonesFile       = supportDir + "/zones.json"
    static let settingsFile    = supportDir + "/settings.json"
    static let armedFile       = supportDir + "/armed"
    static let snoozeFile      = supportDir + "/snooze"
    static let stateFile       = supportDir + "/state.json"
    static let heldFixFile     = supportDir + "/heldfix.json"
    static let logsDir         = supportDir + "/logs"
    static let enforcerdLog    = logsDir + "/enforcerd.log"

    // Release valve. Config + lifecycle state are root-owned (only `--set-*`/the daemon write them);
    // the inbox is a USER-owned subdir so `--request`/`abort` can drop a marker without sudo (the
    // daemon stamps the real request time itself, so the delay can't be backdated).
    static let rvConfigFile    = supportDir + "/releasevalve.json"   // {windowPolicy, delaySec, durationSec}
    static let rvStateFile     = supportDir + "/rv-state.json"       // {requestedAt, eligibleAt, grantedAt, grantExpiresAt}
    static let rvInboxDir      = supportDir + "/rv"
    static let rvRequestMarker = rvInboxDir + "/request"
    static let rvAbortMarker   = rvInboxDir + "/abort"

    static let socketPath      = "/var/run/demonlock.sock"

    static let appPath         = "/Applications/Demonlock.app"
    static let binaryPath      = appPath + "/Contents/MacOS/demonlock"
    static let cliWrapper      = "/usr/local/bin/demonlock"
    static let sudomeBin       = "/usr/local/bin/sudome"    // release-valve grants/revokes admin via this

    static let enforcerdPlist  = "/Library/LaunchDaemons/com.demonlock.enforcerd.plist"
    static let agentPlist      = "/Library/LaunchAgents/com.demonlock.agent.plist"
}
