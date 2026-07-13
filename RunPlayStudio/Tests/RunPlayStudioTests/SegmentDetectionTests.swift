import XCTest
import RunPlayCore
@testable import RunPlayStudio

final class SegmentDetectionTests: XCTestCase {

    // MARK: - Fastest 400m

    func testFastest400mDetection() {
        let workout = createWorkoutWithVaryingPace()
        let segments = SegmentDetector.detectSegments(from: workout)

        let fastest400m = segments.first { $0.type == .fastest400m }
        XCTAssertNotNil(fastest400m, "Should detect fastest 400m")
        if let seg = fastest400m {
            XCTAssertEqual(seg.distanceMeters, 400, accuracy: 60)
            XCTAssertGreaterThan(seg.paceSecondsPerKilometer ?? 0, 0)
            XCTAssertTrue(seg.startDistanceMeters >= 0)
            XCTAssertTrue(seg.endDistanceMeters <= (workout.routePoints.last?.distanceFromStartMeters ?? 0))
        }
    }

    // MARK: - Fastest 1km

    func testFastest1kmDetection() {
        let workout = createWorkoutWithVaryingPace()
        let segments = SegmentDetector.detectSegments(from: workout)

        let fastest1km = segments.first { $0.type == .fastest1km }
        XCTAssertNotNil(fastest1km, "Should detect fastest 1km")
        if let seg = fastest1km {
            XCTAssertEqual(seg.distanceMeters, 1000, accuracy: 60)
            XCTAssertGreaterThan(seg.paceSecondsPerKilometer ?? 0, 0)
        }
    }

    // MARK: - Slowest 1km

    func testSlowest1kmDetection() {
        let workout = createWorkoutWithVaryingPace()
        let segments = SegmentDetector.detectSegments(from: workout)

        let slowest1km = segments.first { $0.type == .slowest1km }
        XCTAssertNotNil(slowest1km, "Should detect slowest 1km")
        if let seg = slowest1km {
            XCTAssertEqual(seg.distanceMeters, 1000, accuracy: 60)
            XCTAssertGreaterThan(seg.paceSecondsPerKilometer ?? 0, 0)
        }
    }

    func testFastestSlowerThanSlowest() {
        let workout = createWorkoutWithVaryingPace()
        let segments = SegmentDetector.detectSegments(from: workout)

        let fastest = segments.first { $0.type == .fastest1km }
        let slowest = segments.first { $0.type == .slowest1km }

        if let f = fastest, let s = slowest {
            XCTAssertLessThan(f.paceSecondsPerKilometer!, s.paceSecondsPerKilometer!,
                             "Fastest should have lower pace than slowest")
        }
    }

    // MARK: - Biggest Climb

    func testBiggestClimbDetection() {
        let workout = createWorkoutWithElevation()
        let segments = SegmentDetector.detectSegments(from: workout)

        let climb = segments.first { $0.type == .biggestClimb }
        XCTAssertNotNil(climb, "Should detect biggest climb")
        if let seg = climb {
            XCTAssertGreaterThan(seg.elevationDeltaMeters ?? 0, 0, "Climb should be positive")
        }
    }

    // MARK: - Biggest Descent

    func testBiggestDescentDetection() {
        let workout = createWorkoutWithElevation()
        let segments = SegmentDetector.detectSegments(from: workout)

        let descent = segments.first { $0.type == .biggestDescent }
        XCTAssertNotNil(descent, "Should detect biggest descent")
        if let seg = descent {
            XCTAssertLessThan(seg.elevationDeltaMeters ?? 0, 0, "Descent should be negative")
        }
    }

