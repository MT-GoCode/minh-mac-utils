import XCTest
@testable import MSVCore

final class DurabilityTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: collapseDecision

    func testNormalTickUpdatesCount() {
        let d = collapseDecision(CollapseState(lastRawCount: 20), newCount: 18, sessionUsable: true, now: t0)
        XCTAssertFalse(d.skip); XCTAssertFalse(d.accepted)
        XCTAssertEqual(d.state, CollapseState(lastRawCount: 18, collapsedSince: nil))
    }

    func testOneTickBlipSkipped() {
        let d = collapseDecision(CollapseState(lastRawCount: 20), newCount: 3, sessionUsable: true, now: t0)
        XCTAssertTrue(d.skip); XCTAssertFalse(d.accepted)
        XCTAssertEqual(d.state.lastRawCount, 20)          // held: the degraded count is not adopted
        XCTAssertEqual(d.state.collapsedSince, t0)
    }

    func testCollapseAcceptedAfterDeadline() {
        var st = CollapseState(lastRawCount: 20)
        var d = collapseDecision(st, newCount: 3, sessionUsable: true, now: t0)
        st = d.state
        d = collapseDecision(st, newCount: 3, sessionUsable: true, now: at(5))
        XCTAssertTrue(d.skip)
        st = d.state
        XCTAssertEqual(st.collapsedSince, t0)             // clock anchored at first collapsed tick
        d = collapseDecision(st, newCount: 3, sessionUsable: true, now: at(11))
        XCTAssertFalse(d.skip); XCTAssertTrue(d.accepted) // reality wins — no permanent wedge
        XCTAssertEqual(d.state, CollapseState(lastRawCount: 3, collapsedSince: nil))
    }

    func testOffConsoleCollapseNeverAccepted() {
        var st = CollapseState(lastRawCount: 20)
        for s in stride(from: 0.0, to: 120, by: 0.5) {    // 2 min locked/off-console
            let d = collapseDecision(st, newCount: 1, sessionUsable: false, now: at(s))
            XCTAssertTrue(d.skip); XCTAssertFalse(d.accepted)
            st = d.state
        }
        XCTAssertNil(st.collapsedSince)                   // clock never ran
        XCTAssertEqual(st.lastRawCount, 20)
        // back on console with a real list → normal tick
        let d = collapseDecision(st, newCount: 19, sessionUsable: true, now: at(121))
        XCTAssertFalse(d.skip)
    }

    func testRecoveryClearsCollapse() {
        let st = CollapseState(lastRawCount: 20, collapsedSince: t0)
        let d = collapseDecision(st, newCount: 19, sessionUsable: true, now: at(3))
        XCTAssertFalse(d.skip)
        XCTAssertNil(d.state.collapsedSince)
    }

    // MARK: maintainCandidates (frozen scope)

    func testFallbackSurvivesWindowAppearingInOriginalGroup() {
        // fallback open on [1,2,3]; window 4 appears and is adopted into group "a" — the
        // fallback list must not be yanked (pre-spec: scope re-derivation collapsed the HUD)
        let out = maintainCandidates(candidates: [1, 2, 3], liveIDs: [1, 2, 3, 4],
                                     assignment: [4: "a"], frozenScope: String?.none)
        XCTAssertEqual(out, [1, 2, 3])
    }

    func testFallbackPrunesClosedWindows() {
        let out = maintainCandidates(candidates: [1, 2, 3], liveIDs: [1, 3],
                                     assignment: [:], frozenScope: String?.none)
        XCTAssertEqual(out, [1, 3])
    }

    func testFrozenScopeFiltersByMembership() {
        let out = maintainCandidates(candidates: [1, 2, 3], liveIDs: [1, 2, 3],
                                     assignment: [1: "a", 2: "b", 3: "a"], frozenScope: "a")
        XCTAssertEqual(out, [1, 3])
    }
}
