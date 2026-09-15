import XCTest
@testable import DemonlockCore

/// Gate #5: demonlock's CLI marker writer appends the WHOLE payload as ONE line — a multi-line policy
/// expression must arrive as a single request, never be split into N rows (the sidecar's writer does
/// the opposite by design; that's why the two are not shared).
final class MarkerSemanticsTests: XCTestCase {
    func testDropDelayMarkerKeepsMultilinePayloadAsOneLine() throws {
        let dir = NSTemporaryDirectory() + "ms-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/req"
        dropDelayMarker(p, payload: "TIME_IS_ANY([*0900-1700])\nAND NOT LOCATED_IN_ANY([\"gym\"])")
        let lines = MarkerIO.consumeLines(p, enforcedUID: getuid())
        XCTAssertEqual(lines?.count, 1)
        XCTAssertEqual(lines?.first, "TIME_IS_ANY([*0900-1700])\nAND NOT LOCATED_IN_ANY([\"gym\"])")
    }
}
