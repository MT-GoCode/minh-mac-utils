import XCTest

/// The sidecar's DelayQueue.swift and MarkerIO.swift are VENDORED byte-identical copies (minus the
/// one-line header). Drift here means a fix landed in one trust domain and not the other.
final class VendorSyncTests: XCTestCase {
    func repoFile(_ rel: String) throws -> String {
        // …/demonlock/Tests/DemonlockCoreTests/VendorSyncTests.swift → repo root is 3 dirs up
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }
    func body(_ s: String) -> String {   // drop the vendor header line(s)
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("// VENDORED") })
            .joined(separator: "\n")
    }

    func testSidecarDelayQueueByteIdentical() throws {
        let a = try repoFile("demonlock/Sources/DemonlockCore/DelayQueue.swift")
        let b = try repoFile("nextdns-sidecar/Sources/nextdns-sidecar/DelayQueue.swift")
        XCTAssertEqual(a, body(b))
    }

    func testSidecarMarkerIOByteIdentical() throws {
        let a = try repoFile("demonlock/Sources/DemonlockCore/MarkerIO.swift")
        let b = try repoFile("nextdns-sidecar/Sources/nextdns-sidecar/MarkerIO.swift")
        XCTAssertEqual(a, body(b))
    }
}
