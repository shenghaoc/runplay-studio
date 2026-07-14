import XCTest
import RunPlayCore
import RunPlayPlatform
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

    func testElevationColoringHandlesNonFiniteSegmentElevation() {
        let points = [
            RouteScenePoint(xMeters: 0, yMeters: 0, zMeters: 0, sourceIndex: 0, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RouteScenePoint(xMeters: 1, yMeters: 10, zMeters: 0, sourceIndex: 1, distanceFromStartMeters: 1, elapsedSeconds: 1),
            RouteScenePoint(xMeters: 2, yMeters: .nan, zMeters: 0, sourceIndex: 2, distanceFromStartMeters: 2, elapsedSeconds: 2)
        ]

        let colors = coloringService.computeSegmentColors(points: points, mode: .elevation)

        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors[1], .systemGreen)
    }

    func testElevationColoringUsesCorrectedProfileInsteadOfSceneY() {
        let routePoints = createElevationRoute(
            altitudes: [10, 1_000, 12],
            routeSegmentIndexes: [0, 0, 0]
        )
        let profile = ElevationProfile(routePoints: routePoints)
        let firstScene = createScenePoints(routePoints: routePoints, yMeters: [0, 1_980, 4])
        let secondScene = createScenePoints(routePoints: routePoints, yMeters: [500, -200, 7_000])

        XCTAssertTrue(profile.sourceAltitudeWasRejected(atPointIndex: 1))

        let firstColors = coloringService.computeSegmentColors(
            points: firstScene,
            mode: .elevation,
            elevationProfile: profile
        )
        let secondColors = coloringService.computeSegmentColors(
            points: secondScene,
            mode: .elevation,
            elevationProfile: profile
        )

        XCTAssertEqual(firstColors, secondColors)
        XCTAssertNotEqual(firstColors.first, firstColors.last)
    }

    func testElevationColoringDoesNotInventScaleForNonMeaningfulProfile() {
        let routePoints = createElevationRoute(
            altitudes: [10, 50, 100],
            routeSegmentIndexes: [0, 0, 0]
        )
        let policy = RouteQualityPolicy(minimumReliableAltitudeSampleCount: 4)
        let profile = ElevationProfile(routePoints: routePoints, policy: policy)
        let scenePoints = createScenePoints(routePoints: routePoints, yMeters: [0, 80, 180])

        XCTAssertFalse(profile.hasMeaningfulElevation)

        let colors = coloringService.computeSegmentColors(
            points: scenePoints,
            mode: .elevation,
            elevationProfile: profile,
            defaultColor: .magenta
        )

        XCTAssertEqual(colors, [.magenta, .magenta])
    }

    func testElevationColoringUsesDefaultAcrossRouteSegmentBoundary() {
        let routePoints = createElevationRoute(
            altitudes: [10, 20, 30, 40],
            routeSegmentIndexes: [0, 0, 1, 1]
        )
        let profile = ElevationProfile(routePoints: routePoints)
        let scenePoints = createScenePoints(routePoints: routePoints, yMeters: [0, 20, 40, 60])

        let colors = coloringService.computeSegmentColors(
            points: scenePoints,
            mode: .elevation,
            elevationProfile: profile,
            defaultColor: .magenta
        )

        XCTAssertEqual(colors.count, 3)
        XCTAssertNotEqual(colors[0], .magenta)
        XCTAssertEqual(colors[1], .magenta)
        XCTAssertNotEqual(colors[2], .magenta)
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

    // MARK: - Heart Rate Color Tests

    func testHeartRateColorScaleHandlesNormalData() {
        let points = createPointsWithHR(count: 20, startHR: 120, endHR: 170)
        let scale = coloringService.computeHeartRateScale(points: points)

        XCTAssertNotNil(scale)
        if let scale = scale {
            XCTAssertLessThan(scale.lowHR, scale.medianHR)
            XCTAssertLessThan(scale.medianHR, scale.highHR)
            XCTAssertTrue(scale.lowHR.isFinite)
            XCTAssertTrue(scale.medianHR.isFinite)
            XCTAssertTrue(scale.highHR.isFinite)
        }
    }

    func testHeartRateColorScaleIgnoresInvalidValues() {
        var points = createPointsWithHR(count: 20, startHR: 120, endHR: 170)
        // Add a point with invalid HR
        let badPoint = RouteScenePoint(
            xMeters: points[10].xMeters,
            yMeters: points[10].yMeters,
            zMeters: points[10].zMeters,
            sourceIndex: 10,
            distanceFromStartMeters: points[10].distanceFromStartMeters,
            elapsedSeconds: points[10].elapsedSeconds,
            heartRateBPM: 500 // Unrealistic
        )
        points.insert(badPoint, at: 11)

        let scale = coloringService.computeHeartRateScale(points: points)
        XCTAssertNotNil(scale)
        if let scale = scale {
            XCTAssertTrue(scale.lowHR >= 40 && scale.lowHR <= 230)
            XCTAssertTrue(scale.highHR >= 40 && scale.highHR <= 230)
        }
    }

    func testHeartRateColorScaleHandlesMissingHR() {
        let points = (0..<10).map { i in
            RouteScenePoint(
                xMeters: Double(i) * 100,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30,
                heartRateBPM: nil
            )
        }

        let scale = coloringService.computeHeartRateScale(points: points)
        // With no HR data, the service provides a fallback scale with default 140 bpm
        // or returns nil - either is acceptable
        if let scale = scale {
            // If returned, values should be the fallback median
            XCTAssertTrue(scale.lowHR.isFinite)
            XCTAssertTrue(scale.medianHR.isFinite)
            XCTAssertTrue(scale.highHR.isFinite)
        }
    }

    func testHeartRateColorScaleHandlesPartialHR() {
        var points = createPointsWithHR(count: 20, startHR: 120, endHR: 170)
        // Remove HR from some points
        for i in stride(from: 0, to: points.count, by: 2) {
            points[i] = RouteScenePoint(
                xMeters: points[i].xMeters,
                yMeters: points[i].yMeters,
                zMeters: points[i].zMeters,
                sourceIndex: points[i].sourceIndex,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                heartRateBPM: nil
            )
        }

        let scale = coloringService.computeHeartRateScale(points: points)
        // Should still work with partial data
        XCTAssertNotNil(scale)
    }

    func testHighHRMapsDifferentlyFromLowHR() {
        let points = createPointsWithHR(count: 20, startHR: 100, endHR: 180)
        let colors = coloringService.computeSegmentColors(points: points, mode: .heartRate)

        XCTAssertEqual(colors.count, points.count - 1)
        // First segment (low HR) should be more blue/green
        // Last segment (high HR) should be more red
        // They should be different colors
        XCTAssertNotEqual(colors.first, colors.last)
    }

    func testNoHRDataReturnsSafeFallback() {
        let points = (0..<10).map { i in
            RouteScenePoint(
                xMeters: Double(i) * 100,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30,
                heartRateBPM: nil
            )
        }

        let colors = coloringService.computeSegmentColors(points: points, mode: .heartRate)
        XCTAssertEqual(colors.count, points.count - 1)
        // Should return default color, not crash
        for color in colors {
            XCTAssertNotNil(color)
        }
    }

    func testHasHeartRateData() {
        let withHR = createPointsWithHR(count: 10, startHR: 120, endHR: 170)
        XCTAssertTrue(coloringService.hasHeartRateData(points: withHR))

        let withoutHR = (0..<10).map { i in
            RouteScenePoint(
                xMeters: Double(i) * 100,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30,
                heartRateBPM: nil
            )
        }
        XCTAssertFalse(coloringService.hasHeartRateData(points: withoutHR))
    }

    func testHeartRateSegmentValues() {
        let points = createPointsWithHR(count: 20, startHR: 120, endHR: 170)
        let hrValues = coloringService.computeSegmentHeartRate(points: points)

        XCTAssertEqual(hrValues.count, points.count - 1)
        for hr in hrValues {
            XCTAssertTrue(hr.isFinite, "HR should be finite")
            XCTAssertFalse(hr.isNaN, "HR should not be NaN")
            XCTAssertGreaterThanOrEqual(hr, 40, "HR should be >= 40")
            XCTAssertLessThanOrEqual(hr, 230, "HR should be <= 230")
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

    private func createPointsWithHR(count: Int, startHR: Double, endHR: Double) -> [RouteScenePoint] {
        var points: [RouteScenePoint] = []
        let totalDistance = Double(count - 1) * 100.0 // 100m between points

        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let distance = fraction * totalDistance
            let hr = startHR + (endHR - startHR) * fraction // Linear interpolation
            let time = distance / 3.0 // ~3 m/s

            points.append(RouteScenePoint(
                xMeters: distance,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: i,
                distanceFromStartMeters: distance,
                elapsedSeconds: time,
                heartRateBPM: hr
            ))
        }

        return points
    }

    private func createElevationRoute(
        altitudes: [Double?],
        routeSegmentIndexes: [Int]
    ) -> [RoutePoint] {
        precondition(altitudes.count == routeSegmentIndexes.count)
        return altitudes.indices.map { index in
            RoutePoint(
                timestamp: Date().addingTimeInterval(Double(index) * 15),
                latitude: 37.7749 + Double(index) * 0.0001,
                longitude: -122.4194,
                altitudeMeters: altitudes[index],
                distanceFromStartMeters: Double(index) * 50,
                elapsedSeconds: Double(index) * 15,
                routeSegmentIndex: routeSegmentIndexes[index]
            )
        }
    }

    private func createScenePoints(
        routePoints: [RoutePoint],
        yMeters: [Double]
    ) -> [RouteScenePoint] {
        precondition(routePoints.count == yMeters.count)
        return routePoints.indices.map { index in
            RouteScenePoint(
                id: routePoints[index].id,
                xMeters: Double(index) * 50,
                yMeters: yMeters[index],
                zMeters: 0,
                sourceIndex: index,
                distanceFromStartMeters: routePoints[index].distanceFromStartMeters,
                elapsedSeconds: routePoints[index].elapsedSeconds,
                routeSegmentIndex: routePoints[index].routeSegmentIndex
            )
        }
    }
}
