import XCTest
@testable import RunPlayCore

final class RecordedLapAnalyzerTests: XCTestCase {

    private func makeRoute(
        pointCount: Int = 21,
        stepMeters: Double = 50,
        stepSeconds: Double = 30,
        pauseAfterIndex: Int? = nil,
        pauseSeconds: Double = 60
    ) -> [RoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed: Double = 0
        var distance: Double = 0
        var segment = 0

        for i in 0..<pointCount {
            if let pauseAfterIndex, i == pauseAfterIndex + 1 {
                segment += 1
                elapsed += pauseSeconds
            }
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.7 + Double(i) * 0.0004,
                longitude: -122.4,
                altitudeMeters: 10 + Double(i),
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                heartRateBPM: 140 + Double(i % 10),
                cadence: 80 + Double(i % 5),
                routeSegmentIndex: segment
            ))
            if i + 1 < pointCount {
                elapsed += stepSeconds
                distance += stepMeters
            }
        }
        return points
    }

    func testNoPauseLap() throws {
        let points = makeRoute()
        let start = points[0].timestamp
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .manual,
            sourceStartDate: start,
            sourceEndDate: start.addingTimeInterval(300),
            reportedMetrics: RecordedLapReportedMetrics(elapsedSeconds: 300, distanceMeters: 500)
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )
        XCTAssertEqual(result.laps.count, 1)
        let lap = result.laps[0]
        XCTAssertEqual(lap.elapsedSeconds, 300, accuracy: 0.5)
        XCTAssertEqual(lap.activeSeconds, 300, accuracy: 0.5)
        XCTAssertEqual(lap.pausedSeconds, 0, accuracy: 0.5)
        XCTAssertGreaterThan(lap.distanceMeters, 0)
        XCTAssertEqual(lap.elapsedSeconds, lap.activeSeconds + lap.pausedSeconds, accuracy: 0.001)
        XCTAssertEqual(lap.activeSeconds, lap.movingSeconds + lap.stoppedSeconds, accuracy: 0.001)
    }

    func testLapContainingRecordingPause() throws {
        let points = makeRoute(pauseAfterIndex: 5, pauseSeconds: 90)
        let start = points[0].timestamp
        let end = points.last!.timestamp
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .distance,
            sourceStartDate: start,
            sourceEndDate: end,
            reportedMetrics: nil
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )
        XCTAssertEqual(result.laps.count, 1)
        let lap = result.laps[0]
        XCTAssertGreaterThan(lap.pausedSeconds, 0)
        XCTAssertEqual(lap.elapsedSeconds, lap.activeSeconds + lap.pausedSeconds, accuracy: 0.001)
    }

    func testMaterialSourceDistanceMismatch() throws {
        let points = makeRoute()
        let start = points[0].timestamp
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .distance,
            sourceStartDate: start,
            sourceEndDate: start.addingTimeInterval(300),
            reportedMetrics: RecordedLapReportedMetrics(distanceMeters: 50_000)
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )
        XCTAssertEqual(result.diagnostics.distanceMismatchCount, 1)
        // Canonical distance is route-derived, not the absurd source value.
        XCTAssertLessThan(result.laps[0].distanceMeters, 2_000)
    }

    func testMalformedBoundariesSkipped() throws {
        let points = makeRoute()
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .manual,
            sourceStartDate: nil,
            sourceEndDate: nil,
            reportedMetrics: nil
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )
        XCTAssertTrue(result.laps.isEmpty)
        XCTAssertEqual(result.diagnostics.malformedLapCount, 1)
        XCTAssertTrue(result.warnings.contains(.recordedLapsMalformedSkipped))
    }

    func testSubCentisecondBoundaryRoundingDoesNotCountAsClamp() throws {
        let points = makeRoute()
        let start = points[0].timestamp
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .manual,
            sourceStartDate: start.addingTimeInterval(-0.001),
            sourceEndDate: points.last!.timestamp.addingTimeInterval(0.001),
            reportedMetrics: nil
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))

        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )

        XCTAssertEqual(result.laps.count, 1)
        XCTAssertEqual(result.diagnostics.clampedBoundaryCount, 0)
    }

    func testFirstLapStartingBeforeFirstGPSFixIsClamped() throws {
        let points = makeRoute()
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .fit,
            trigger: .manual,
            sourceStartDate: points[0].timestamp.addingTimeInterval(-20),
            sourceEndDate: points.last!.timestamp,
            reportedMetrics: nil
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))

        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .fit
        )

        XCTAssertEqual(result.laps.count, 1)
        XCTAssertEqual(result.laps[0].startElapsedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(result.diagnostics.clampedBoundaryCount, 1)
    }

    func testCancellation() {
        let points = makeRoute(pointCount: 50)
        let start = points[0].timestamp
        let provisionals = (0..<20).map { i in
            RecordedLap.provisional(
                lapIndex: i + 1,
                source: .fit,
                trigger: .manual,
                sourceStartDate: start.addingTimeInterval(Double(i) * 30),
                sourceEndDate: start.addingTimeInterval(Double(i + 1) * 30),
                reportedMetrics: nil
            )
        }
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        XCTAssertThrowsError(
            try RecordedLapAnalyzer.analyze(
                provisionalLaps: provisionals,
                routePoints: points,
                context: context,
                source: .fit,
                cancellationCheckStride: 1,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLargeRouteManyLapsPerformance() throws {
        // 2_001 points × 50 m ≈ 100 km; 100 synthetic laps.
        let points = makeRoute(pointCount: 2_001, stepMeters: 50, stepSeconds: 20)
        let start = points[0].timestamp
        let lapDuration = points.last!.elapsedSeconds / 100
        let provisionals = (0..<100).map { i in
            RecordedLap.provisional(
                lapIndex: i + 1,
                source: .fit,
                trigger: .distance,
                sourceStartDate: start.addingTimeInterval(Double(i) * lapDuration),
                sourceEndDate: start.addingTimeInterval(Double(i + 1) * lapDuration),
                reportedMetrics: nil
            )
        }
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))

        measure {
            do {
                let result = try RecordedLapAnalyzer.analyze(
                    provisionalLaps: provisionals,
                    routePoints: points,
                    context: context,
                    source: .fit
                )
                XCTAssertEqual(result.laps.count, 100)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHRAndCadenceAggregation() throws {
        let points = makeRoute()
        let start = points[0].timestamp
        let provisional = RecordedLap.provisional(
            lapIndex: 1,
            source: .tcx,
            trigger: .manual,
            sourceStartDate: start,
            sourceEndDate: start.addingTimeInterval(300),
            reportedMetrics: nil
        )
        let context = WorkoutAnalysisContext(workout: RunWorkout(routePoints: points))
        let result = try RecordedLapAnalyzer.analyze(
            provisionalLaps: [provisional],
            routePoints: points,
            context: context,
            source: .tcx
        )
        XCTAssertNotNil(result.laps[0].averageHeartRateBPM)
        XCTAssertNotNil(result.laps[0].maximumHeartRateBPM)
        XCTAssertNotNil(result.laps[0].averageCadence)
    }
}
