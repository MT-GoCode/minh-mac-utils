import Foundation

/// Consume markers dropped by the no-sudo CLI into the user-owned inbox.
///
/// Hardened the way demonlock's MarkerIO is: open with O_NOFOLLOW so a symlink planted in a
/// user-writable dir can't turn the root daemon into a read primitive, require the file be owned by
/// the enforced user, and verify the unlink actually removed it (a `chflags uchg` marker that can't
/// be deleted must not re-fire every tick).
///
/// Markers are named `<millis>-<rand>.<kind>` and drained in FILENAME order, so the daemon replays
/// your requests in the order you made them. That ordering is load-bearing: `remove` then `abort`
/// must cancel, and `abort` then `remove` must not.
enum MarkerIO {

    struct Marker {
        var kind: String   // "add" | "remove" | "abort" | "testcall"
        var body: String
    }

    static let kinds = ["add", "remove", "abort", "testcall"]

    static func drainAll(enforcedUID: uid_t) -> [Marker] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.inboxDir) else { return [] }
        var out: [Marker] = []
        for name in names.sorted() {
            guard let kind = kinds.first(where: { name.hasSuffix("." + $0) }) else { continue }
            guard let body = consume(Paths.inboxDir + "/" + name, enforcedUID: enforcedUID) else { continue }
            out.append(Marker(kind: kind, body: body))
        }
        return out
    }

    private static func consume(_ path: String, enforcedUID: uid_t) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == enforcedUID, (st.st_mode & S_IFMT) == S_IFREG else {
            logStderr("marker rejected (not a regular file owned by the enforced user): \(path)")
            unlink(path)
            return nil
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count <= 64 * 1024 {           // markers are tiny; refuse to slurp a big file
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        unlink(path)
        if FileManager.default.fileExists(atPath: path) {
            logStderr("marker could not be removed (immutable?) — ignoring: \(path)")
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CLI side: drop a marker under a unique, time-ordered name so two requests in one tick can
    /// neither clobber each other nor be replayed out of order.
    static func drop(kind: String, body: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.inboxDir) else {
            throw ForceError(message: "forcecalls isn't installed (no \(Paths.inboxDir)) — run: sudo ./install.sh")
        }
        // An inbox that exists but isn't yours means a partial or stale install: the installer is
        // what chowns it to the enforced user. Say so, rather than surfacing a bare "permission
        // denied" that reads like a bug in the CLI.
        guard fm.isWritableFile(atPath: Paths.inboxDir) else {
            throw ForceError(message: """
                the inbox at \(Paths.inboxDir) isn't writable by you — the install didn't finish.
                re-run: sudo ./install.sh
                """)
        }
        let name = String(format: "%013.0f-%@.%@", nowEpoch() * 1000, String(UUID().uuidString.prefix(8)), kind)
        do { try body.write(toFile: Paths.inboxDir + "/" + name, atomically: true, encoding: .utf8) }
        catch { throw ForceError(message: "couldn't write to the inbox: \(error.localizedDescription)") }
    }
}
