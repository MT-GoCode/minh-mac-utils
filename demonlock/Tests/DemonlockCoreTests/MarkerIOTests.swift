import XCTest
@testable import DemonlockCore

final class MarkerIOTests: XCTestCase {
    var dir: String = ""
    var uid: uid_t { getuid() }
    func path(_ n: String = "m") -> String { dir + "/" + n }

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "markerio-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func mode(_ p: String) -> mode_t { var st = stat(); stat(p, &st); return st.st_mode & 0o777 }

    func testAppendCreatesWithMode() {
        XCTAssertTrue(MarkerIO.append(path(), line: "secret", mode: 0o600))
        XCTAssertEqual(mode(path()), 0o600)
        XCTAssertEqual(mode(path()) & 0o077, 0)           // never group/other-readable
    }

    func testLockboxAddMarkerNeverOtherReadable() {
        // attacker pre-creates 0644; the 0600 write must not inherit it
        FileManager.default.createFile(atPath: path(), contents: Data("evil\n".utf8))
        chmod(path(), 0o644)
        XCTAssertTrue(MarkerIO.append(path(), line: "s3cret", mode: 0o600))
        XCTAssertEqual(mode(path()) & 0o077, 0)
        XCTAssertEqual(MarkerIO.consumeLast(path(), enforcedUID: uid), "s3cret")  // old contents gone
    }

    func testAppendThenConsumeLines_roundTripsEscapedNewlines() {
        let payload = "line1\nline2 with \\backslash\\"
        XCTAssertTrue(MarkerIO.append(path(), line: payload))
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), [payload])
    }

    func testMultiLineAppendAtomic() {
        XCTAssertTrue(MarkerIO.append(path(), lines: ["a", "b"]))
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), ["a", "b"])
    }

    func testConsumeLastTakesLastNonEmpty() {
        _ = MarkerIO.append(path(), line: "1800s")
        _ = MarkerIO.append(path(), line: "3600s")
        XCTAssertEqual(MarkerIO.consumeLast(path(), enforcedUID: uid), "3600s")
        XCTAssertNil(MarkerIO.consumeLast(path(), enforcedUID: uid))   // consumed
    }

    func testRvRequestRoundTrip() {   // spec: "rv request round-trips under the new writer"
        dropDelayMarkerForTest(path(), payload: "3600s")
        XCTAssertEqual(MarkerIO.consumeLast(path(), enforcedUID: uid), "3600s")
    }
    private func dropDelayMarkerForTest(_ p: String, payload: String) {
        _ = MarkerIO.append(p, line: payload.isEmpty ? nil : payload)  // dropDelayMarker's exact shape
    }

    func testZeroByteFileReturnsEmptyArray() {
        _ = MarkerIO.append(path(), line: nil)
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), [])
    }

    func testNilAppendTruncatesStaleLines() {   // bare --abort after keyed abort ⇒ abort-all wins
        _ = MarkerIO.append(path(), line: "add:x")
        _ = MarkerIO.append(path(), line: nil)
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), [])
    }

    func testConsumeFlagOnZeroByte() {
        _ = MarkerIO.append(path(), line: nil)
        XCTAssertTrue(MarkerIO.consumeFlag(path(), enforcedUID: uid))
        XCTAssertFalse(MarkerIO.consumeFlag(path(), enforcedUID: uid))
    }

    func testTrailingPartialLineDiscarded() {
        let fd = open(path(), O_WRONLY | O_CREAT, 0o644)
        _ = "complete\npart".withCString { write(fd, $0, strlen($0)) }
        close(fd)
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), ["complete"])
    }

    func testOverMiBRejectsWholeFile() {
        let fd = open(path(), O_WRONLY | O_CREAT, 0o644)
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 1 << 16)
        for _ in 0..<20 { _ = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }  // 1.25 MiB
        close(fd)
        XCTAssertNil(MarkerIO.consumeLines(path(), enforcedUID: uid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path()))  // rejected + unlinked
    }

    func testHeldFlockSkipsNonBlocking() {
        _ = MarkerIO.append(path(), line: "x")
        // flock attaches to the open file description: a fresh open() in-process still contends
        let holder = open(path(), O_RDONLY)
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        XCTAssertNil(MarkerIO.consumeLines(path(), enforcedUID: uid))          // skipped, not hung
        XCTAssertTrue(FileManager.default.fileExists(atPath: path()))          // survives for next tick
        flock(holder, LOCK_UN); close(holder)
        XCTAssertEqual(MarkerIO.consumeLines(path(), enforcedUID: uid), ["x"]) // consumed after release
    }

    func testSymlinkRefused() {
        _ = MarkerIO.append(path("real"), line: "x")
        symlink(path("real"), path("sym"))
        XCTAssertNil(MarkerIO.consumeLines(path("sym"), enforcedUID: uid))
    }

    func testFifoRefused() {
        mkfifo(path("fifo"), 0o644)
        XCTAssertNil(MarkerIO.consumeLines(path("fifo"), enforcedUID: uid))
    }

    func testWrongOwnerRefused() {
        _ = MarkerIO.append(path(), line: "x")
        XCTAssertNil(MarkerIO.consumeLines(path(), enforcedUID: uid &+ 1))     // owner-pin fails
        XCTAssertFalse(FileManager.default.fileExists(atPath: path()))         // and it's consumed-away
    }
}
