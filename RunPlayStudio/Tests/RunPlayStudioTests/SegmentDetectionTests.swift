import XCTest
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

    // MARK: - Helpers

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
