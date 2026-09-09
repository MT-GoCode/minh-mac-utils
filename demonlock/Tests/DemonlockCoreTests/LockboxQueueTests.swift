import XCTest
@testable import DemonlockCore

/// Lockbox queue semantics tested through fixture stores/closures (never the real /Library paths).
final class LockboxQueueTests: XCTestCase {
    var dir = ""
    var uid: uid_t { getuid() }
    var path: String { dir + "/lb-state.json" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "lb-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    /// A store mirroring Lockbox.unlocksQueue's (LBFile composite; sibling preserved; legacy migrated).
    func store() -> DelayQueue.QStateStore {
        DelayQueue.QStateStore(
            load: {
                let f: Lockbox.LBFile = loadJSON(self.path) ?? .init()
                if let st = f.unlocksQ { return st }
                guard let legacy = f.pending, !legacy.isEmpty else { return DelayQueue.QState() }
                var st = DelayQueue.QState()
                for (n, p) in legacy.sorted(by: { ($0.value.requestedAt, $0.key) < ($1.value.requestedAt, $1.key) }) {
                    st.pending[n] = .init(payload: n, requestedAt: p.requestedAt, applyAt: p.applyAt, seq: st.nextSeq)
                    st.nextSeq += 1
                }
                return st
            },
            save: { st in
                var f: Lockbox.LBFile = loadJSON(self.path) ?? .init()
                f.unlocksQ = st; f.pending = nil
                saveJSON(f, to: self.path)
            })
    }
    func q() -> DelayQueue {
        DelayQueue(kind: "lockbox-unlock", store: store(),
                   requestMarker: dir + "/unlock", abortMarker: dir + "/abort",
                   onFailure: .drop, payloadIsJSON: false, auditLog: dir + "/audit.log")
    }
    func windows() -> [String: Double] { (loadJSON(path) as Lockbox.LBFile?)?.unlockedUntil ?? [:] }
    func setWindow(_ name: String, until: Double) {
        var f: Lockbox.LBFile = loadJSON(path) ?? .init()
        f.unlockedUntil[name] = until; saveJSON(f, to: path)
    }

    let entryDelay = { (_: String) -> Double in max(7200, Bounds.lockboxUnlockDelayMin) }

    func testUnlockQueuesWithPerEntryDelayAboveFloor() {
        let queue = q()
        _ = MarkerIO.append(dir + "/unlock", line: "bank")
        _ = queue.consumeMarkers(now: 1000, enforcedUID: uid, delaySec: entryDelay,
                                 key: { $0 }, validate: { _ in true })
        XCTAssertEqual(queue.status().rows[0].applyAt, 1000 + max(7200, Bounds.lockboxUnlockDelayMin))
    }

    func testAbortRelocksOpenWindowViaAbortedKeys() {
        // The R-finding scenario: bank is UNLOCKED; user aborts; window must die even though the
        // queue consumed the marker (Lockbox.tick clears windows for consumeMarkers' returned keys).
        setWindow("bank", until: 99999)
        let queue = q()
        _ = MarkerIO.append(dir + "/unlock", line: "bank")   // also a pending row (any state)
        _ = queue.consumeMarkers(now: 1, enforcedUID: uid, delaySec: entryDelay, key: { $0 }, validate: { _ in true })
        _ = MarkerIO.append(dir + "/abort", line: "bank")
        let aborted = queue.consumeMarkers(now: 2, enforcedUID: uid, delaySec: entryDelay, key: { $0 }, validate: { _ in true })
        XCTAssertEqual(aborted, ["bank"])
        // the tick-side mirror:
        var f: Lockbox.LBFile = loadJSON(path)!
        for n in aborted { f.unlockedUntil.removeValue(forKey: n) }
        saveJSON(f, to: path)
        XCTAssertNil(windows()["bank"])
        XCTAssertTrue(queue.status().rows.isEmpty)
    }

    func testCrashCannotResurrectAWindow() {
        // Save-before-apply: the pending row leaves the state BEFORE the window opens. A "crash"
        // (state reloaded fresh, apply result discarded) must find no row to re-apply.
        let queue = q()
        _ = MarkerIO.append(dir + "/unlock", line: "bank")
        _ = queue.consumeMarkers(now: 1000, enforcedUID: uid, delaySec: { _ in 100 }, key: { $0 }, validate: { _ in true })
        var applyCalls = 0
        _ = queue.applyDue(now: 2000, validate: { _ in true }) { due in
            applyCalls += due.count
            // mid-apply, on-disk pending is already empty (pre-apply save)
            let mid: Lockbox.LBFile = loadJSON(self.path)!
            XCTAssertTrue(mid.unlocksQ!.pending.isEmpty)
            return [:]                                       // crash-shaped: no verdicts
        }
        XCTAssertEqual(applyCalls, 1)
        var applied2 = 0
        _ = q().applyDue(now: 2001, validate: { _ in true }) { due in applied2 = due.count; return [:] }
        XCTAssertEqual(applied2, 0)                          // never re-applied → no window resurrection
    }

    func testSiblingWindowSurvivesQueueSaves() {
        setWindow("open-one", until: 5000)
        let queue = q()
        _ = MarkerIO.append(dir + "/unlock", line: "bank")
        _ = queue.consumeMarkers(now: 1000, enforcedUID: uid, delaySec: entryDelay, key: { $0 }, validate: { _ in true })
        XCTAssertEqual(windows()["open-one"], 5000)          // byte-for-byte sibling survival
    }

    func testLegacyPendingMigratesAndWindowSiblingPreserved() throws {
        let legacy = #"{"pending":{"bank":{"requestedAt":10,"applyAt":7210}},"unlockedUntil":{"other":9999}}"#
        try legacy.write(toFile: path, atomically: true, encoding: .utf8)
        let queue = q()
        XCTAssertEqual(queue.status().rows.map(\.key), ["bank"])
        _ = MarkerIO.append(dir + "/unlock", line: "second")
        _ = queue.consumeMarkers(now: 20, enforcedUID: uid, delaySec: entryDelay, key: { $0 }, validate: { _ in true })
        XCTAssertEqual(windows()["other"], 9999)             // sibling survived the first queue save
        let f: Lockbox.LBFile = loadJSON(path)!
        XCTAssertNil(f.pending)                              // legacy consumed
        XCTAssertEqual(Set(f.unlocksQ!.pending.keys), ["bank", "second"])
    }
}
