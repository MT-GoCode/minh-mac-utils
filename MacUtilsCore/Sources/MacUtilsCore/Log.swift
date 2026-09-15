import Foundation

public func nowEpoch() -> Double { Date().timeIntervalSince1970 }

/// A timestamped stderr log line for daemon subsystems. Format: `[yyyy-MM-dd HH:mm:ss] message`.
public func logStderr(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
}

public func errOut(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Print to stderr and exit 1 — the CLI's uniform failure path.
public func fail(_ msg: String) -> Never { errOut(msg); exit(1) }

/// Privileged commands require real root (run via sudo). The caller supplies its exact message so
/// no tool's stderr text changes.
public func requireRoot(or message: String) {
    if geteuid() != 0 { fail(message) }
}
