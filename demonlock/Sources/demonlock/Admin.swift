import Foundation

/// Admin (sudo) grant/revoke, internalized from the retired setuid `sudome` binary. The enforcer is
/// already root, so there's no setuid dance and no shared-secret password: it edits the `admin` group
/// directly, which grants sudo through macOS's default `%admin` rule. EVERY grant path (release-valve)
/// and EVERY revoke path (release-valve expiry / abort, `arm`, `nosudo`) routes through here, so
/// revocation is uniform and idempotent. Only ever called from the root daemon or a root (`sudo`) CLI.
///
/// LIMITS — documented, not fixable, and by design out of the threat model: admin obtained during a
/// grant is not truly *contained*. A login session open during the grant keeps `admin` in its cached
/// supplementary groups after `dseditgroup -d`; a determined user can also plant residue revoke won't
/// clean (a differently-named /etc/sudoers.d file, a root LaunchDaemon, a root shell). That's inherent
/// to handing out real root. The REQUEST DELAY is the commitment gate; the auto-revoke is anti-accident
/// (stop sudo lingering by mistake — Minh's stated #1 lapse cause), not a containment boundary. [M1]
enum Admin {
    private static let dseditgroup = "/usr/sbin/dseditgroup"
    private static let sudoTSDir = "/var/db/sudo/ts"

    static func isAdmin(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "checkmember", "-m", user, "admin"]) == 0
    }

    /// Grant admin to `user` (idempotent). Effective on next login; a current shell picks it up on its
    /// next auth. Returns true on success.
    @discardableResult
    static func grant(_ user: String) -> Bool {
        Proc.run(dseditgroup, ["-o", "edit", "-a", user, "-t", "user", "admin"]) == 0
    }

    /// Revoke admin from `user` (idempotent — a no-op group edit if already not an admin). Also drops any
    /// stale per-user NOPASSWD override and wipes cached sudo timestamps so the revoke bites immediately
    /// in already-open terminals, not after sudo's 5-minute window. Returns true on success.
    @discardableResult
    static func revoke(_ user: String) -> Bool {
        let wasAdmin = isAdmin(user)
        let rc = wasAdmin ? Proc.run(dseditgroup, ["-o", "edit", "-d", user, "-t", "user", "admin"]) : 0
        clearSudoCache()
        return rc == 0
    }

    private static func clearSudoCache() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sudoTSDir) else { return }
        for e in entries { try? fm.removeItem(atPath: sudoTSDir + "/" + e) }
    }
}
