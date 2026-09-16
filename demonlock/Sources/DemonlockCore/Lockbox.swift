import Foundation
import MacUtilsCore
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
    struct Pending: Codable { var requestedAt: Double; var applyAt: Double }   // legacy shape

    /// lockbox-state.json container: the unlocks DelayQueue owns `unlocksQ`; `unlockedUntil` is a
    /// SIBLING (window lifecycle, never queue state — a naive whole-file rewrite would erase every
    /// open window). COMPOSITE-FILE CONTRACT: bespoke tick code re-loads after every queue call.
    struct LBFile: Codable {
        var pending: [String: Pending]? = nil     // legacy (migrated then nil)
        var unlockedUntil: [String: Double] = [:] // name → auto-relock time (sibling)
        var unlocksQ: DelayQueue.QState? = nil
        static func load() -> LBFile { loadJSON(Paths.lockboxStateFile) ?? LBFile() }
        func save() { saveJSON(self, to: Paths.lockboxStateFile) }
    }

    static func unlocksQueue() -> DelayQueue {
        DelayQueue(kind: "lockbox-unlock",
                   store: DelayQueue.QStateStore(
                       load: {
                           let f = LBFile.load()
                           if var st = f.unlocksQ { st.fixSeq(); return st }
                           guard let legacy = f.pending, !legacy.isEmpty else { return DelayQueue.QState() }
                           var st = DelayQueue.QState()
                           for (n, p) in legacy.sorted(by: { ($0.value.requestedAt, $0.key) < ($1.value.requestedAt, $1.key) }) {
                               st.pending[n] = .init(payload: n, requestedAt: p.requestedAt, applyAt: p.applyAt, seq: st.nextSeq)
                               st.nextSeq += 1
                           }
                           return st
                       },
                       save: { st in
                           var f = LBFile.load()          // fresh — never clobber the sibling
                           f.unlocksQ = st; f.pending = nil
                           f.save()
                       }),
                   requestMarker: Paths.lbUnlockMarker, abortMarker: Paths.lbAbortMarker,
                   onFailure: .drop, payloadIsJSON: false, auditLog: Paths.queueAuditLog)
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

    /// One daemon tick. The unlocks DelayQueue owns pending unlocks (markers lbUnlock/lbAbort);
    /// bespoke code keeps add/remove/copy and the window lifecycle, RE-LOADING LBFile after every
    /// queue call (composite-file contract). ABORT STILL RELOCKS: the queue consumes the abort
    /// marker, so the aborted keys it returns drive the window clear.
    @discardableResult
    static func tick(now: Double, enforcedUID: uid_t?) -> (windows: Status, unlocks: DelayQueue.QStatus) {
        var entries = LockboxStore.load()
        let q = unlocksQueue()

        // add (no sudo): the secret transits the user-owned 0600 inbox marker (self-binding).
        if let euid = enforcedUID, let lines = MarkerIO.consumeLines(Paths.lbAddMarker, enforcedUID: euid) {
            for line in lines {   // every add in the tick lands (last write for a repeated name wins)
                guard let e = try? JSONDecoder().decode(LockboxEntry.self, from: Data(line.utf8)),
                      rejectReason(e.name, delaySec: e.delaySec, secretLen: e.secret.utf8.count,
                                   entryCount: entries.count, nameExists: entries.contains(where: { $0.name == e.name })) == nil
                else { continue }
                entries.removeAll { $0.name == e.name }
                entries.append(e); LockboxStore.save(entries)
                // Re-adding resets any in-flight/open unlock — else the NEW secret inherits the OLD
                // one's unlock window and is instantly copyable. The pending row dies via the queue store.
                var f = LBFile.load(); f.unlockedUntil.removeValue(forKey: e.name); f.save()
                q.rootCancel(keys: [e.name], now: now, reason: "secret re-added")
            }
        }
        // remove (tightening, immediate): delete from the vault + clear all lock state.
        if let euid = enforcedUID, let names = MarkerIO.consumeLines(Paths.lbRemoveMarker, enforcedUID: euid) {
            for name in Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                if entries.contains(where: { $0.name == name }) { entries.removeAll { $0.name == name }; LockboxStore.save(entries) }
                var f = LBFile.load(); f.unlockedUntil.removeValue(forKey: name); f.save()
                q.rootCancel(keys: [name], now: now, reason: "entry removed")
            }
        }

        // Queue phase 1 — validate: entry exists && not already unlocked. delaySec is PER-ENTRY,
        // floor-clamped (a hand-edited vault entry can't go below the compiled floor).
        let validate: (String) -> Bool = { name in
            LockboxStore.load().contains(where: { $0.name == name }) && LBFile.load().unlockedUntil[name] == nil
        }
        let aborted = q.consumeMarkers(now: now, enforcedUID: enforcedUID,
                                       delaySec: { name in
                                           max(LockboxStore.load().first(where: { $0.name == name })?.delaySec
                                               ?? Bounds.lockboxUnlockDelayMin, Bounds.lockboxUnlockDelayMin)
                                       },
                                       key: { $0 }, validate: validate)
        if !aborted.isEmpty {                              // an explicit abort relocks an OPEN window too
            var f = LBFile.load()
            for name in aborted { f.unlockedUntil.removeValue(forKey: name) }
            f.save()
        }

        // copy: if unlocked, write the secret to a fresh 0600 user-owned outbox, then relock now.
        if let euid = enforcedUID, let names = MarkerIO.consumeLines(Paths.lbCopyMarker, enforcedUID: euid) {
            for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
                var f = LBFile.load()
                if let until = f.unlockedUntil[name], now < until,
                   let e = LockboxStore.load().first(where: { $0.name == name }) {
                    writeOutbox(e.secret, ownerUID: euid)             // last copy in the tick owns the outbox
                    f.unlockedUntil.removeValue(forKey: name); f.save()   // relock immediately on copy
                }
            }
        }

        // Queue phase 2 — a due unlock opens the auto-relock window.
        let unlocksStatus = q.applyDue(now: now, validate: validate) { due in
            Dictionary(uniqueKeysWithValues: due.map { d in
                var f = LBFile.load()
                f.unlockedUntil[d.key] = now + Bounds.lockboxAutoRelock
                f.save()
                return (d.key, (true, nil))
            })
        }

        // auto-relock expired windows.
        var f = LBFile.load()
        var changed = false
        for (name, until) in f.unlockedUntil where now >= until { f.unlockedUntil.removeValue(forKey: name); changed = true }
        if changed { f.save() }

        entries = LockboxStore.load()
        let pendingAt = Dictionary(uniqueKeysWithValues: unlocksStatus.rows.map { ($0.key, $0.applyAt) })
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = Status(entries: byName.keys.sorted().map { name in
            EntryView(name: name, delaySec: byName[name]!.delaySec,
                      unlocked: f.unlockedUntil[name] != nil,
                      unlockAtEpoch: pendingAt[name])
        })
        return (windows, unlocksStatus)
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
