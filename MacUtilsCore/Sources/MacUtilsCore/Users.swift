import Foundation

/// Resolve a username OR numeric-uid string to a uid. nil if empty/unknown.
public func resolveUID(_ s: String) -> uid_t? {
    let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.isEmpty { return nil }
    if let n = UInt32(v) { return uid_t(n) }
    return v.withCString { cstr -> uid_t? in
        guard let pw = getpwnam(cstr) else { return nil }
        return pw.pointee.pw_uid
    }
}

/// uid → login name (getpwuid). nil if unknown.
public func userName(for uid: uid_t) -> String? {
    guard let pw = getpwuid(uid) else { return nil }
    return String(cString: pw.pointee.pw_name)
}

/// uid of the user owning the live console session (the `/dev/console` owner), or nil if none /
/// root (login window). `/dev/console` is a device node, never a symlink, so stat == lstat here.
public func consoleUID() -> uid_t? {
    var st = stat()
    guard lstat("/dev/console", &st) == 0, st.st_uid != 0 else { return nil }
    return st.st_uid
}
