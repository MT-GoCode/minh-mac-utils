import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"

switch cmd {
// long-running roles (launchd)
case "enforcerd":                          Enforcer().run()
case "agent":                              runAgent()

// user commands (one canonical name each — no aliases)
case "status":                             runStatus()
case "scan":                               runScan()
case "zones":                              argv.dropFirst().contains("list") ? runZoneList() : runZones()
case "perm-ask":                           runPermAsk()
case "test-lockout":                       runTestLockout(Array(argv.dropFirst()))

// no sudo — self-serve delayed changes (land after 36h)
case "delay-set-policy":                   runDelaySetPolicy(Array(argv.dropFirst()))
case "delayzones":                         runDelayZones(Array(argv.dropFirst()))

// sudo commands
case "setpolicy":                          runSetPolicy(argv.dropFirst().joined(separator: " "))
case "snooze":                             runSnooze(argv.dropFirst().joined(separator: " "))
case "admin-release-valve":                runReleaseValve(Array(argv.dropFirst()))
case "arm":                                runArm()
case "nosudo":                             runNoSudo()
case "disarm":                             runDisarm()
case "safe-apps":                          runSafeApps(Array(argv.dropFirst()))
case "snooze-preset":                      runSnoozePreset(Array(argv.dropFirst()))
case "password-lockbox":                   runLockbox(Array(argv.dropFirst()))
case "settings-guard":
    switch argv.dropFirst().first {
    case "dump": SettingsGuard.dump()
    default:     SettingsGuard.status()
    }

// internal
case "_policytest":                        runPolicyTest()

case "help", "--help", "-h":               printHelp()

default:
    // also covers `open --args scan/agent`, which can reorder argv
    if argv.contains("scan") { runScan() }
    else if argv.contains("agent") { runAgent() }
    else { printHelp() }
}
