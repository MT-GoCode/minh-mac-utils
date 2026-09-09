import XCTest
@testable import DemonlockCore

/// All closures test-local over a FIXTURE preset list — never SnoozePresets.find/Settings.load
/// (which read the installed /Library file and would couple the suite to the live machine).
final class SnoozePresetsQueueTests: XCTestCase {
    var dir = ""
    var uid: uid_t { getuid() }
    let fixtures = [SnoozePreset(name: "tonight", spec: "for 90m", invokeDelaySec: 3600),
                    SnoozePreset(name: "midnight", spec: "until 0005", invokeDelaySec: 5400)]
    func find(_ n: String) -> SnoozePreset? { fixtures.first { $0.name == n } }

    func invokeQ() -> DelayQueue {
        DelayQueue(kind: "snooze-invoke", store: .file(dir + "/inv.json"),
                   requestMarker: dir + "/invoke", abortMarker: dir + "/invoke-abort",
                   onFailure: .drop, payloadIsJSON: false, auditLog: dir + "/audit.log")
    }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult
    func consume(_ q: DelayQueue, now: Double) -> [String] {
        q.consumeMarkers(now: now, enforcedUID: uid,
                         delaySec: { self.find($0)?.invokeDelaySec ?? 3600 },
                         key: { self.find($0) != nil ? "invocation" : nil },
                         validate: { self.find($0) != nil })
    }

    func testInvokeIdempotentWhilePending() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: "tonight")
        consume(q, now: 1000)
        XCTAssertEqual(q.status().rows[0].applyAt, 4600)
        _ = MarkerIO.append(dir + "/invoke", line: "tonight")     // double-invoke, same preset
        consume(q, now: 2000)
        XCTAssertEqual(q.status().rows.count, 1)
        XCTAssertEqual(q.status().rows[0].applyAt, 4600)          // clock kept
    }

    func testDifferentPresetReplacesAndResets() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: "tonight")
        consume(q, now: 1000)
        _ = MarkerIO.append(dir + "/invoke", line: "midnight")    // change of mind → stricter
        consume(q, now: 2000)
        let st = q.status()
        XCTAssertEqual(st.rows.count, 1)
        XCTAssertEqual(st.rows[0].preview, "midnight")
        XCTAssertEqual(st.rows[0].applyAt, 2000 + 5400)           // midnight's delay, restarted
    }

    func testUnknownPresetRejected() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: "nope")
        consume(q, now: 1000)
        XCTAssertTrue(q.status().rows.isEmpty)
        XCTAssertEqual(q.status().recent.first?.reason, "unkeyable")
    }

    func testTargetFrozenAtQueueTime() {
        // The frozen target derives from the daemon-stamped requestedAt in the due tuple — advancing
        // the clock past a boundary between queue and apply must not move it.
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: "tonight")     // "for 90m"
        let t0 = 1_700_000_000.0
        consume(q, now: t0)
        var target: Double = 0
        _ = q.applyDue(now: t0 + 3600 + 7200, validate: { self.find($0) != nil }) { due in
            let d = due[0]
            let t = try! TimeSpec.parseTarget(self.find(d.payload)!.spec,
                                              from: Date(timeIntervalSince1970: d.requestedAt))
            target = t.timeIntervalSince1970
            return [d.key: (true, nil)]
        }
        XCTAssertEqual(target, t0 + 90 * 60)                      // 90m from QUEUE time, not apply time
    }

    func testApplyCapsAtCeiling() {
        // parseTarget from a requestedAt far in the past can exceed... use the tick-side formula:
        let now = 2_000.0
        let target = now + Bounds.snoozeDurationMax + 9999        // beyond the 18h ceiling
        let capped = min(target, now + Bounds.snoozeDurationMax)
        XCTAssertEqual(capped, now + Bounds.snoozeDurationMax)
    }

    func testInvokeAbortZeroByteCancels() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: "tonight")
        consume(q, now: 1000)
        _ = MarkerIO.append(dir + "/invoke-abort", line: nil)     // today's flag-style abort
        consume(q, now: 1001)
        XCTAssertTrue(q.status().rows.isEmpty)
    }

    func testLegacySPFileMigratesAndSiblingsSurviveSameTickSaves() throws {
        // legacy composite file: in-flight invocation + one pending add
        let legacy = #"{"invocation":{"name":"tonight","requestedAt":100,"applyAt":3700,"targetAt":5500},"adds":{"newone":{"preset":{"name":"newone","spec":"for 60m","invokeDelaySec":3600},"requestedAt":50,"applyAt":172850}}}"#
        let path = NSTemporaryDirectory() + "sp-mig-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try legacy.write(toFile: path, atomically: true, encoding: .utf8)

        // stores mirroring SnoozePresets.subStore over this file
        func store(field: @escaping (SnoozePresets.SPFile) -> DelayQueue.QState?,
                   migrate: @escaping (SnoozePresets.SPFile) -> DelayQueue.QState?,
                   write: @escaping (inout SnoozePresets.SPFile, DelayQueue.QState) -> Void) -> DelayQueue.QStateStore {
            DelayQueue.QStateStore(
                load: {
                    let f: SnoozePresets.SPFile = loadJSON(path) ?? .init()
                    return field(f) ?? migrate(f) ?? DelayQueue.QState()
                },
                save: { st in
                    var f: SnoozePresets.SPFile = loadJSON(path) ?? .init()   // FRESH — composite contract
                    write(&f, st); saveJSON(f, to: path)
                })
        }
        let invStore = store(field: { $0.invokeQ },
                             migrate: { f in f.invocation.map { .init(pending: ["invocation": .init(payload: $0.name, requestedAt: $0.requestedAt, applyAt: $0.applyAt, seq: 0)], nextSeq: 1, lastAppliedAt: nil, recent: []) } },
                             write: { f, st in f.invokeQ = st; f.invocation = nil })
        let addStore = store(field: { $0.addsQ },
                             migrate: { f in f.adds.map { adds in
                                 var st = DelayQueue.QState()
                                 for (n, a) in adds { st.pending[n] = .init(payload: n, requestedAt: a.requestedAt, applyAt: a.applyAt, seq: st.nextSeq); st.nextSeq += 1 }
                                 return st
                             } },
                             write: { f, st in f.addsQ = st; f.adds = nil })

        // both migrate
        XCTAssertEqual(invStore.load().pending["invocation"]?.payload, "tonight")
        XCTAssertEqual(addStore.load().pending["newone"]?.applyAt, 172850)
        // interleaved saves in one tick: invoke saves, then adds saves — invoke's rows must survive
        var inv = invStore.load(); invStore.save(inv)
        var add = addStore.load(); addStore.save(add)
        inv = invStore.load(); add = addStore.load()
        XCTAssertEqual(inv.pending.count, 1)                       // not clobbered by the sibling save
        XCTAssertEqual(add.pending.count, 1)
        let f: SnoozePresets.SPFile = loadJSON(path)!
        XCTAssertNil(f.invocation); XCTAssertNil(f.adds)           // legacy consumed
    }
}
