import Foundation

let argv = Array(CommandLine.arguments.dropFirst())

switch argv.first {
case "show", "list", nil:
    Commands.show()
case "add":
    Commands.add(Array(argv.dropFirst()))
case "remove", "rm":
    Commands.remove(Array(argv.dropFirst()))
case "testcall", "test":
    Commands.testcall(Array(argv.dropFirst()))
case "abort":
    Commands.abort()
case "daemon":
    // launchd entry point — the root side. Never returns.
    Daemon.run()
case "presence":
    Commands.presence()
case "selftest":
    SelfTest.run()
case "help", "-h", "--help":
    Commands.help()
case .some(let other):
    FileHandle.standardError.write(Data("unknown command '\(other)' — try: forcecalls help\n".utf8))
    exit(2)
}