    func testSegmentDetectionDoesNotTreatRouteGapAsElevationChange() {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            RoutePoint(timestamp: start, latitude: 37.7749, longitude: -122.4194, altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(300), latitude: 37.7839, longitude: -122.4194, altitudeMeters: 10, distanceFromStartMeters: 1_000, elapsedSeconds: 300, routeSegmentIndex: 0),
            RoutePoint(timestamp: start.addingTimeInterval(3_600), latitude: 37.9000, longitude: -122.3000, altitudeMeters: 110, distanceFromStartMeters: 1_000, elapsedSeconds: 3_600, routeSegmentIndex: 1),
            RoutePoint(timestamp: start.addingTimeInterval(3_900), latitude: 37.9090, longitude: -122.3000, altitudeMeters: 110, distanceFromStartMeters: 2_000, elapsedSeconds: 3_900, routeSegmentIndex: 1)
        ])

        let segments = SegmentDetector.detectSegments(from: workout)

        XCTAssertNil(segments.first { $0.type == .biggestClimb })
        XCTAssertNil(segments.first { $0.type == .biggestDescent })
    }

    func testPaceWindowSpansPauseUsingActiveTime() throws {
        let start = Date()
        let workout = RunWorkout(routePoints: [
            segmentPoint(start: start, time: 0, distance: 0, segment: 0),
            segmentPoint(start: start, time: 150, distance: 500, segment: 0),
            segmentPoint(start: start, time: 1_150, distance: 500, segment: 1),
            segmentPoint(start: start, time: 1_300, distance: 1_000, segment: 1),
            segmentPoint(start: start, time: 1_600, distance: 1_500, segment: 1),
            segmentPoint(start: start, time: 1_900, distance: 2_000, segment: 1)
        ])

        let fastest = try XCTUnwrap(
            SegmentDetector.detectSegments(from: workout).first { $0.type == .fastest1km }
        )

        XCTAssertEqual(fastest.startDistanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(fastest.endDistanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(fastest.activeDurationSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(fastest.elapsedDurationSeconds, 1_300, accuracy: 0.001)
        XCTAssertEqual(fastest.paceSecondsPerKilometer ?? -1, 300, accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testShortRouteReturnsNoSegments() {
        let points = [
            RoutePoint(timestamp: Date(), latitude: 37.7749, longitude: -122.4194, altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0),
            RoutePoint(timestamp: Date(), latitude: 37.7750, longitude: -122.4193, altitudeMeters: 15, distanceFromStartMeters: 100, elapsedSeconds: 30)
        ]
        let workout = RunWorkout(routePoints: points)
        let segments = SegmentDetector.detectSegments(from: workout)

        // Should not crash, may return empty or only elevation segments
        XCTAssertTrue(segments.count <= 2, "Short route should have at most elevation segments")
    }

    func testRepeatedPointsDoNotCrash() {
        let points = (0..<20).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: 0, // All same distance
                elapsedSeconds: Double(i) * 10
            )
        }
        let workout = RunWorkout(routePoints: points)
        let segments = SegmentDetector.detectSegments(from: workout)

        // Should not crash
        XCTAssertNotNil(segments)
    }

    func testZeroDurationPointsDoNotCrash() {
        let points = (0..<20).map { i in
            RoutePoint(
                timestamp: Date(),
                latitude: 37.7749 + Double(i) * 0.001,
                longitude: -122.4194,
                altitudeMeters: 10 + Double(i),
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: 0 // All same time
            )
        }
        let workout = RunWorkout(routePoints: points)
        let segments = SegmentDetector.detectSegments(from: workout)

        // Should not crash
        XCTAssertNotNil(segments)
    }

    func testSegmentPointRangesAreValid() {
        let workout = createWorkoutWithVaryingPace()
        let segments = SegmentDetector.detectSegments(from: workout)

        for segment in segments {
            XCTAssertLessThan(segment.sourcePointRange.lowerBound, workout.routePoints.count,
                             "Start index should be within bounds")
            XCTAssertLessThanOrEqual(segment.sourcePointRange.upperBound, workout.routePoints.count,
                             "End index should be within bounds")
            XCTAssertLessThan(segment.sourcePointRange.lowerBound, segment.sourcePointRange.upperBound,
                             "Start should be less than end")
        }
    }

    func testSegmentDistancesWithinBounds() {
        let workout = createWorkoutWithVaryingPace()
        let totalDistance = workout.routePoints.last?.distanceFromStartMeters ?? 0
        let segments = SegmentDetector.detectSegments(from: workout)

        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.startDistanceMeters, 0,
                                       "Start distance should be >= 0")
            XCTAssertLessThanOrEqual(segment.endDistanceMeters, totalDistance + 1,
                                   "End distance should be within total distance")
            XCTAssertLessThan(segment.startDistanceMeters, segment.endDistanceMeters,
                             "Start distance should be less than end")
        }
    }

    // MARK: - Binary Search Helpers

    func testFirstIndexAtOrAfterEmptyArray() {
        let points: [RoutePoint] = []
        XCTAssertNil(RoutePointInterpolator.firstIndex(atOrAfter: 100, in: points))
    }

    func testFirstIndexAtOrAfterSingleElement() {
        let points = [makePoint(distance: 50)]
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: 50, in: points), 0)
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: 51, in: points), nil)
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: 0, in: points), 0)
    }

    func testFirstIndexAtOrAfterExactBoundary() {
        let points = [0, 100, 200, 300, 400].map { makePoint(distance: Double($0)) }
        // Target exactly matches a point
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: 200, in: points), 2)
        // Target between points — should return next point
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: 150, in: points), 2)
        // Target before all
        XCTAssertEqual(RoutePointInterpolator.firstIndex(atOrAfter: -10, in: points), 0)
        // Target beyond all
        XCTAssertNil(RoutePointInterpolator.firstIndex(atOrAfter: 500, in: points))
    }

    func testLastIndexAtOrBeforeEmptyArray() {
        let points: [RoutePoint] = []
        XCTAssertNil(RoutePointInterpolator.lastIndex(atOrBefore: 100, in: points))
    }

    func testLastIndexAtOrBeforeSingleElement() {
        let points = [makePoint(distance: 50)]
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 50, in: points), 0)
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 49, in: points), nil)
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 100, in: points), 0)
    }

    func testLastIndexAtOrBeforeExactBoundary() {
        let points = [0, 100, 200, 300, 400].map { makePoint(distance: Double($0)) }
        // Target exactly matches a point
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 200, in: points), 2)
        // Target between points — should return previous point
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 250, in: points), 2)
        // Target after all
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 500, in: points), 4)
        // Target before all
        XCTAssertNil(RoutePointInterpolator.lastIndex(atOrBefore: -10, in: points))
    }

    func testLastIndexAtOrBeforeDuplicateDistanceReturnsLastMatch() {
        let points = [0, 100, 200, 200, 400].map { makePoint(distance: Double($0)) }
        XCTAssertEqual(RoutePointInterpolator.lastIndex(atOrBefore: 200, in: points), 3)
    }

    func testEmptyRouteReturnsNoSegments() {
        let workout = RunWorkout(routePoints: [])
        let segments = SegmentDetector.detectSegments(from: workout)
        XCTAssertTrue(segments.isEmpty, "Empty route should return no segments")
    }

    func testSinglePointRouteReturnsNoSegments() {
        let points = [makePoint(distance: 0)]
        let workout = RunWorkout(routePoints: points)
        let segments = SegmentDetector.detectSegments(from: workout)
        XCTAssertTrue(segments.isEmpty, "Single point route should return no segments")
    }

    func testIrregularSpacingBinarySearch() {
        // Points with irregular GPS spacing
        let points = [0, 30, 200, 250, 500].map { makePoint(distance: Double($0)) }
        let workout = RunWorkout(routePoints: points)
        // Should not crash — binary search handles irregular spacing
        let segments = SegmentDetector.detectSegments(from: workout)
        XCTAssertNotNil(segments)
    }

    // MARK: - Helpers

    private func makePoint(distance: Double) -> RoutePoint {
        RoutePoint(
            timestamp: Date(),
            latitude: 37.7749,
            longitude: -122.4194,
            altitudeMeters: nil,
            distanceFromStartMeters: distance,
            elapsedSeconds: distance / 3.0 // ~3 m/s pace
        )
    }

    private func segmentPoint(start: Date, time: Double, distance: Double, segment: Int) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: 1 + (distance / 100_000),
            longitude: 1,
            altitudeMeters: 10,
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            routeSegmentIndex: segment
        )
    }

    private func createWorkoutWithVaryingPace() -> RunWorkout {
        // Create a 5km run with varying pace
        // Fast section (first 1km), slow section (middle), medium (end)
        var points: [RoutePoint] = []
        let startDate = Date()

        // Fast section: 4:00/km pace (240 sec/km)
        for i in 0..<20 {
            let dist = Double(i) * 50 // 50m intervals
            let time = dist * 240 / 1000
            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + dist / 111000,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: dist,
                elapsedSeconds: time
            ))
        }

        // Slow section: 6:00/km pace (360 sec/km)
        let fastEndDist = 1000.0
        let fastEndTime = fastEndDist * 240 / 1000
        for i in 1..<21 {
            let dist = fastEndDist + Double(i) * 50
            let time = fastEndTime + Double(i) * 50 * 360 / 1000
            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + dist / 111000,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: dist,
                elapsedSeconds: time
            ))
        }

        // Medium section: 5:00/km pace (300 sec/km)
        let slowEndDist = 2000.0
        let slowEndTime = fastEndTime + 1000 * 360 / 1000
        for i in 1..<21 {
            let dist = slowEndDist + Double(i) * 50
            let time = slowEndTime + Double(i) * 50 * 300 / 1000
            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + dist / 111000,
                longitude: -122.4194,
                altitudeMeters: 10,
                distanceFromStartMeters: dist,
                elapsedSeconds: time
            ))
        }

        return RunWorkout(routePoints: points)
    }

    private func createWorkoutWithElevation() -> RunWorkout {
        // Create a run with climb then descent
        var points: [RoutePoint] = []
        let startDate = Date()

        for i in 0..<50 {
            let dist = Double(i) * 100
            let time = Double(i) * 30
            let elevation: Double
            if i < 25 {
                elevation = 10 + Double(i) * 2 // Climb from 10m to 60m
            } else {
                elevation = 60 - Double(i - 25) * 2 // Descent back
            }
            points.append(RoutePoint(
                timestamp: startDate.addingTimeInterval(time),
                latitude: 37.7749 + dist / 111000,
                longitude: -122.4194,
                altitudeMeters: elevation,
                distanceFromStartMeters: dist,
                elapsedSeconds: time
            ))
        }

        return RunWorkout(routePoints: points)
    }
}
