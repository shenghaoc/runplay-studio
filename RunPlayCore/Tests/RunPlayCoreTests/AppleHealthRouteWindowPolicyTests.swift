import XCTest
@testable import RunPlayCore

final class AppleHealthRouteWindowPolicyTests: XCTestCase {
    private let window = AppleHealthWorkoutWindow(startSeconds: 1_000, endSeconds: 1_600,
        activityType: "HKWorkoutActivityTypeRunning", utcOffsetSeconds: 0)

    private func points(_ offsets: [Double]) -> [RoutePoint] {
        offsets.map { RoutePoint(timestamp: Date(timeIntervalSince1970: 1_000 + $0), latitude: 0, longitude: 0) }
    }

    func testBothToleranceBoundariesAreInclusiveAndOneSecondOutsideIsTrimmed() {
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-60, 0, 600, 660]), window: window), .keep)
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-61, -60, 0, 600, 660, 661]), window: window), .trim(1..<5))
    }

    func testFiveMinuteLimitIsInclusiveAtEitherEnd() {
        for excess in [299.0, 300.0] {
            XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-excess, -60, 0, 600, 660, 600 + excess]), window: window), .trim(1..<5))
        }
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-301, 0, 600]), window: window), .mismatch)
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([0, 600, 901]), window: window), .mismatch)
    }

    func testNoOverlapIsMismatchEvenInsideTheTolerance() {
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-50, -10]), window: window), .mismatch)
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([610, 650]), window: window), .mismatch)
    }

    func testContainedShorterRouteIsKeptAndSharedReferenceHasNoAuthority() {
        let route = points([100, 500])
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: route, window: window), .keep)
        let other = AppleHealthWorkoutWindow(startSeconds: 2_000, endSeconds: 2_600,
            activityType: "HKWorkoutActivityTypeRunning", utcOffsetSeconds: 0)
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: route, window: other), .mismatch)
    }

    func testTrimNeedsTwoRetainedPointsAndKeepsRepeatedBoundaryTimes() {
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-299, 899]), window: window), .mismatch)
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: points([-61, -60, -60, 660, 660, 661]), window: window), .trim(1..<5))
    }

    /// Each track segment is sorted on its own, so a middle segment can run two
    /// hours past the workout while the route's first and last points sit inside
    /// it. A route out of time order as a whole is not kept.
    func testRouteWhoseSegmentsAreOutOfTimeOrderIsAMismatch() {
        var route = points([0, 300, 7_200, 7_300, 400, 500])
        for index in route.indices {
            route[index].routeSegmentIndex = index / 2
        }
        XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: route, window: window), .mismatch)
    }

    func testEmptySinglePointAndReversedRoutesAreMismatches() {
        for route in [points([]), points([0]), points([600, 0])] {
            XCTAssertEqual(AppleHealthRouteWindowPolicy.decision(for: route, window: window), .mismatch)
        }
    }
}
