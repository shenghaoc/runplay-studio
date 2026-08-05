import CoreGraphics
import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class ComparisonVideoPixelMapTests: XCTestCase {
    func testExactPointAndInterpolation() {
        let map = ComparisonVideoRoutePixelMap(samples: [
            sample(id: 0, distance: 0, x: 0, y: 0, segment: 0),
            sample(id: 1, distance: 100, x: 100, y: 0, segment: 0),
            sample(id: 2, distance: 200, x: 200, y: 0, segment: 0),
        ])
        XCTAssertEqual(map.pixel(atDistanceMeters: 0)?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(map.pixel(atDistanceMeters: 50)?.x ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(map.pixel(atDistanceMeters: 200)?.x ?? -1, 200, accuracy: 1e-9)
    }

    func testNoCrossSegmentInterpolation() {
        let map = ComparisonVideoRoutePixelMap(samples: [
            sample(id: 0, distance: 0, x: 0, y: 0, segment: 0),
            sample(id: 1, distance: 100, x: 100, y: 0, segment: 0),
            // Gap / new segment starts at 200 with a jump in pixel space.
            sample(id: 2, distance: 200, x: 500, y: 50, segment: 1),
            sample(id: 3, distance: 300, x: 600, y: 50, segment: 1),
        ])
        // Midway between segment boundary samples should not invent a bridge.
        let pixel = map.pixel(atDistanceMeters: 150)
        XCTAssertEqual(pixel?.x ?? -1, 100, accuracy: 1e-9)
    }

    func testPreferredSegmentFallback() {
        let map = ComparisonVideoRoutePixelMap(samples: [
            sample(id: 0, distance: 0, x: 10, y: 10, segment: 0),
            sample(id: 1, distance: 100, x: 20, y: 20, segment: 0),
            sample(id: 2, distance: 200, x: 90, y: 90, segment: 1),
        ])
        let position = ComparisonVideoRoutePosition(
            routePointID: nil,
            routePointIndex: 2,
            routeSegmentIndex: 1,
            distanceMeters: 150
        )
        let pixel = map.pixel(for: position)
        XCTAssertNotNil(pixel)
    }

    func testEmptyMapReturnsNil() {
        let map = ComparisonVideoRoutePixelMap(samples: [])
        XCTAssertNil(map.pixel(atDistanceMeters: 10))
    }

    private func sample(
        id: Int,
        distance: Double,
        x: CGFloat,
        y: CGFloat,
        segment: Int
    ) -> ComparisonVideoPixelSample {
        ComparisonVideoPixelSample(
            routePointID: UUID(),
            routePointIndex: id,
            routeSegmentIndex: segment,
            distanceMeters: distance,
            point: CGPoint(x: x, y: y)
        )
    }
}
