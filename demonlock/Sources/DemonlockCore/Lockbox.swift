import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A delay-gated password manager for arbitrary secrets. NOT a privilege path — it does not hold the
/// admin password (admin is granted only by the release valve, no password anywhere). You `unlock` a
/// secret (no sudo); after its per-entry delay it's copyable for a short window, then auto-relocks (or
/// relocks the instant you `copy` it). Secrets live in a SEPARATE 0600 root-only file; only lock STATE
/// (names, unlocked-or-not, time left) is published for `show`. [reviews: separate from settings 644;
/// concealed pasteboard so clipboard managers don't retain the secret]

struct LockboxEntry: Codable, Equatable { var name: String; var secret: String; var delaySec: Double }

/// The 0600 root-only vault. Read/written only by the root daemon and root (sudo) CLI.
enum LockboxStore {
    static func load() -> [LockboxEntry] { loadJSON(Paths.lockboxFile) ?? [] }
    // secrets: root-only, never group/other-readable
    static func save(_ entries: [LockboxEntry]) { saveJSON(entries, to: Paths.lockboxFile, mode: 0o600) }
    static func names() -> [String] { load().map(\.name).sorted() }
}

enum Lockbox {
    struct Pending: Codable { var requestedAt: Double; var applyAt: Double }
    struct LBState: Codable {
        var pending: [String: Pending] = [:]      // name → pending unlock
        var unlockedUntil: [String: Double] = [:] // name → auto-relock time
        static func load() -> LBState { loadJSON(Paths.lockboxStateFile) ?? LBState() }
        func save() { saveJSON(self, to: Paths.lockboxStateFile) }
    }

    struct Status: Codable { var entries: [EntryView] = [] }
    struct EntryView: Codable { var name: String; var delaySec: Double; var unlocked: Bool; var unlockAtEpoch: Double? }

    static let maxSecretBytes = 4096
    static let maxEntries = 64

    static func rejectReason(_ name: String, delaySec: Double, secretLen: Int = 0, entryCount: Int = 0, nameExists: Bool = true) -> String? {
        guard (1...24).contains(name.count), name.allSatisfy({ ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" }) else {
            return "name must be 1–24 chars of [a-z0-9-]"
        }
        if delaySec < Bounds.lockboxUnlockDelayMin { return "unlock delay must be ≥ \(Int(Bounds.lockboxUnlockDelayMin/3600))h" }
        // Caps stop a no-sudo user bloating the root-owned lockbox.json (O(n²) rewrites, undeletable
        // growth). secretLen/entryCount default to skip-checks so the CLI early-check still works.
        if secretLen > maxSecretBytes { return "secret too large (max \(maxSecretBytes) bytes)" }
        if !nameExists && entryCount >= maxEntries { return "too many lockbox entries (max \(maxEntries)) — remove one first" }
        return nil
    }

    /// One daemon tick: consume markers (add/unlock/abort/remove/copy), apply due unlocks, auto-relock. All
    /// markers owner-checked via MarkerIO; secrets never transit a world-readable path. Returns status.
    @discardableResult
    static func tick(now: Double, enforcedUID: uid_t?) -> Status {
        var entries = LockboxStore.load()
        var st = LBState.load()

        if let euid = enforcedUID {
            // add (no sudo): the secret transits the user-owned inbox marker (acceptable — self-binding).
            if let data = MarkerIO.consume(Paths.lbAddMarker, enforcedUID: euid),
               let e = try? JSONDecoder().decode(LockboxEntry.self, from: data),
               rejectReason(e.name, delaySec: e.delaySec, secretLen: e.secret.utf8.count,
                            entryCount: entries.count, nameExists: entries.contains(where: { $0.name == e.name })) == nil {
                entries.removeAll { $0.name == e.name }
                entries.append(e); LockboxStore.save(entries)
                // Re-adding a secret resets any in-flight/open unlock for that name — else the NEW secret
                // inherits the OLD one's unlock window and is instantly copyable.
                st.pending.removeValue(forKey: e.name); st.unlockedUntil.removeValue(forKey: e.name); st.save()
            }
            // unlock (no sudo): start the per-entry delay if the entry exists and isn't already unlocked.
            if let data = MarkerIO.consume(Paths.lbUnlockMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let e = entries.first(where: { $0.name == name }), st.unlockedUntil[name] == nil, st.pending[name] == nil {
                    let delay = max(e.delaySec, Bounds.lockboxUnlockDelayMin)
                    st.pending[name] = Pending(requestedAt: now, applyAt: now + delay); st.save()
                }
            }
            // abort: cancel a pending unlock AND relock if unlocked.
            if let data = MarkerIO.consume(Paths.lbAbortMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                st.pending.removeValue(forKey: name); st.unlockedUntil.removeValue(forKey: name); st.save()
            }
            // remove (tightening): delete the entry from the vault entirely + clear any lock state.
            if let data = MarkerIO.consume(Paths.lbRemoveMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if entries.contains(where: { $0.name == name }) { entries.removeAll { $0.name == name }; LockboxStore.save(entries) }
                st.pending.removeValue(forKey: name); st.unlockedUntil.removeValue(forKey: name); st.save()
            }
            // copy: if unlocked, write the secret to a fresh 0600 user-owned outbox, then relock now.
            if let data = MarkerIO.consume(Paths.lbCopyMarker, enforcedUID: euid) {
                let name = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let until = st.unlockedUntil[name], now < until, let e = entries.first(where: { $0.name == name }) {
                    writeOutbox(e.secret, ownerUID: euid)
                    st.unlockedUntil.removeValue(forKey: name); st.save()   // relock immediately on copy
                }
            }
        }

        // apply due unlocks → unlocked for the auto-relock window.
        var changed = false
        for (name, p) in st.pending where now >= p.applyAt {
            st.unlockedUntil[name] = now + Bounds.lockboxAutoRelock
            st.pending.removeValue(forKey: name); changed = true
        }
        // auto-relock expired.
        for (name, until) in st.unlockedUntil where now >= until { st.unlockedUntil.removeValue(forKey: name); changed = true }
        if changed { st.save() }

        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Status(entries: byName.keys.sorted().map { name in
            EntryView(name: name, delaySec: byName[name]!.delaySec,
                      unlocked: st.unlockedUntil[name] != nil,
                      unlockAtEpoch: st.pending[name]?.applyAt)
        })
    }

    /// Write the secret to a fresh, exclusive, 0600 file the CLI (running as the owner) can read once.
    /// O_EXCL|O_NOFOLLOW so we never write through a pre-existing symlink the user planted.
    private static func writeOutbox(_ secret: String, ownerUID: uid_t) {
        unlink(Paths.lbOutboxFile)   // clear any stale one
        let fd = open(Paths.lbOutboxFile, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        _ = fchown(fd, ownerUID, 0)
        _ = secret.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    #if canImport(AppKit)
    /// Put the secret on the clipboard as a CONCEALED type so clipboard managers (Raycast, which is
    /// spared and keeps history) don't retain it, plus a plain string so paste works. [review L6]
    static func copyToConcealedPasteboard(_ secret: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(secret, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString(secret, forType: .string)
    }
    #endif
}
