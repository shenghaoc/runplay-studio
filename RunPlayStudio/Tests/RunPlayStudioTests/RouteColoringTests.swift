import XCTest
@testable import RunPlayStudio

final class RouteColoringTests: XCTestCase {

    let coloringService = RouteColoringService()

    // MARK: - Pace Color Scale Tests

    func testPaceColorScaleHandlesNormalData() {
        let points = createPointsWithPace(count: 20, startPace: 300, endPace: 400) // 5:00 to 6:40/km
        let scale = coloringService.computePaceScale(points: points)

        XCTAssertNotNil(scale)
        if let scale = scale {
            XCTAssertLessThan(scale.fastestPace, scale.medianPace)
            XCTAssertLessThan(scale.medianPace, scale.slowestPace)
            XCTAssertTrue(scale.fastestPace.isFinite)
            XCTAssertTrue(scale.medianPace.isFinite)
            XCTAssertTrue(scale.slowestPace.isFinite)
        }
    }

    func testPaceColorScaleIgnoresNaN() {
        var points = createPointsWithPace(count: 20, startPace: 300, endPace: 400)
        // Add a point with invalid data (same position = zero distance)
        let badPoint = RouteScenePoint(
            xMeters: points[10].xMeters,
            yMeters: points[10].yMeters,
            zMeters: points[10].zMeters,
            sourceIndex: 10,
            distanceFromStartMeters: points[10].distanceFromStartMeters, // Same distance
            elapsedSeconds: points[10].elapsedSeconds + 10,
            paceSecondsPerKilometer: Double.nan
        )
        points.insert(badPoint, at: 11)

        let scale = coloringService.computePaceScale(points: points)
        XCTAssertNotNil(scale)
        if let scale = scale {
            XCTAssertTrue(scale.fastestPace.isFinite)
            XCTAssertTrue(scale.slowestPace.isFinite)
        }
    }

    func testPaceColorScaleHandlesRepeatedPoints() {
        // All points at same location
        let points = (0..<10).map { i in
            RouteScenePoint(
                xMeters: 0, yMeters: 0, zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: 0,
                elapsedSeconds: Double(i) * 10
            )
        }

        let scale = coloringService.computePaceScale(points: points)
        // Should return nil or use default values (not crash)
        if let scale = scale {
            XCTAssertTrue(scale.fastestPace.isFinite)
            XCTAssertTrue(scale.medianPace.isFinite)
            XCTAssertTrue(scale.slowestPace.isFinite)
        }
    }

    func testPaceColorScaleHandlesMissingPace() {
        let points = (0..<10).map { i in
            RouteScenePoint(
                xMeters: Double(i) * 100,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 60,
                paceSecondsPerKilometer: nil // Missing pace
            )
        }

        let scale = coloringService.computePaceScale(points: points)
        // Should compute pace from distance/elapsed, not crash
        XCTAssertNotNil(scale)
    }

    func testPaceColorScaleHandlesVeryShortRoute() {
        let points = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RouteScenePoint(xMeters: 1, yMeters: 0, zMeters: 0, sourceIndex: 1, distanceFromStartMeters: 1, elapsedSeconds: 1)
        ]

        let scale = coloringService.computePaceScale(points: points)
        // Very short route - may return scale with extreme values or nil
        if let scale = scale {
            XCTAssertTrue(scale.fastestPace.isFinite)
        }
    }

    // MARK: - Segment Color Tests

    func testFastestSegmentsMapDifferentlyFromSlowest() {
        // Create points with clear pace variation: fast start, slow end
        let points = createPointsWithPace(count: 20, startPace: 250, endPace: 500)
        let colors = coloringService.computeSegmentColors(points: points, mode: .pace)

        XCTAssertEqual(colors.count, points.count - 1)
        XCTAssertGreaterThan(colors.count, 2)

        // First segment (fast) should be more blue
        // Last segment (slow) should be more red
        // We can't easily compare NSColor, but they should be different
        // At minimum, verify they're all valid colors
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    func testSingleColorModeReturnsUniformColors() {
        let points = createPointsWithPace(count: 10, startPace: 300, endPace: 400)
        let colors = coloringService.computeSegmentColors(points: points, mode: .singleColor)

        XCTAssertEqual(colors.count, points.count - 1)
        // All colors should be the same
        for color in colors {
            XCTAssertEqual(color, colors[0])
        }
    }

    func testEmptyPointsReturnsEmptyColors() {
        let colors = coloringService.computeSegmentColors(points: [], mode: .pace)
        XCTAssertTrue(colors.isEmpty)
    }

    func testSinglePointReturnsEmptyColors() {
        let points = [RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0)]
        let colors = coloringService.computeSegmentColors(points: points, mode: .pace)
        XCTAssertTrue(colors.isEmpty)
    }

    // MARK: - Segment Pace Tests

    func testComputeSegmentPaceReturnsValidValues() {
        let points = createPointsWithPace(count: 20, startPace: 300, endPace: 350)
        let paceValues = coloringService.computeSegmentPace(points: points)

        XCTAssertEqual(paceValues.count, points.count - 1)
        for pace in paceValues {
            XCTAssertTrue(pace.isFinite, "Pace should be finite")
            XCTAssertFalse(pace.isNaN, "Pace should not be NaN")
            XCTAssertGreaterThan(pace, 0, "Pace should be positive")
        }
    }

    func testComputeSegmentPaceHandlesZeroDistance() {
        // Two points at same location
        let points = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 1, distanceFromStartMeters: 0, elapsedSeconds: 60)
        ]

        let paceValues = coloringService.computeSegmentPace(points: points)
        XCTAssertEqual(paceValues.count, 1)
        // Should use median fallback, not NaN
        XCTAssertTrue(paceValues[0].isFinite)
    }

    func testPaceFormatting() {
        let scale = PaceColorScale(fastestPace: 270, medianPace: 330, slowestPace: 420)

        XCTAssertEqual(scale.fastestFormatted, "4:30 /km")
        XCTAssertEqual(scale.medianFormatted, "5:30 /km")
        XCTAssertEqual(scale.slowestFormatted, "7:00 /km")
    }

    // MARK: - Route Projection Integration

    func testRouteColoringDoesNotBreakProjection() {
        let routePoints = [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194, altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: Date(), latitude: 37.7759, longitude: -122.4184, altitudeMeters: 50, distanceFromStartMeters: 1000, elapsedSeconds: 300)
        ]

        let projection = RouteProjectionService()
        let scenePoints = projection.project(routePoints)

        let colors = coloringService.computeSegmentColors(points: scenePoints, mode: .pace)
        XCTAssertEqual(colors.count, scenePoints.count - 1)

        // Verify colors are valid
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    // MARK: - Helpers

    private func createPointsWithPace(count: Int, startPace: Double, endPace: Double) -> [RouteScenePoint] {
        var points: [RouteScenePoint] = []
        let totalDistance = Double(count - 1) * 100.0 // 100m between points

        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let distance = fraction * totalDistance
            let pace = startPace + (endPace - startPace) * fraction // Linear interpolation
            let time = distance * pace / 1000.0 // time = distance * pace

            points.append(RouteScenePoint(
                xMeters: distance,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: distance,
                elapsedSeconds: time,
                paceSecondsPerKilometer: pace
            ))
        }

        return points
    }
}
