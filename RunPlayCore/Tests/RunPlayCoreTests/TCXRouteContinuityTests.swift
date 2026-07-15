import XCTest
@testable import RunPlayCore

final class TCXRouteContinuityTests: XCTestCase {

    func testFirstPointIsContinuous() {
        let next = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3,
            longitude: 103.8,
            timestamp: Date()
        )
        XCTAssertEqual(
            TCXRouteContinuityResolver.decide(previous: nil, next: next),
            .continuous
        )
    }

    func testSeamlessBoundaryRemainsContinuous() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3000,
            longitude: 103.8000,
            timestamp: t0
        )
        let next = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3001,
            longitude: 103.8001,
            timestamp: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(
            TCXRouteContinuityResolver.decide(previous: previous, next: next),
            .continuous
        )
    }

    func testForcedTimeGapIsDiscontinuous() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3000,
            longitude: 103.8000,
            timestamp: t0
        )
        let next = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3001,
            longitude: 103.8001,
            timestamp: t0.addingTimeInterval(120)
        )
        XCTAssertEqual(
            TCXRouteContinuityResolver.decide(previous: previous, next: next),
            .discontinuous
        )
    }

    func testForcedRelocationIsDiscontinuous() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 1.3000,
            longitude: 103.8000,
            timestamp: t0
        )
        let next = TCXRouteContinuityResolver.ContinuityPoint(
            latitude: 2.0000,
            longitude: 104.0000,
            timestamp: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(
            TCXRouteContinuityResolver.decide(previous: previous, next: next),
            .discontinuous
        )
    }
}
