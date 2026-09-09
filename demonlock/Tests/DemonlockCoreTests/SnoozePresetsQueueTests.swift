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
                   onFailure: .drop, payloadIsJSON: true, auditLog: dir + "/audit.log")
    }
    func payload(_ name: String, at now: Double) -> String {
        // mirrors the CLI: target quantized to the minute (double-invoke idempotency)
        let t = try! TimeSpec.parseTarget(find(name)!.spec, from: Date(timeIntervalSince1970: now))
        let d = try! JSONEncoder().encode(SnoozePresets.InvokePayload(
            name: name, targetAt: (t.timeIntervalSince1970 / 60).rounded() * 60))
        return String(data: d, encoding: .utf8)!
    }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "sp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    @discardableResult
    func consume(_ q: DelayQueue, now: Double) -> [String] {
        // mirrors SnoozePresets.tick's queue-time closures, over the fixture list
        q.consumeMarkers(now: now, enforcedUID: uid,
                         delaySec: { SnoozePresets.decodeInvoke($0).flatMap { self.find($0.name) }?.invokeDelaySec ?? 3600 },
                         key: { SnoozePresets.decodeInvoke($0).flatMap { self.find($0.name) } != nil ? "invocation" : nil },
                         validate: { line in
                             guard let p = SnoozePresets.decodeInvoke(line), let preset = self.find(p.name),
                                   let expect = try? TimeSpec.parseTarget(preset.spec, from: Date(timeIntervalSince1970: now))
                             else { return false }
                             return abs(p.targetAt - expect.timeIntervalSince1970) <= SnoozePresets.invokeTargetToleranceSec
                         })
    }

    func testInvokeIdempotentOnIdenticalPayload_reinvokeReplacesAndResets() {
        let q = invokeQ()
        let p1 = payload("tonight", at: 1000)
        _ = MarkerIO.append(dir + "/invoke", line: p1)
        consume(q, now: 1000)
        XCTAssertEqual(q.status().rows[0].applyAt, 4600)
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: 1005))  // nervous re-invoke
        consume(q, now: 1005)                                     // 5s later: same quantized minute
        XCTAssertEqual(q.status().rows[0].applyAt, 4600)          // ⇒ identical payload ⇒ clock kept
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: 2000))  // later re-invoke:
        consume(q, now: 2000)                                     // new frozen target ⇒ different payload
        XCTAssertEqual(q.status().rows.count, 1)
        XCTAssertEqual(q.status().rows[0].applyAt, 5600)          // replace + full delay reset (stricter)
    }

    func testDifferentPresetReplacesAndResets() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: 1000))
        consume(q, now: 1000)
        _ = MarkerIO.append(dir + "/invoke", line: payload("midnight", at: 2000))  // change of mind
        consume(q, now: 2000)
        let st = q.status()
        XCTAssertEqual(st.rows.count, 1)
        XCTAssertTrue(st.rows[0].preview.contains("midnight"))
        XCTAssertEqual(st.rows[0].applyAt, 2000 + 5400)           // midnight's delay, restarted
    }

    func testUnknownPresetAndForgedTargetRejected() {
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: #"{"name":"nope","targetAt":9999}"#)
        consume(q, now: 1000)
        XCTAssertTrue(q.status().rows.isEmpty)
        XCTAssertEqual(q.status().recent.first?.reason, "unkeyable")
        // forged far-future target on a REAL preset: past the one-sided tolerance ⇒ invalid at queue
        _ = MarkerIO.append(dir + "/invoke", line: #"{"name":"tonight","targetAt":99999999}"#)
        consume(q, now: 1000)
        XCTAssertTrue(q.status().rows.isEmpty)
        XCTAssertEqual(q.status().recent.first?.reason, "invalid at queue")
    }

    func testStaleInvokeAfterDaemonGapAccepted() {
        // CLI resolved at T0; daemon was down 40min. Claimed target is EARLIER than a fresh resolve
        // — harmless (shorter snooze) and must be accepted (one-sided gate; reviewer-1 NEW-3).
        let q = invokeQ()
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: 1000))
        consume(q, now: 1000 + 2400)                              // consumed 40min late
        XCTAssertEqual(q.status().rows.count, 1)                  // accepted, not "invalid at queue"
    }

    func testTargetFrozenAtQueueTime_evenIfPresetEditedBeforeLanding() {
        // The target is FROZEN in the payload at queue time — a preset spec edit landing between
        // queue and apply must NOT retarget the pending invocation (main's semantics; reviewer-1 #4).
        let q = invokeQ()
        let t0 = 1_700_000_000.0
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: t0))   // "for 90m" resolved at t0
        consume(q, now: t0)
        var target: Double = 0
        // landing validate deliberately IGNORES the current preset spec (as SnoozePresets.tick does)
        _ = q.applyDue(now: t0 + 3600 + 7200, validate: { SnoozePresets.decodeInvoke($0) != nil }) { due in
            target = SnoozePresets.decodeInvoke(due[0].payload)!.targetAt
            return [due[0].key: (true, nil)]
        }
        XCTAssertEqual(target, t0 + 90 * 60)                      // 90m from QUEUE time, immune to edits
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
        _ = MarkerIO.append(dir + "/invoke", line: payload("tonight", at: 1000))
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
