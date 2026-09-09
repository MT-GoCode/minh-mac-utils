import XCTest
@testable import DemonlockCore

final class DelayQueueTests: XCTestCase {
    var dir = ""
    var uid: uid_t { getuid() }
    var stateFile: String { dir + "/state.json" }
    var reqM: String { dir + "/req" }
    var abortM: String { dir + "/abort" }
    var audit: String { dir + "/audit.log" }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "dq-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func queue(_ failure: DelayQueue.Failure = .drop, json: Bool = false) -> DelayQueue {
        DelayQueue(kind: "test", store: .file(stateFile), requestMarker: reqM, abortMarker: abortM,
                   onFailure: failure, payloadIsJSON: json, auditLog: audit)
    }
    let delay: (String) -> Double = { _ in 100 }
    let keyFn: (String) -> String? = { $0.hasPrefix("BAD") ? nil : "k:" + String($0.prefix(4)) }
    let ok: (String) -> Bool = { !$0.contains("INVALID") }

    @discardableResult
    func consume(_ q: DelayQueue, now: Double) -> [String] {
        q.consumeMarkers(now: now, enforcedUID: uid, delaySec: delay, key: keyFn, validate: ok)
    }
    @discardableResult
    func apply(_ q: DelayQueue, now: Double, applied: inout [String]) -> DelayQueue.QStatus {
        var a = [String]()
        let st = q.applyDue(now: now, validate: ok) { due in
            a = due.map(\.key)
            return Dictionary(uniqueKeysWithValues: due.map { ($0.key, (true, String?.none)) })
        }
        applied = a
        return st
    }

    // MARK: core landing + ordering

    func testQueueLandsAfterDelay() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa payload")
        consume(q, now: 1000)
        var applied = [String]()
        apply(q, now: 1050, applied: &applied)
        XCTAssertEqual(applied, [])                          // not due yet
        let st = apply(q, now: 1101, applied: &applied)
        XCTAssertEqual(applied, ["k:aaaa"])
        XCTAssertEqual(st.lastAppliedAt, 1101)
        XCTAssertTrue(st.rows.isEmpty)
    }

    func testSeqOrderIsSeqContract() {
        // del+add same tick with varied key sets; reload state from disk between ticks.
        for keys in [["dddd", "aaaa"], ["zzzz", "bbbb", "aaaa"], ["mmmm", "aaaa", "zzzz", "cccc"]] {
            try? FileManager.default.removeItem(atPath: stateFile)
            _ = MarkerIO.append(reqM, lines: keys)
            consume(queue(), now: 1000)                       // fresh instance = fresh load
            var applied = [String]()
            apply(queue(), now: 2000, applied: &applied)      // fresh instance again
            XCTAssertEqual(applied, keys.map { "k:" + String($0.prefix(4)) })  // request order, not hash order
        }
    }

    func testItemDecodesWithoutRetriesField() throws {
        let json = """
        {"pending":{"k":{"payload":"p","requestedAt":1,"applyAt":2,"seq":0}},"nextSeq":1,"recent":[]}
        """
        let st = try JSONDecoder().decode(DelayQueue.QState.self, from: Data(json.utf8))
        XCTAssertNil(st.pending["k"]?.retries)
    }

    // MARK: requeue rule

    func testIdenticalPayloadIdempotent_JSONWhitespace() {
        let q = queue(json: true)
        let constKey: (String) -> String? = { _ in "doc" }    // constant key (policy-style)
        _ = MarkerIO.append(reqM, line: #"{"b": 1, "a": 2}"#)
        _ = q.consumeMarkers(now: 1000, enforcedUID: uid, delaySec: delay, key: constKey, validate: ok)
        let applyAt0 = q.status().rows[0].applyAt
        _ = MarkerIO.append(reqM, line: #"{ "a":2,"b":1 }"#)  // same value, different bytes
        _ = q.consumeMarkers(now: 1050, enforcedUID: uid, delaySec: delay, key: constKey, validate: ok)
        XCTAssertEqual(q.status().rows.count, 1)
        XCTAssertEqual(q.status().rows[0].applyAt, applyAt0)  // clock kept
    }

    func testIdenticalNonJSONBytes() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "  aaaa expr  ")
        consume(q, now: 1000)
        _ = MarkerIO.append(reqM, line: "aaaa expr")          // trimmed-identical
        consume(q, now: 1050)
        XCTAssertEqual(q.status().rows[0].applyAt, 1100)      // clock kept
    }

    func testDifferentPayloadReplacesAndResets() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa v1")
        consume(q, now: 1000)
        _ = MarkerIO.append(reqM, line: "aaaa v2")            // same key (k:aaaa), new payload
        consume(q, now: 1050)
        let st = q.status()
        XCTAssertEqual(st.rows.count, 1)
        XCTAssertEqual(st.rows[0].applyAt, 1150)              // clock RESET
        XCTAssertEqual(st.recent.first?.what, "replaced")
    }

    // MARK: cap

    func fill64(_ q: DelayQueue) {
        for i in 0..<64 { _ = MarkerIO.append(reqM, line: String(format: "%04d", i)) }
        consume(q, now: 1000)
        XCTAssertEqual(q.status().rows.count, 64)
        XCTAssertTrue(q.status().full)
    }

    func test65thKeyRejected() {
        let q = queue(); fill64(q)
        _ = MarkerIO.append(reqM, line: "9999")
        consume(q, now: 1001)
        XCTAssertEqual(q.status().rows.count, 64)
        XCTAssertEqual(q.status().recent.first?.reason, "queue full (64/64)")
    }

    func testReplaceAcceptedAtCap() {
        let q = queue(); fill64(q)
        _ = MarkerIO.append(reqM, line: "0001 corrected")
        consume(q, now: 1001)
        XCTAssertEqual(q.status().rows.count, 64)
        XCTAssertEqual(q.status().recent.first?.what, "replaced")
    }

    func testAbortAcceptedAtCap() {
        let q = queue(); fill64(q)
        _ = MarkerIO.append(abortM, line: "k:0001")
        XCTAssertEqual(consume(q, now: 1001), ["k:0001"])
        XCTAssertEqual(q.status().rows.count, 63)
    }

    // MARK: abort

    func testAbortByKey() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb"])
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: "k:aaaa")
        XCTAssertEqual(consume(q, now: 1001), ["k:aaaa"])
        XCTAssertEqual(q.status().rows.map(\.key), ["k:bbbb"])
    }

    func testAbortAllOnZeroByteFile() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb"])
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: nil)                 // bare --abort
        XCTAssertEqual(consume(q, now: 1001).count, 2)
        XCTAssertTrue(q.status().rows.isEmpty)
        XCTAssertEqual(q.status().recent.first?.what, "flushed")
    }

    func testAbortAllLiteralLine() {                           // safe-apps/sidecar CLIs write "--all"
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb"])
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: "--all")
        consume(q, now: 1001)
        XCTAssertTrue(q.status().rows.isEmpty)
    }

    func testAbortBlankLinesSkippedAndUnknownKeyStillReturned() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, lines: ["", "k:nope"])     // blank must NOT wipe the queue
        XCTAssertEqual(consume(q, now: 1001), ["k:nope"])      // returned for app-side effects (relock)
        XCTAssertEqual(q.status().rows.count, 1)               // pending untouched
        XCTAssertEqual(q.status().recent.first?.reason, "nothing pending (side effects only)")
    }

    func testAbortedKeysReturned() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: "k:aaaa")
        XCTAssertEqual(consume(q, now: 1001), ["k:aaaa"])
    }

    func testLineCapRejectsWholeFile() {
        // Over the per-marker line cap the WHOLE file is rejected (one event) — a truncated prefix
        // could split an atomic del+add pair (never act on a prefix; same rule as the byte cap).
        let q = queue()
        _ = MarkerIO.append(reqM, lines: (0..<(DelayQueue.maxLinesPerMarker + 1)).map { String(format: "%04d", $0) })
        consume(q, now: 1000)
        XCTAssertTrue(q.status().rows.isEmpty)                     // nothing queued from the prefix
        XCTAssertEqual(q.status().recent.first?.what, "rejected")
        XCTAssertEqual(q.status().recent.count, 1)                 // ONE collapsed event
        // and an over-cap ABORT file must not read as abort-all:
        _ = MarkerIO.append(reqM, line: "aaaa"); consume(q, now: 1001)
        _ = MarkerIO.append(abortM, lines: (0..<(DelayQueue.maxLinesPerMarker + 1)).map { "k:\($0)" })
        XCTAssertEqual(consume(q, now: 1002), [])
        XCTAssertEqual(q.status().rows.count, 1)                   // pending survives
    }

    // MARK: validation

    func testPoisonLineRejectedIndividually() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["BADkey", "aaaa", "bbbb INVALID"])
        consume(q, now: 1000)
        XCTAssertEqual(q.status().rows.map(\.key), ["k:aaaa"])
        let whats = q.status().recent.map(\.what)
        XCTAssertEqual(whats.filter { $0 == "rejected" }.count, 2)
    }

    func testInvalidAtLandingDropped() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var applied = [String]()
        _ = queue().applyDue(now: 2000, validate: { _ in false }) { due in
            applied = due.map(\.key); return [:]
        }
        XCTAssertEqual(applied, [])                            // never reached apply
        XCTAssertEqual(queue().status().recent.first?.reason, "invalid at landing")
        XCTAssertTrue(queue().status().rows.isEmpty)
    }

    // MARK: crash safety (.drop)

    func testSaveBeforeApply_crashLosesRowNeverReapplies() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var callCount = 0
        // Simulated crash: apply throws away the process before the post-save — modelled by an
        // applyBatch that records the call; the pre-apply save already happened inside applyDue,
        // so we then reload state fresh and verify the row is gone and apply isn't re-run.
        _ = q.applyDue(now: 2000, validate: ok) { due in
            callCount += due.count
            // "crash": return nothing — but the row was already saved-out; to model the crash we
            // stop here and inspect the on-disk state via a fresh instance below. The post-apply
            // save will run in-process, so instead assert the INVARIANT: the row left pending in
            // the PRE-apply save. Read the file NOW, mid-apply.
            let mid: DelayQueue.QState = loadJSON(self.stateFile)!
            XCTAssertNil(mid.pending["k:aaaa"])                // save-before-apply held
            XCTAssertEqual(mid.recent.first?.what, "applying")
            return [:]                                        // and the verdictless key becomes failed
        }
        XCTAssertEqual(callCount, 1)
        var applied = [String]()
        apply(queue(), now: 2001, applied: &applied)
        XCTAssertEqual(applied, [])                            // never re-applied
        XCTAssertEqual(queue().status().recent.first?.what, "failed")  // no verdict ⇒ failed, visible
    }

    func testApplyingSweepRunsWithoutDueRows() {
        // Hand-craft a crashed state: an `applying` outcome with empty pending.
        let st = DelayQueue.QState(pending: [:], nextSeq: 1, lastAppliedAt: nil,
                                   recent: [.init(key: "k:aaaa", what: "applying", reason: nil, at: 500)])
        saveJSON(st, to: stateFile)
        consume(queue(), now: 1000)                            // step-0 sweep, no due rows anywhere
        XCTAssertEqual(queue().status().recent.first?.what, "unconfirmed")
    }

    func testLastAppliedAtOnlyOnSuccess() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        _ = q.applyDue(now: 2000, validate: ok) { due in
            Dictionary(uniqueKeysWithValues: due.map { ($0.key, (false, String?.some("boom"))) })
        }
        let st = q.status()
        XCTAssertNil(st.lastAppliedAt)                         // failed apply never bumps it
        XCTAssertEqual(st.recent.first?.what, "failed")
    }

    // MARK: .retry

    func testRetryKeepsRowWithBackoff() {
        let q = queue(.retry)
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var expected: [Double] = [5, 10, 20, 40, 80, 160, 300, 300]
        var now = 1100.0
        for exp in expected {
            _ = q.applyDue(now: now, validate: ok) { due in
                Dictionary(uniqueKeysWithValues: due.map { ($0.key, (false, String?.none)) })
            }
            let st: DelayQueue.QState = loadJSON(stateFile)!
            XCTAssertEqual(st.pending["k:aaaa"]?.nextRetryAt, now + exp)   // 5,10,20,…,300 ceiling
            now = (st.pending["k:aaaa"]?.nextRetryAt ?? now) + 1
        }
        expected = []  // silence unused warning
        // still pending, still retryable, cap slot held
        XCTAssertEqual(q.status().rows.count, 1)
    }

    func testRetryFailedOutcomeAtTenAndNeverApplying() {
        let q = queue(.retry)
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var now = 1100.0
        for _ in 0..<10 {
            _ = q.applyDue(now: now, validate: ok) { due in
                Dictionary(uniqueKeysWithValues: due.map { ($0.key, (false, String?.none)) })
            }
            let st: DelayQueue.QState = loadJSON(stateFile)!
            XCTAssertFalse(st.recent.contains { $0.what == "applying" })   // .retry never gets applying
            now = (st.pending["k:aaaa"]?.nextRetryAt ?? now) + 1
        }
        XCTAssertTrue(q.status().recent.contains { $0.what == "failed" })
        XCTAssertEqual(q.status().rows.count, 1)               // keeps retrying
    }

    func testRetryCrashAfterSuccessReappliesOnce_setLikeSafe() {
        // .retry is remove-AFTER-success: a crash between apply-success and the save re-applies
        // exactly once on the next tick. Safe only because .retry applies are contractually
        // idempotent (set-like) — this test documents/asserts the re-apply happens.
        let q = queue(.retry)
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        let preApply = try! Data(contentsOf: URL(fileURLWithPath: stateFile))   // snapshot pre-apply
        var calls = 0
        _ = q.applyDue(now: 1101, validate: ok) { due in
            calls += due.count
            return Dictionary(uniqueKeysWithValues: due.map { ($0.key, (true, String?.none)) })
        }
        XCTAssertEqual(calls, 1)
        try! preApply.write(to: URL(fileURLWithPath: stateFile))                // "crash": save lost
        _ = queue(.retry).applyDue(now: 1102, validate: ok) { due in
            calls += due.count
            return Dictionary(uniqueKeysWithValues: due.map { ($0.key, (true, String?.none)) })
        }
        XCTAssertEqual(calls, 2)                                               // re-applied once
        XCTAssertTrue(queue(.retry).status().rows.isEmpty)                     // then cleared
    }

    func testRetrySucceedsAndClears() {
        let q = queue(.retry)
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var applied = [String]()
        apply(q, now: 1101, applied: &applied)
        XCTAssertEqual(applied, ["k:aaaa"])
        XCTAssertTrue(q.status().rows.isEmpty)
    }

    // MARK: clock

    func testClockBackward400sRestamps() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)                                  // applyAt 1100
        consume(q, now: 600)                                   // clock jumped back 400s > slack
        let st = q.status()
        XCTAssertEqual(st.rows[0].applyAt, 700)                // full delay restarted from new now
    }

    func testClockBackward100sDoesNot() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        consume(q, now: 901)                                   // within 300s slack
        XCTAssertEqual(q.status().rows[0].applyAt, 1100)
    }

    func testForwardJumpLands() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        var applied = [String]()
        apply(q, now: 1_000_000, applied: &applied)            // long shutdown
        XCTAssertEqual(applied, ["k:aaaa"])
    }

    // MARK: recent ring + flush + audit

    func testRecentIsEightEvents_flushIsOne() {
        let q = queue()
        for i in 0..<20 { _ = MarkerIO.append(reqM, line: String(format: "%04d", i)) }
        consume(q, now: 1000)                                  // 20 queued events → ring keeps 8
        XCTAssertEqual(q.status().recent.count, 8)
        q.flushAll(now: 1001, reason: "admin grant")
        let recent = q.status().recent
        XCTAssertEqual(recent.first?.what, "flushed")          // ONE event for 20 rows
        XCTAssertEqual(recent.count, 8)
        XCTAssertTrue(recent.first!.key.contains(","))         // lists the keys
        XCTAssertTrue(q.status().rows.isEmpty)
    }

    func testAuditLineWritten() throws {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        let log = try String(contentsOfFile: audit, encoding: .utf8)
        XCTAssertTrue(log.contains("test k:aaaa QUEUED"))
    }

    // MARK: misc contracts

    func testNilEnforcedUIDStillApplies() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1000)
        _ = q.consumeMarkers(now: 1500, enforcedUID: nil, delaySec: delay, key: keyFn, validate: ok)
        var applied = [String]()
        // applyDue has no uid — due items land even with a cold uid cache
        apply(q, now: 2000, applied: &applied)
        XCTAssertEqual(applied, ["k:aaaa"])
    }

    func testPeekDueMatchesApplyOrder() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["dddd", "aaaa"])
        consume(q, now: 1000)
        XCTAssertEqual(q.peekDue(now: 2000).map(\.key), ["k:dddd", "k:aaaa"])
        var applied = [String]()
        apply(q, now: 2000, applied: &applied)
        XCTAssertEqual(applied, ["k:dddd", "k:aaaa"])
    }

    func testRequestedAtInDueTuples() {
        let q = queue()
        _ = MarkerIO.append(reqM, line: "aaaa")
        consume(q, now: 1234)
        var seen: Double = 0
        _ = q.applyDue(now: 2000, validate: ok) { due in
            seen = due[0].requestedAt
            return [due[0].key: (true, nil)]
        }
        XCTAssertEqual(seen, 1234)                             // daemon-stamped, frozen
    }
}
