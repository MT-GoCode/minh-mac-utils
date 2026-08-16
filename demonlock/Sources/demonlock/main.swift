import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"

switch cmd {
// long-running roles (launchd)
case "enforcerd":                          Enforcer().run()
case "agent":                              runAgent()

// user commands
case "status":                             runStatus()
case "scan":                               runScan()
case "zones", "view-zones", "edit-zones":  argv.dropFirst().contains("list") ? runZoneList() : runZones()
case "list-zones":                         runZoneList()
case "perm-ask":                           runPermAsk()

// no sudo — self-serve delayed changes (land after 36h)
case "delaysetpolicy", "delay-set-policy": runDelaySetPolicy(Array(argv.dropFirst()))
case "delayzones":                         runDelayZones(Array(argv.dropFirst()))

// sudo commands
case "setpolicy":                          runSetPolicy(argv.dropFirst().joined(separator: " "))
case "snooze":                             runSnooze(argv.dropFirst().joined(separator: " "))
case "release-valve", "rv",
     "admin-release-valve", "arv":         runReleaseValve(Array(argv.dropFirst()))
case "arm":                                runArm()
case "nosudo":                             runNoSudo()
case "disarm":                             runDisarm()
case "safe-apps", "safeapps":              runSafeApps(Array(argv.dropFirst()))
case "snooze-preset", "snooze-presets":    runSnoozePreset(Array(argv.dropFirst()))
case "password-lockbox", "lockbox":        runLockbox(Array(argv.dropFirst()))
case "settings-guard":
    switch argv.dropFirst().first {
    case "dump": SettingsGuard.dump()
    default:     SettingsGuard.status()
    }

// internal
case "_policytest":                        runPolicyTest()
case "_zonedel":                           runZoneDelete(argv.dropFirst().joined(separator: " "))

case "help", "--help", "-h":               printHelp()

default:
    // also covers `open --args scan/agent`, which can reorder argv
    if argv.contains("scan") { runScan() }
    else if argv.contains("agent") { runAgent() }
    else { printHelp() }
}
