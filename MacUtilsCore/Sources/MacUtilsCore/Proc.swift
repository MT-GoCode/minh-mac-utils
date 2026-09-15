import Foundation

/// Small process-running helpers shared by daemons, watchdogs, and CLIs.
public enum Proc {
    /// Run to completion, return the exit status (-1 if it couldn't launch). By default the child
    /// inherits stdout/stderr (so `launchctl`/`killall` chatter lands in the daemon log, as it always
    /// has for demonlock/blockrem); `quiet: true` sends both to /dev/null.
    @discardableResult
    public static func run(_ path: String, _ args: [String], quiet: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    /// stdout as a String ("" on launch failure). stderr is discarded to /dev/null — never an
    /// undrained Pipe, which deadlocks the parent once the child writes >64 KiB.
    public static func capture(_ path: String, _ args: [String]) -> String {
        captureStatus(path, args).out
    }

    /// stdout AND exit status, for probes where "the command failed" and "the command succeeded but
    /// printed nothing" must not collapse into one verdict.
    public static func captureStatus(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
