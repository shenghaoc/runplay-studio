import XCTest
@testable import RunPlayCore

final class WorkoutRawElevationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(
        altitude: Double?,
        elapsed: Double,
        segment: Int = 0,
        index: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(elapsed),
            latitude: 1.30 + Double(index) * 0.001,
            longitude: 103.8,
            altitudeMeters: altitude,
            distanceFromStartMeters: elapsed * 3,
            elapsedSeconds: elapsed,
            routeSegmentIndex: segment
        )
    }

    // MARK: - Extraction-stage totals

    func testRawTotalsSumAdjacentDeltasWithinSegment() {
        let totals = WorkoutAnalyzer.rawElevationTotals(in: [
            point(altitude: 100, elapsed: 0, index: 0),
            point(altitude: 103, elapsed: 10, index: 1),
            point(altitude: 101, elapsed: 20, index: 2),
            point(altitude: 105, elapsed: 30, index: 3)
        ])
        XCTAssertEqual(totals.gain ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(totals.loss ?? 0, 2, accuracy: 1e-9)
    }

    func testRawTotalsSkipSegmentBoundaries() {
        let totals = WorkoutAnalyzer.rawElevationTotals(in: [
            point(altitude: 100, elapsed: 0, segment: 0, index: 0),
            point(altitude: 102, elapsed: 10, segment: 0, index: 1),
            point(altitude: 200, elapsed: 300, segment: 1, index: 2),
            point(altitude: 190, elapsed: 310, segment: 1, index: 3)
        ])
        // The 102→200 jump across the segment boundary contributes nothing.
        XCTAssertEqual(totals.gain ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(totals.loss ?? 0, 10, accuracy: 1e-9)
    }

    func testRawTotalsSkipMissingAltitudePairs() {
        let totals = WorkoutAnalyzer.rawElevationTotals(in: [
            point(altitude: 100, elapsed: 0, index: 0),
            point(altitude: nil, elapsed: 10, index: 1),
            point(altitude: 104, elapsed: 20, index: 2),
            point(altitude: 106, elapsed: 30, index: 3),
            point(altitude: .nan, elapsed: 40, index: 4),
            point(altitude: 108, elapsed: 50, index: 5)
        ])
        // Only 104→106 forms a pair: 100 is isolated by the nil sample and
        // 108 is isolated by the non-finite sample.
        XCTAssertEqual(totals.gain ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(totals.loss ?? 0, 0, accuracy: 1e-9)
    }

    func testRawTotalsNilWithoutFinitePairs() {
        XCTAssertNil(WorkoutAnalyzer.rawElevationTotals(in: []).gain)
        XCTAssertNil(WorkoutAnalyzer.rawElevationTotals(in: [point(altitude: 10, elapsed: 0)]).gain)
        XCTAssertNil(
            WorkoutAnalyzer.rawElevationTotals(in: [
                point(altitude: nil, elapsed: 0, index: 0),
                point(altitude: nil, elapsed: 10, index: 1)
            ]).gain
        )
    }

    // MARK: - Analysis persistence

    func testAnalysisPersistsRawTotalsAndBumpsVersion() throws {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(startDate: origin),
            routePoints: [
                point(altitude: 100, elapsed: 0, index: 0),
                point(altitude: 104, elapsed: 30, index: 1),
                point(altitude: 102, elapsed: 60, index: 2)
            ]
        )
        let analyzer = WorkoutAnalyzer()
        try analyzer.normalizeAndAnalyze(&workout, distancePolicy: .computeFromCoordinates)
        XCTAssertEqual(workout.analysisVersion, RunWorkout.currentAnalysisVersion)
        XCTAssertEqual(workout.summary.rawElevationGainMeters ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.rawElevationLossMeters ?? 0, 2, accuracy: 1e-9)
    }

    func testLegacySummaryDecodesWithoutRawTotals() throws {
        // A version-5 snapshot payload without raw fields decodes with nil.
        let legacyJSON = """
        {
          "totalDistanceMeters": 10000,
          "totalElapsedSeconds": 4000,
          "totalActiveSeconds": 3600,
          "averagePaceSecondsPerKilometer": 360,
          "averageSpeedMetersPerSecond": 2.78,
          "elevationGainMeters": 120,
          "elevationLossMeters": 80
        }
        """
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(summary.rawElevationGainMeters)
        XCTAssertNil(summary.rawElevationLossMeters)
        XCTAssertEqual(summary.elevationGainMeters, 120)

        let roundTrip = try JSONDecoder().decode(
            RunSummary.self,
            from: try JSONEncoder().encode(summary)
        )
        XCTAssertNil(roundTrip.rawElevationGainMeters)
    }
}
