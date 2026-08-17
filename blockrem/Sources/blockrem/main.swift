import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"
let rest = Array(argv.dropFirst())

switch cmd {
// long-running roles (launchd)
case "enforcerd":            Enforcer().run()
case "agent":               runAgent()

// user commands
case "list", "ls":          runList()
case "perm-ask":            runPermAsk()

// sudo commands
case "set":                 runSet(rest)
case "delete", "rm":        runDelete(rest)
case "snooze":              runSnooze(rest)

// internal
case "_selftest":           runSelfTest()

case "help", "--help", "-h": printHelp()

default:
    if argv.contains("agent") { runAgent() }
    else { printHelp() }
}
