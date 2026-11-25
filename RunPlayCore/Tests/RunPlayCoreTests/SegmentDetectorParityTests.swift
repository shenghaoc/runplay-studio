import XCTest
@testable import RunPlayCore

/// Coverage guard for the generated segment-detection fixture matrix. The
/// golden digest in `SegmentDetectionGoldenTests` runs these fixtures; this
/// test keeps the matrix covering every route family the digest depends on.
final class SegmentDetectorParityTests: XCTestCase {

    func testGeneratedFixtureMatrixCoversRequiredRouteFamilies() {
        var pauseBoundaryCount = 0
        var stationaryPlateauCount = 0
        var missingAltitudeCount = 0
        var kilometerRouteCount = 0

        for fixtureIndex in 0..<SegmentDetectorParityFixtures.generatedFixtureCount {
            let points = SegmentDetectorParityFixtures.generatedFixture(
                index: fixtureIndex
            )
            if points.contains(where: { $0.altitudeMeters == nil }) {
                missingAltitudeCount += 1
            }
            if let first = points.first, let last = points.last,
               last.distanceFromStartMeters - first.distanceFromStartMeters >= 1_000 {
                kilometerRouteCount += 1
            }
            for pair in zip(points, points.dropFirst())
                where pair.0.distanceFromStartMeters
                    == pair.1.distanceFromStartMeters {
                if pair.0.routeSegmentIndex == pair.1.routeSegmentIndex {
                    stationaryPlateauCount += 1
                } else {
                    pauseBoundaryCount += 1
                }
            }
        }

        XCTAssertEqual(SegmentDetectorParityFixtures.generatedFixtureCount, 1_000)
        XCTAssertGreaterThanOrEqual(pauseBoundaryCount, 200)
        XCTAssertGreaterThanOrEqual(stationaryPlateauCount, 140)
        XCTAssertGreaterThanOrEqual(missingAltitudeCount, 250)
        XCTAssertGreaterThanOrEqual(kilometerRouteCount, 800)
    }
}
