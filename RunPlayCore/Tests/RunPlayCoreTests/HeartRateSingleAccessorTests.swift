import Foundation
import XCTest
@testable import RunPlayCore

/// The heart-rate single-accessor invariant.
///
/// Heart rate lives **either** on the GPS route points **or** in the standalone
/// series, never in both, and every consumer reads it through one accessor
/// (`forEachHeartRateSample` / `heartRateSamples` /
/// `heartRateBPM(atRoutePointIndex:)`). Construction enforces the exclusivity;
/// these tests pin it on routed, route-less and legacy-snapshot shapes so a
/// future producer cannot accidentally double-store and silently double-count.
///
/// The Apple Health export is what makes the standalone series necessary: its
/// route GPX files carry position, elevation, speed, course and accuracy but no
/// heart rate, so even a *routed* Health run keeps heart rate in the series.
/// That is exactly why the source cannot be inferred from `hasRoute`.
final class HeartRateSingleAccessorTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(
        elapsed: Double,
        rate: Double?,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(elapsed),
            latitude: 47.3769 + elapsed * 0.00001,
            longitude: 8.5417 + elapsed * 0.00001,
            distanceFromStartMeters: 3 * elapsed,
            elapsedSeconds: elapsed,
            heartRateBPM: rate,
            routeSegmentIndex: segment
        )
    }

    private func sample(elapsed: Double, rate: Double?) -> HeartRateSample {
        HeartRateSample(elapsedSeconds: elapsed, heartRateBPM: rate, segmentIndex: 0)
    }

    // MARK: - Source resolution

    /// Routed workout with heart rate on the points: source is `.routePoints`
    /// and no standalone series is stored.
    func testRoutedWorkoutReadsHeartRateFromRoutePoints() {
        let points = (0...10).map { point(elapsed: Double($0) * 30, rate: 140) }
        let workout = RunWorkout(routePoints: points, analysisVersion: 1)

        XCTAssertEqual(workout.heartRateSampleSource, .routePoints)
        XCTAssertNil(workout.heartRateSeries)
        XCTAssertEqual(workout.heartRateSamples.count, points.count)
        XCTAssertEqual(workout.heartRateSamples.first?.heartRateBPM, 140)
        // The accessor reproduces each point's own reading verbatim.
        for index in points.indices {
            XCTAssertEqual(
                workout.heartRateBPM(atRoutePointIndex: index),
                points[index].heartRateBPM
            )
        }
    }

    /// Route-less workout with a standalone series: source is
    /// `.standaloneSeries`.
    func testRouteLessWorkoutReadsHeartRateFromStandaloneSeries() {
        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: 150) }
        let workout = RunWorkout(
            analysisVersion: 1,
            heartRateSeries: series
        )

        XCTAssertFalse(workout.hasRoute)
        XCTAssertEqual(workout.heartRateSampleSource, .standaloneSeries)
        XCTAssertEqual(workout.heartRateSeries?.count, series.count)
        XCTAssertEqual(workout.heartRateSamples.count, series.count)
        XCTAssertEqual(workout.heartRateSamples.first?.heartRateBPM, 150)
    }

    /// The Health-export shape: a **routed** workout whose heart rate still lives
    /// in the series, because its route points carry none. This is the case that
    /// breaks any consumer branching on `routePoints.isEmpty` to find heart rate.
    func testRoutedWorkoutWithStandaloneHeartRateUsesSeries() {
        // Route points with coordinates but no heart rate at all.
        let points = (0...10).map { point(elapsed: Double($0) * 30, rate: nil) }
        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: 155) }
        let workout = RunWorkout(
            routePoints: points,
            analysisVersion: 1,
            heartRateSeries: series
        )

        XCTAssertTrue(workout.hasRoute)
        XCTAssertEqual(workout.heartRateSampleSource, .standaloneSeries)
        XCTAssertEqual(workout.heartRateSeries?.count, series.count)
        // Indexed lookup resolves through the series by elapsed time, not
        // through the (empty) point readings.
        for index in points.indices {
            XCTAssertEqual(workout.heartRateBPM(atRoutePointIndex: index), 155)
        }
    }

    /// No heart rate anywhere: source is `.none`, the series is not stored, and
    /// `hasHeartRateData` is false. The accessor still visits one sample per
    /// route point — with a nil reading — because gap positions are meaningful
    /// evidence for interval weighting, not noise to compact away.
    func testWorkoutWithoutHeartRateResolvesToNone() {
        let points = (0...10).map { point(elapsed: Double($0) * 30, rate: nil) }
        let workout = RunWorkout(routePoints: points, analysisVersion: 1)

        XCTAssertEqual(workout.heartRateSampleSource, .none)
        XCTAssertNil(workout.heartRateSeries)
        XCTAssertEqual(workout.heartRateSamples.count, points.count)
        XCTAssertTrue(workout.heartRateSamples.allSatisfy { $0.heartRateBPM == nil })
        XCTAssertFalse(workout.hasHeartRateData)
    }

    // MARK: - Exclusivity enforcement at construction

    /// The single-source invariant: supplying a series to a workout whose route
    /// points already carry valid heart rate drops the series. Never both.
    func testSeriesIsDroppedWhenRoutePointsCarryHeartRate() {
        let points = (0...10).map { point(elapsed: Double($0) * 30, rate: 140) }
        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: 999) }
        let workout = RunWorkout(
            routePoints: points,
            analysisVersion: 1,
            heartRateSeries: series
        )

        XCTAssertNil(workout.heartRateSeries)
        XCTAssertEqual(workout.heartRateSampleSource, .routePoints)
        // The dropped series' bogus reading must never surface.
        XCTAssertEqual(workout.heartRateSamples.first?.heartRateBPM, 140)
        XCTAssertNotEqual(workout.heartRateSamples.first?.heartRateBPM, 999)
    }

    /// A series carrying no valid reading anywhere is inert: it is not stored,
    /// so the workout reports `.none` rather than a series of nils.
    func testSeriesWithoutAnyValidReadingIsNotStored() {
        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: nil) }
        let workout = RunWorkout(analysisVersion: 1, heartRateSeries: series)

        XCTAssertNil(workout.heartRateSeries)
        XCTAssertEqual(workout.heartRateSampleSource, .none)
    }

    /// An out-of-order series is sorted into the elapsed-time domain and clamped
    /// monotonic, so no consumer can produce a negative interval weight from it.
    func testSeriesIsSortedAndMonotonicallyClamped() {
        let shuffled = [
            sample(elapsed: 60, rate: 150),
            sample(elapsed: 0, rate: 140),
            sample(elapsed: 30, rate: 145),
        ]
        let workout = RunWorkout(analysisVersion: 1, heartRateSeries: shuffled)
        let elapsed = workout.heartRateSamples.map(\.elapsedSeconds)

        XCTAssertEqual(elapsed, [0, 30, 60])
        // Non-decreasing by construction.
        for pair in zip(elapsed, elapsed.dropFirst()) where pair.0 > pair.1 {
            XCTFail("series must be monotonic, got \(elapsed)")
        }
    }

    // MARK: - The allocation-free and materializing forms agree

    /// `forEachHeartRateSample` and `heartRateSamples` resolve the same source
    /// through the same rule, so they can never diverge.
    func testForEachAndMaterializedAccessorAgree() {
        let points = (0...10).map { point(elapsed: Double($0) * 30, rate: 140 + Double($0)) }
        let routed = RunWorkout(routePoints: points, analysisVersion: 1)
        var visited: [HeartRateSample] = []
        routed.forEachHeartRateSample { visited.append($0) }
        XCTAssertEqual(visited, routed.heartRateSamples)

        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: 150 + Double($0)) }
        let routeLess = RunWorkout(analysisVersion: 1, heartRateSeries: series)
        var visitedSeries: [HeartRateSample] = []
        routeLess.forEachHeartRateSample { visitedSeries.append($0) }
        XCTAssertEqual(visitedSeries, routeLess.heartRateSamples)
    }

    // MARK: - Consumers read through the accessor, not routePoints

    /// The summary heart-rate aggregate uses the accessor, so a route-less run's
    /// standalone series produces summary average/max just like a routed run.
    func testSummaryHeartRateReadsThroughAccessorForRouteLessRun() {
        let series = (0...10).map { sample(elapsed: Double($0) * 30, rate: 140 + Double($0)) }
        var workout = RunWorkout(
            summary: RunSummary(totalDistanceMeters: 3_000, totalElapsedSeconds: 300),
            analysisVersion: RunWorkout.currentAnalysisVersion,
            heartRateSeries: series
        )
        WorkoutAnalyzer().analyze(&workout)

        XCTAssertNotNil(workout.summary.averageHeartRateBPM)
        XCTAssertEqual(workout.summary.maxHeartRateBPM, 150)
        // Mean of 140...150.
        XCTAssertEqual(workout.summary.averageHeartRateBPM ?? 0, 145, accuracy: 0.5)
    }

    /// Training load reads through the accessor: a route-less run with a
    /// standalone series is *measured*, identical in shape to a routed run.
    func testTrainingLoadReadsThroughAccessorForRouteLessRun() throws {
        let series = (0...40).map { sample(elapsed: Double($0) * 30, rate: 100) }
        let workout = RunWorkout(
            summary: RunSummary(
                totalDistanceMeters: 3_600,
                totalElapsedSeconds: 1_200,
                averageSpeedMetersPerSecond: 3
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion,
            heartRateSeries: series
        )
        let snapshot = try TrainingLoadCalculator.compute(
            for: workout,
            profile: AthleteProfile(restingHeartRateBPM: 50, maximumHeartRateBPM: 150),
            referenceYear: 2026
        )
        XCTAssertEqual(snapshot.kind, .measured)
        XCTAssertEqual(snapshot.meanHeartRateBPM, 100)
    }

    // MARK: - Legacy snapshot compatibility

    /// A legacy persisted snapshot predating `heartRateSeries` decodes with a nil
    /// series and resolves its source from the route points alone — no migration
    /// required, and re-encoding omits the absent key so the payload stays
    /// byte-identical.
    func testLegacySnapshotDecodesWithoutHeartRateSeries() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "metadata": { "activityType": "running" },
          "source": "fit",
          "routePoints": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "timestamp": "2023-11-14T22:13:20Z",
              "latitude": 47.3769,
              "longitude": 8.5417,
              "distanceFromStartMeters": 0,
              "elapsedSeconds": 0,
              "heartRateBPM": 141,
              "routeSegmentIndex": 0
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "timestamp": "2023-11-14T22:13:50Z",
              "latitude": 47.3770,
              "longitude": 8.5418,
              "distanceFromStartMeters": 90,
              "elapsedSeconds": 30,
              "heartRateBPM": 143,
              "routeSegmentIndex": 0
            }
          ],
          "splits": [],
          "summary": {
            "totalDistanceMeters": 90,
            "totalElapsedSeconds": 30,
            "totalActiveSeconds": 30,
            "averagePaceSecondsPerKilometer": 333,
            "averageSpeedMetersPerSecond": 3,
            "elevationGainMeters": 0,
            "elevationLossMeters": 0
          },
          "segments": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workout = try decoder.decode(RunWorkout.self, from: data)

        XCTAssertNil(workout.heartRateSeries)
        XCTAssertEqual(workout.heartRateSampleSource, .routePoints)
        XCTAssertEqual(workout.heartRateSamples.count, 2)
        XCTAssertEqual(workout.heartRateBPM(atRoutePointIndex: 1), 143)

        // Re-encoding must not introduce the heartRateSeries key.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try encoder.encode(workout)
        let text = try XCTUnwrap(String(data: reencoded, encoding: .utf8))
        XCTAssertFalse(text.contains("heartRateSeries"))
    }

    /// A snapshot that *does* carry a standalone series round-trips it exactly,
    /// including the source resolution.
    func testStandaloneSeriesRoundTripsThroughCoding() throws {
        let series = (0...4).map { sample(elapsed: Double($0) * 60, rate: 148 + Double($0)) }
        let workout = RunWorkout(
            summary: RunSummary(totalDistanceMeters: 1_500, totalElapsedSeconds: 240),
            analysisVersion: RunWorkout.currentAnalysisVersion,
            heartRateSeries: series
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(workout)
        let decoded = try JSONDecoder().decode(RunWorkout.self, from: data)

        XCTAssertEqual(decoded.heartRateSeries, workout.heartRateSeries)
        XCTAssertEqual(decoded.heartRateSampleSource, .standaloneSeries)
        XCTAssertEqual(decoded.heartRateSamples.count, series.count)
    }
}
