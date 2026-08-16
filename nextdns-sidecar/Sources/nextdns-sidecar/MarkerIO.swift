import Foundation

/// Hardened consumption of user-dropped inbox markers (inlined from demonlock — can't import its module).
/// The inbox is USER-owned, so a marker could be a symlink OR a hardlink to a root-owned file; a naive
/// `Data(contentsOf:)` follows it and turns the root daemon into an arbitrary-file read primitive (bad
/// once creds live under the config dir). Every marker the daemon reads goes through here:
///   • O_NOFOLLOW  — refuse a symlink (returns ELOOP).
///   • fstat: regular file AND st_uid == enforcedUID — the OWNER check defeats the hardlink-to-a-root-
///     file trick; O_NOFOLLOW alone does not (a hardlink isn't a symlink).
///   • unlink-and-verify BEFORE returning — a marker made user-immutable (`chflags uchg`) can't be
///     removed, so it would re-fire every tick; if we can't consume it, we act on nothing.
/// The daemon is the sole caller. CLI-side marker DROPS stay ordinary writes; the trust boundary is the
/// daemon's READ, which is here.
enum MarkerIO {
    /// Consume a marker: return its bytes, or nil if absent / a symlink / not owned by enforcedUID /
    /// not removable. Unlinked before its bytes are returned, so a consumed marker never fires twice.
    static func consume(_ path: String, enforcedUID: uid_t) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return nil }                         // absent, or a symlink (O_NOFOLLOW → ELOOP)
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,           // regular file only (not fifo/dev/dir)
              st.st_uid == enforcedUID else {             // owner-pinned: blocks hardlink-to-root-file
            unlinkHardened(path); return nil
        }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        readLoop: while data.count <= (1 << 20) {         // 1 MiB cap — markers are tiny
            let n = read(fd, &buf, buf.count)
            if n < 0 { unlinkHardened(path); return nil }
            if n == 0 { break readLoop }
            data.append(contentsOf: buf[0..<n])
        }

        guard unlinkHardened(path) else { return nil }    // must be consumable, or it re-fires forever
        return data
    }

    /// True iff a genuine, owner-owned, removable marker existed (and was consumed). For flag-only markers.
    static func consumeFlag(_ path: String, enforcedUID: uid_t) -> Bool {
        consume(path, enforcedUID: enforcedUID) != nil
    }

    /// Remove a marker and confirm it's gone. Root can clear a user-immutable (`uchg`) flag then unlink,
    /// so a stuck marker self-heals; returns false only if it truly can't be removed.
    @discardableResult
    private static func unlinkHardened(_ path: String) -> Bool {
        if unlink(path) == 0 { return true }
        _ = chflags(path, 0)                              // clear uchg/nodump etc. (root); best-effort
        if unlink(path) == 0 { return true }
        var st = stat()
        return lstat(path, &st) != 0                      // already gone == success
    }
}
