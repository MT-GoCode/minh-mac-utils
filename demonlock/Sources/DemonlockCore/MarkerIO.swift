import Foundation

/// Hardened user↔root inbox I/O — BOTH directions live here; no code outside MarkerIO touches the
/// inbox. The rv/ inbox is USER-owned, so a marker could be a symlink OR a hardlink to a root-owned
/// file; a naive `Data(contentsOf:)` follows it and lets the root daemon read an arbitrary file as
/// "payload" (a read primitive — critical once secrets live under $SUPPORT). Daemon reads:
///   • O_NOFOLLOW  — refuse a symlink (returns ELOOP).
///   • fstat: regular file AND st_uid == enforcedUID — the OWNER check is what defeats the
///     hardlink-to-a-root-file trick; O_NOFOLLOW alone does not (a hardlink isn't a symlink).
///   • unlink-and-verify BEFORE returning — a marker made user-immutable (`chflags uchg`) can't be
///     removed, so it would re-fire every tick (a standing auto-request). If we can't consume it, we
///     act on nothing. (review H5 / M5)
///
/// Markers are NDJSON-ish: one ESCAPED payload per line ("\" → "\\", newline → "\n", escape
/// backslash first), so multi-line payloads (policy expressions) survive line framing. Writers
/// APPEND under flock; the daemon consumes whole files under a NON-BLOCKING flock.
enum MarkerIO {
    // MARK: - writers (CLI / UI side — the user writing into their own inbox)

    /// Append one escaped line (nil ⇒ create/TRUNCATE to a zero-byte file — the abort-all signal
    /// must CLEAR stale key lines; O_APPEND would leave them and silently narrow the abort).
    /// Created with `mode` from the START (no umask window). When mode != 0o644 the caller is
    /// writing a secret: unlink first + O_EXCL, so an attacker-precreated 0644 file can't keep its
    /// mode (open() ignores `mode` on existing files).
    @discardableResult
    static func append(_ path: String, line: String?, mode: mode_t = 0o644) -> Bool {
        append(path, lines: line.map { [$0] } ?? [], truncate: line == nil, mode: mode)
    }

    /// Atomic multi-line append: ONE write() of the joined escaped buffer, so the daemon can never
    /// consume between the lines (a zone edit's del+add must land together or not at all).
    @discardableResult
    static func append(_ path: String, lines: [String], mode: mode_t = 0o644) -> Bool {
        append(path, lines: lines, truncate: false, mode: mode)
    }

    private static func append(_ path: String, lines: [String], truncate: Bool, mode: mode_t) -> Bool {
        var flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (truncate ? O_TRUNC : O_APPEND)
        if mode != 0o644 {
            // Secret marker: must be exactly `mode` from the first byte. Reuse (append to) an existing
            // file ONLY if it's already a regular, single-link, self-owned file with that exact mode —
            // so two adds inside one tick both survive; anything else is recreated fresh (O_EXCL, so
            // an attacker-precreated 0644 file can't keep its mode).
            var st = stat()
            let reusable = lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
                && st.st_nlink == 1 && st.st_uid == getuid() && (st.st_mode & 0o777) == mode
            if !reusable { unlink(path); flags |= O_EXCL }
        }
        let fd = open(path, flags, mode)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        if lines.isEmpty { return true }                     // zero-byte (truncate) case
        let buf = lines.map { escape($0) + "\n" }.joined()
        let data = Array(buf.utf8)
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    // MARK: - daemon-side consumption

    /// Consume a marker: all COMPLETE lines, unescaped, in file order. nil ⇒ absent / symlink /
    /// fifo / wrong owner / lock contended / over-cap / unremovable. [] ⇒ genuine zero-byte file
    /// (the flag / abort-all signal). A trailing partial line is discarded + logged; a file over
    /// the 1 MiB cap is rejected WHOLE (unlinked + logged) — never act on a truncated prefix.
    static func consumeLines(_ path: String, enforcedUID: uid_t) -> [String]? {
        // O_NONBLOCK is load-bearing: a no-sudo user can `mkfifo` a marker path, and a FIFO is NOT a
        // symlink so O_NOFOLLOW doesn't catch it — a plain O_RDONLY open would BLOCK the single-threaded
        // daemon forever (permanent enforcement DoS). O_NONBLOCK returns immediately; the S_IFREG fstat
        // below then rejects the FIFO. Harmless for regular files (always read-ready).
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return nil }                        // absent, or a symlink (O_NOFOLLOW → ELOOP)
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,          // regular file only (not fifo/dev/dir)
              st.st_uid == enforcedUID else {            // owner-pinned: blocks hardlink-to-root-file
            unlinkHardened(path); return nil
        }

        // NON-BLOCKING flock, for the same reason as O_NONBLOCK above: the inbox is user-owned, so a
        // hostile process holding a blocking flock would wedge the single-threaded root enforcer
        // forever. Contended ⇒ leave the marker for the next tick (writers hold it for microseconds).
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            logThrottled("marker \(path) flock-contended — retrying next tick"); return nil
        }
        defer { flock(fd, LOCK_UN) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if data.count > (1 << 20) {                  // 1 MiB cap — reject the WHOLE file
                logStderr("marker \(path) exceeds 1 MiB — rejected whole")
                unlinkHardened(path); return nil
            }
            let n = read(fd, &buf, buf.count)
            if n < 0 { unlinkHardened(path); return nil }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }

