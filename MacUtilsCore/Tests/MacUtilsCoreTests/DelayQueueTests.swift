import XCTest
@testable import MacUtilsCore

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

extension DelayQueueTests {
    /// Same-tick ordering must not matter: abort-all then a keyed abort (and vice versa) both flush
    /// everything. Under the old zero-byte-truncate writer, all-then-key silently lost the all.
    func testAbortAllThenKeyedSameTickFlushesAll() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb"])
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: "--all")
        _ = MarkerIO.append(abortM, line: "k:aaaa")
        consume(q, now: 1001)
        XCTAssertTrue(q.status().rows.isEmpty)
    }
    func testKeyedThenAbortAllSameTickFlushesAll() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb"])
        consume(q, now: 1000)
        _ = MarkerIO.append(abortM, line: "k:aaaa")
        _ = MarkerIO.append(abortM, line: "--all")
        consume(q, now: 1001)
        XCTAssertTrue(q.status().rows.isEmpty)
    }
}

extension DelayQueueTests {
    /// Grant path: expediteAll makes every row due NOW (one event); the next applyDue lands them all,
    /// in seq order, through the normal validate/apply — never bypassing validation.
    func testExpediteAllLandsEverythingNextTick() {
        let q = queue()
        _ = MarkerIO.append(reqM, lines: ["aaaa", "bbbb", "cccc"])
        consume(q, now: 1000)                       // applyAt = 1000 + delay (far future)
        q.expediteAll(now: 1001, reason: "admin grant")
        let st = q.status()
        XCTAssertEqual(st.rows.count, 3)
        XCTAssertTrue(st.rows.allSatisfy { $0.applyAt == 1001 })
        XCTAssertEqual(st.recent.first?.what, "expedited")
        XCTAssertEqual(st.recent.first?.key, "k:aaaa, k:bbbb, k:cccc")
        var landed: [String] = []
        _ = q.applyDue(now: 1002, validate: { $0 != "bbbb" }) { due in   // bbbb fails validation at landing
            landed = due.map(\.key)
            return Dictionary(uniqueKeysWithValues: due.map { ($0.key, (ok: true, reason: nil)) })
        }
        XCTAssertEqual(landed, ["k:aaaa", "k:cccc"])   // seq order, validator still honored
        XCTAssertTrue(q.status().rows.isEmpty)
    }
    func testExpediteAllNoOpOnEmpty() {
        let q = queue()
        q.expediteAll(now: 5, reason: "admin grant")
        XCTAssertTrue(q.status().recent.isEmpty)
    }
}
