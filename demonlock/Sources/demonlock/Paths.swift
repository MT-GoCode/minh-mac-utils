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
    static let enforcedUIDCacheFile = supportDir + "/enforced-uid"   // last-resolved enforced uid, survives restart
    static let logsDir         = supportDir + "/logs"
    static let enforcerdLog    = logsDir + "/enforcerd.log"

    // Release valve. Config + lifecycle state are root-owned (only `--set-*`/the daemon write them);
    // the inbox is a USER-owned subdir so `--request`/`abort` can drop a marker without sudo (the
    // daemon stamps the real request time itself, so the delay can't be backdated).
    static let rvConfigFile    = supportDir + "/releasevalve.json"   // {gatePolicy, delaySec, maxRequestDurationSec}
    static let rvStateFile     = supportDir + "/rv-state.json"       // {requestedAt, eligibleAt, grantedAt, grantExpiresAt}
    static let rvInboxDir      = supportDir + "/rv"
    static let rvRequestMarker = rvInboxDir + "/request"
    static let rvAbortMarker   = rvInboxDir + "/abort"

    // Delayed changes: a non-sudo user queues a new policy / zones set that lands after a fixed delay.
    // Root-owned pending state; the request/abort markers live in the same user-owned inbox as the
    // release valve (the request marker's CONTENTS are the payload; the daemon stamps the real time).
    static let delayedPolicyFile   = supportDir + "/delayed-policy.json"     // {pending, lastAppliedAt}
    static let dspRequestMarker    = rvInboxDir + "/delay-set-policy"          // CONTENTS = the new policy text
    static let dspAbortMarker      = rvInboxDir + "/delay-set-policy-abort"
    static let delayedZonesFile    = supportDir + "/delayed-zones.json"      // {pending, lastAppliedAt}
    static let dzRequestMarker     = rvInboxDir + "/delayzones"              // CONTENTS = the new zones.json
    static let dzAbortMarker       = rvInboxDir + "/delayzones-abort"

    // Delayed release-valve gate-policy change (no sudo; lands after gatePolicyDelaySec).
    static let delayedGatePolicyFile = supportDir + "/delayed-gatepolicy.json"
    static let dgpRequestMarker    = rvInboxDir + "/delaysetgatepolicy"      // CONTENTS = the new gate policy
    static let dgpAbortMarker      = rvInboxDir + "/delaysetgatepolicy-abort"


    // safe-apps: a name-keyed registry of pending delayed registrations (root-owned), plus user markers.
    // register = a delayed add (contents = SafeApp JSON); remove = immediate tighten (contents = name);
    // abort = drop a pending add (contents = name or "--all").
    static let safeAppsPendingFile = supportDir + "/safe-apps-pending.json"
    static let saRegisterMarker    = rvInboxDir + "/safeapp-register"
    static let saRemoveMarker      = rvInboxDir + "/safeapp-remove"
    static let saAbortMarker       = rvInboxDir + "/safeapp-abort"

    // snooze-presets: a single in-flight invocation + a name-keyed registry of pending delayed-adds.
    static let snoozePresetsStateFile = supportDir + "/snooze-presets.json"
    static let spInvokeMarker  = rvInboxDir + "/snoozepreset-invoke"        // contents = preset name
    static let spInvokeAbort   = rvInboxDir + "/snoozepreset-invoke-abort"
    static let spAddMarker     = rvInboxDir + "/snoozepreset-add"           // contents = SnoozePreset JSON (delayed)
    static let spAddAbort      = rvInboxDir + "/snoozepreset-add-abort"     // contents = name or "--all"
    static let spRemoveMarker  = rvInboxDir + "/snoozepreset-remove"        // contents = name (immediate)

    // password-lockbox: secrets live in a SEPARATE 0600 root-only file (never settings.json, which is
    // 644). Lock state is published for `show` (names + lock state only, never secrets).
    static let lockboxFile      = supportDir + "/lockbox.json"          // 0600 root: [{name, secret, delaySec}]
    static let lockboxStateFile = supportDir + "/lockbox-state.json"    // pending unlocks + unlockedUntil
    static let lbUnlockMarker   = rvInboxDir + "/lockbox-unlock"        // contents = name
    static let lbAbortMarker    = rvInboxDir + "/lockbox-abort"         // contents = name
    static let lbCopyMarker     = rvInboxDir + "/lockbox-copy"          // contents = name
    static let lbAddMarker      = rvInboxDir + "/lockbox-add"           // contents = {name,secret,delaySec} JSON
    static let lbOutboxFile     = rvInboxDir + "/lockbox-out"           // daemon→CLI one-shot secret (0600 user-owned)

    static let socketPath      = "/var/run/demonlock.sock"

    static let appPath         = "/Applications/Demonlock.app"
    static let binaryPath      = appPath + "/Contents/MacOS/demonlock"
    static let cliWrapper      = "/usr/local/bin/demonlock"

    static let enforcerdPlist  = "/Library/LaunchDaemons/com.demonlock.enforcerd.plist"
    static let agentPlist      = "/Library/LaunchAgents/com.demonlock.agent.plist"
}