        // Must be consumable, or it re-fires forever. If not, act on nothing.
        guard unlinkHardened(path) else { return nil }

        guard !data.isEmpty else { return [] }           // zero-byte flag / abort-all
        var text = String(decoding: data, as: UTF8.self)
        var partial: Substring? = nil
        if !text.hasSuffix("\n") {                       // torn write: drop the partial tail
            if let i = text.lastIndex(of: "\n") {
                partial = text[text.index(after: i)...]
                text = String(text[...i])
            } else { partial = Substring(text); text = "" }
        }
        if let p = partial, !p.isEmpty { logStderr("marker \(path): discarded partial trailing line (\(p.count) bytes)") }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(text.hasSuffix("\n") ? 1 : 0)      // split artifact after trailing \n
            .map { unescape(String($0)) }
    }

    /// Single-value markers (rv request, invoke, lockbox names, removes): LAST non-empty line —
    /// preserves today's last-write-wins-by-truncation semantics under the append writer.
    static func consumeLast(_ path: String, enforcedUID: uid_t) -> String? {
        guard let lines = consumeLines(path, enforcedUID: enforcedUID) else { return nil }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { !$0.isEmpty })
    }

    /// True iff a genuine, owner-owned, removable marker existed (and was consumed). For flag
    /// markers whose only signal is existence.
    static func consumeFlag(_ path: String, enforcedUID: uid_t) -> Bool {
        consumeLines(path, enforcedUID: enforcedUID) != nil
    }

    // MARK: - escaping (escape backslash FIRST; unescape in the mirror order)

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ s: String) -> String {
        var out = String(); out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let d = it.next() {
                out.append(d == "n" ? "\n" : d)
            } else { out.append(c) }
        }
        return out
    }

    // MARK: - internals

    /// Remove a marker and confirm it's gone. Root can clear a user-immutable (`uchg`) flag then unlink,
    /// so a stuck marker self-heals instead of wedging the inbox; returns false only if it truly can't
    /// be removed (caller then acts on nothing).
    @discardableResult
    private static func unlinkHardened(_ path: String) -> Bool {
        if unlink(path) == 0 { return true }
        _ = lchflags(path, 0)                            // lchflags (NOT chflags): never follow a symlink
                                                         // swapped in after the failed unlink; clears uchg
        if unlink(path) == 0 { return true }
        var st = stat()
        return lstat(path, &st) != 0                     // already gone == success
    }

    /// ≤ one log line per path per minute (the contended-flock skip fires every tick otherwise).
    private static var lastLog: [String: Double] = [:]
    private static func logThrottled(_ s: String) {
        let now = Date().timeIntervalSince1970
        if now - (lastLog[s] ?? 0) >= 60 { lastLog[s] = now; logStderr(s) }
    }
}
