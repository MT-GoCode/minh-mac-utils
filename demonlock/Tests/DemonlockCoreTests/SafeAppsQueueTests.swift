import XCTest
@testable import DemonlockCore

final class SafeAppsQueueTests: XCTestCase {
    var dir = ""
    var uid: uid_t { getuid() }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "sa-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func q() -> DelayQueue {
        DelayQueue(kind: "safe-apps", store: .file(dir + "/st.json", legacyDecode: Legacy.safeApps()),
                   requestMarker: dir + "/reg", abortMarker: dir + "/abort",
                   onFailure: .drop, payloadIsJSON: true, auditLog: dir + "/audit.log")
    }
    func appJSON(_ name: String, bid: String, rootOwned: Bool = true, tid: String = "SY64MV22J9") -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(data: try! enc.encode(SafeApp(name: name, bid: bid, tid: tid, rootOwned: rootOwned)), encoding: .utf8)!
    }
    let decode: (String) -> SafeApp? = { try? JSONDecoder().decode(SafeApp.self, from: Data($0.utf8)) }

    @discardableResult
    func consume(_ queue: DelayQueue, now: Double, validate: @escaping (String) -> Bool = { _ in true }) -> [String] {
        queue.consumeMarkers(now: now, enforcedUID: uid, delaySec: { _ in 100 },
                             key: { self.decode($0)?.name }, validate: validate)
    }

    func testSameNameDifferentFlagsReplacesAndResets() {
        // THE user's flag case: same name, different rootOwned ⇒ replace + full clock reset.
        let queue = q()
        _ = MarkerIO.append(dir + "/reg", line: appJSON("raycast", bid: "com.raycast.macos", rootOwned: true))
        consume(queue, now: 1000)
        XCTAssertEqual(queue.status().rows[0].applyAt, 1100)
        _ = MarkerIO.append(dir + "/reg", line: appJSON("raycast", bid: "com.raycast.macos", rootOwned: false))
        consume(queue, now: 1050)
        let st = queue.status()
        XCTAssertEqual(st.rows.count, 1)
        XCTAssertEqual(st.rows[0].applyAt, 1150)                       // reset — no hour-35 swap
        XCTAssertEqual(decode(st.rows[0].preview)?.rootOwned, false)   // new payload won
        XCTAssertEqual(st.recent.first?.what, "replaced")
    }

    func testIdenticalReregisterIdempotent() {
        let queue = q()
        let json = appJSON("raycast", bid: "com.raycast.macos")
        _ = MarkerIO.append(dir + "/reg", line: json)
        consume(queue, now: 1000)
        _ = MarkerIO.append(dir + "/reg", line: json)
        consume(queue, now: 1050)
        XCTAssertEqual(queue.status().rows[0].applyAt, 1100)           // clock kept
    }

    func testBlocklistRejectedAtQueueAndLanding() {
        // real validator: a browser bid is never spareable
        let validate: (String) -> Bool = { line in
            self.decode(line).map { SafeApps.rejectReason($0, settings: Settings()) == nil } ?? false
        }
        let queue = q()
        _ = MarkerIO.append(dir + "/reg", line: appJSON("chrome", bid: "com.google.Chrome"))
        consume(queue, now: 1000, validate: validate)
        XCTAssertTrue(queue.status().rows.isEmpty)                     // rejected at queue
        XCTAssertEqual(queue.status().recent.first?.reason, "invalid at queue")
        // landing-side: queue with permissive validate, land with the real one
        _ = MarkerIO.append(dir + "/reg", line: appJSON("chrome", bid: "com.google.Chrome"))
        consume(queue, now: 1000)
        var applied = 0
        _ = queue.applyDue(now: 2000, validate: validate) { due in applied = due.count; return [:] }
        XCTAssertEqual(applied, 0)                                     // dropped at landing, fail-closed
        XCTAssertEqual(queue.status().recent.first?.reason, "invalid at landing")
    }

    func testFlushAllAcrossManyQueues() {
        // The grant-flush shape: every queue flushes independently, one event each, empties no-op.
        var queues: [DelayQueue] = []
        for i in 0..<7 {
            let dq = DelayQueue(kind: "q\(i)", store: .file(dir + "/q\(i).json"),
                                requestMarker: dir + "/r\(i)", abortMarker: dir + "/a\(i)",
                                onFailure: .drop, payloadIsJSON: false, auditLog: dir + "/audit.log")
            if i % 2 == 0 {   // some queues pending, some empty (flushAll must no-op cleanly)
                _ = MarkerIO.append(dir + "/r\(i)", line: "x\(i)")
                _ = dq.consumeMarkers(now: 1, enforcedUID: uid, delaySec: { _ in 100 },
                                      key: { $0 }, validate: { _ in true })
            }
            queues.append(dq)
        }
        for dq in queues { dq.flushAll(now: 2, reason: "admin grant") }
        for (i, dq) in queues.enumerated() {
            XCTAssertTrue(dq.status().rows.isEmpty)
            if i % 2 == 0 { XCTAssertEqual(dq.status().recent.first?.what, "flushed") }
            else { XCTAssertTrue(dq.status().recent.isEmpty) }   // empty queue: no spurious event
        }
    }

    func testFlushEmptiesQueueAsOneEvent() {
        let queue = q()
        _ = MarkerIO.append(dir + "/reg", lines: [appJSON("a", bid: "com.a.a"), appJSON("b", bid: "com.b.b")])
        consume(queue, now: 1000)
        queue.flushAll(now: 1001, reason: "admin grant")
        XCTAssertTrue(queue.status().rows.isEmpty)
        XCTAssertEqual(queue.status().recent.first?.what, "flushed")
        XCTAssertTrue(queue.status().recent.first!.key.contains("a"))
    }
}
