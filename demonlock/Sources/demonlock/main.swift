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

// sudo commands
case "setpolicy":                          runSetPolicy(argv.dropFirst().joined(separator: " "))
case "snoozetonight":                       runSnoozeTonight()
case "arm":                                runArm()
case "disarm":                             runDisarm()

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
