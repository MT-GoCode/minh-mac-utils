import XCTest
import MacUtilsCore
@testable import DemonlockCore

final class SmokeTests: XCTestCase {
    func testBoundsClamp() { XCTAssertEqual(Bounds.clamp(0, Bounds.zonesDelay), 12.0 * 3600) }
}
