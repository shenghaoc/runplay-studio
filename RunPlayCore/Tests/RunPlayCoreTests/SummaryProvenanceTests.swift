import Foundation
import XCTest
@testable import RunPlayCore

/// The summary-path invariant: source-supplied distance and duration survive
/// analysis **only** when `routePoints` is empty. Routed workouts keep
/// route-derived distance exactly as they always have, so pace and splits stay
/// consistent with every other importer — including Apple Health export runs
/// that arrive with a route GPX.
final class SummaryProvenanceTests: XCTestCase {

    // MARK: - Fixtures

    private static let origin = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// Routed run with a complete device-supplied distance series and no
    /// altitude. Every summary value it produces is pure IEEE arithmetic — no
    /// `sin`/`cos`/`atan2`/`sqrt` — so its encoding is byte-stable across
    /// macOS and Linux, unlike a coordinate-derived route whose haversine
    /// distances differ in the last bits between libm implementations.
    private func suppliedDistanceRoute() -> [RoutePoint] {
        var points: [RoutePoint] = []
        for index in 0..<40 {
            let elapsed = Double(index) * 30
            points.append(RoutePoint(
                timestamp: Self.origin.addingTimeInterval(elapsed),
                latitude: 47.0,
                longitude: 8.0,
                altitudeMeters: nil,
                distanceFromStartMeters: Double(index) * 100,
                elapsedSeconds: elapsed,
                heartRateBPM: 140.0 + Double(index),
                routeSegmentIndex: 0
            ))
        }
        return points
    }

    /// Routed run with genuinely moving coordinates and no supplied distance
    /// series, so distance must come from the geometry. Used only for
    /// sign/count assertions — its haversine distances are not bit-stable
    /// across libm implementations, so it is never byte-pinned.
    private func coordinateDerivedRoute() -> [RoutePoint] {
        var points: [RoutePoint] = []
        for index in 0..<40 {
            let elapsed = Double(index) * 30
            points.append(RoutePoint(
                timestamp: Self.origin.addingTimeInterval(elapsed),
                latitude: 47.3769 + Double(index) * 0.0004,
                longitude: 8.5417 + Double(index) * 0.0003,
                altitudeMeters: nil,
                distanceFromStartMeters: 0,
                elapsedSeconds: elapsed,
                heartRateBPM: 145.0 + Double(index),
                routeSegmentIndex: 0
            ))
        }
        return points
    }

    /// Routed run with a pause gap, so per-segment rebasing and paused time
    /// are exercised without any libm-dependent value.
    private func suppliedDistanceRouteWithPause() -> [RoutePoint] {
        var points: [RoutePoint] = []
        for index in 0..<20 {
            let elapsed = Double(index) * 30
            points.append(RoutePoint(
                timestamp: Self.origin.addingTimeInterval(elapsed),
                latitude: 47.0,
                longitude: 8.0,
                altitudeMeters: nil,
                distanceFromStartMeters: Double(index) * 100,
                elapsedSeconds: elapsed,
                heartRateBPM: 150.0,
                routeSegmentIndex: 0
            ))
        }
        for index in 0..<20 {
            let elapsed = 1_200.0 + Double(index) * 30
            points.append(RoutePoint(
                timestamp: Self.origin.addingTimeInterval(elapsed),
                latitude: 47.0,
                longitude: 8.0,
                altitudeMeters: nil,
                distanceFromStartMeters: 1_900.0 + Double(index) * 100,
                elapsedSeconds: elapsed,
                heartRateBPM: 160.0,
                routeSegmentIndex: 1
            ))
        }
        return points
    }

    /// The store's exact encoder settings (`FileWorkoutLibraryStore`), so the
    /// goldens below are the bytes a snapshot file actually carries.
    private func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func encodedSummaryBytes(_ workout: RunWorkout) throws -> String {
        let data = try storeEncoder().encode(workout.summary)
        return String(decoding: data, as: UTF8.self)
    }

    private func routedWorkout(
        points: [RoutePoint],
        source: WorkoutSource = .json,
        distancePolicy: RouteDistancePolicy = .useSuppliedDistancesWhenValid
    ) throws -> RunWorkout {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(
                name: "routed",
                activityType: "running",
                startDate: Self.origin,
                endDate: points.last?.timestamp ?? Self.origin
            ),
            source: source,
            routePoints: points,
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: distancePolicy,
            isCancelled: { false }
        )
        return workout
    }

    // MARK: - Routed workouts never pick up a source value

    /// The direction that matters most: a routed run whose summary already
    /// carries a source-reported total must not inherit it. Distance comes
    /// from the route, and provenance stays the historical default.
    func testRoutedWorkoutIgnoresPresetSourceTotals() throws {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(activityType: "running", startDate: Self.origin),
            source: .json,
            routePoints: suppliedDistanceRoute(),
            summary: RunSummary(
                totalDistanceMeters: 99_999,
                totalElapsedSeconds: 12_345
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: .useSuppliedDistancesWhenValid,
            isCancelled: { false }
        )

        XCTAssertEqual(workout.summary.totalDistanceMeters, 3_900, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 1_170, accuracy: 1e-9)
        XCTAssertNotEqual(workout.summary.totalDistanceMeters, 99_999)
        XCTAssertNotEqual(workout.summary.totalElapsedSeconds, 12_345)
        XCTAssertEqual(workout.summary.distanceProvenance, .gpsDerived)
        XCTAssertFalse(workout.routePoints.isEmpty)
    }

    /// The reanalysis path (`analyze`, used by library load and migration)
    /// must reach the same conclusion as the import path.
    func testRoutedWorkoutIgnoresPresetSourceTotalsOnReanalyze() throws {
        var workout = try routedWorkout(points: suppliedDistanceRoute())
        workout.summary.totalDistanceMeters = 99_999
        workout.summary.totalElapsedSeconds = 12_345

        WorkoutAnalyzer().analyze(&workout)

        XCTAssertEqual(workout.summary.totalDistanceMeters, 3_900, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 1_170, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.distanceProvenance, .gpsDerived)
    }

    /// Importers call `normalizeAndAnalyze`, so route-less preservation has to
    /// hold on that path as well — the route-quality stage returns an empty
    /// result for an empty route and must not zero the reported totals.
    func testRouteLessTotalsSurviveNormalizeAndAnalyze() throws {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(activityType: "running", startDate: Self.origin),
            source: .json,
            routePoints: [],
            summary: RunSummary(
                totalDistanceMeters: 6_400,
                totalElapsedSeconds: 1_920
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        try WorkoutAnalyzer().normalizeAndAnalyze(
            &workout,
            distancePolicy: .computeFromCoordinates,
            isCancelled: { false }
        )

        XCTAssertTrue(workout.routePoints.isEmpty)
        XCTAssertEqual(workout.summary.totalDistanceMeters, 6_400, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 1_920, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.distanceProvenance, .sourceReported)
        // No route means no splits and no segments; nothing is synthesized.
        XCTAssertTrue(workout.splits.isEmpty)
        XCTAssertTrue(workout.segments.isEmpty)
    }

    /// A Health-export run that *does* carry a route GPX is routed, so it
    /// keeps route-derived distance and its splits stay consistent with every
    /// other importer rather than being source-anchored.
    func testRoutedHealthExportStyleRunKeepsRouteDerivedDistance() throws {
        let workout = try routedWorkout(
            points: coordinateDerivedRoute(),
            source: .gpx,
            distancePolicy: .computeFromCoordinates
        )

        XCTAssertEqual(workout.summary.distanceProvenance, .gpsDerived)
        XCTAssertEqual(workout.routeDistanceSource, .coordinateDerived)
        XCTAssertGreaterThan(workout.summary.totalDistanceMeters, 0)
        XCTAssertFalse(workout.splits.isEmpty)
        // Splits are anchored to route distance, and their paces are finite
        // and derived — the property that keeps a routed Health-export run
        // indistinguishable from any other routed import.
        for split in workout.splits {
            XCTAssertGreaterThan(split.distanceMeters, 0)
            XCTAssertTrue(split.paceSecondsPerKilometer.isFinite)
        }
    }

    // MARK: - Route-less workouts preserve source totals

    /// The new behaviour: a route-less workout keeps what the source reported,
    /// and says so through provenance.
    func testRouteLessWorkoutPreservesSourceReportedTotals() throws {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(activityType: "running", startDate: Self.origin),
            source: .json,
            routePoints: [],
            summary: RunSummary(
                totalDistanceMeters: 5_000,
                totalElapsedSeconds: 1_500
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        WorkoutAnalyzer().analyze(&workout)

        XCTAssertTrue(workout.routePoints.isEmpty)
        XCTAssertEqual(workout.summary.totalDistanceMeters, 5_000, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 1_500, accuracy: 1e-9)
        XCTAssertEqual(workout.summary.distanceProvenance, .sourceReported)
    }

    /// A route-less source reports elapsed time only and carries no pause
    /// boundaries, so active time equals elapsed and pace is the sole speed.
    func testRouteLessSummaryDerivesPaceFromReportedTotals() throws {
        var workout = RunWorkout(
            routePoints: [],
            summary: RunSummary(
                totalDistanceMeters: 10_000,
                totalElapsedSeconds: 3_000
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        WorkoutAnalyzer().analyze(&workout)

        let summary = workout.summary
        XCTAssertEqual(summary.totalActiveSeconds, 3_000, accuracy: 1e-9)
        XCTAssertEqual(summary.totalPausedSeconds, 0, accuracy: 1e-9)
        // 10 km in 3000 s → 3.3333 m/s → 300 s/km.
        XCTAssertEqual(summary.averageSpeedMetersPerSecond, 10.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.averagePaceSecondsPerKilometer, 300, accuracy: 1e-9)
        XCTAssertEqual(summary.elapsedPaceSecondsPerKilometer, 300, accuracy: 1e-9)
        XCTAssertEqual(summary.movingPaceSecondsPerKilometer, 300, accuracy: 1e-9)
        XCTAssertEqual(summary.distanceProvenance, .sourceReported)
    }

    /// Re-analysing a route-less workout must be idempotent: the preserved
    /// totals feed the next pass unchanged rather than decaying.
    func testRouteLessAnalysisIsIdempotent() throws {
        var workout = RunWorkout(
            routePoints: [],
            summary: RunSummary(
                totalDistanceMeters: 7_500,
                totalElapsedSeconds: 2_250
            ),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        WorkoutAnalyzer().analyze(&workout)
        let first = workout.summary

        WorkoutAnalyzer().analyze(&workout)
        let second = workout.summary

        XCTAssertEqual(first, second)
        XCTAssertEqual(second.totalDistanceMeters, 7_500, accuracy: 1e-9)
        XCTAssertEqual(second.totalElapsedSeconds, 2_250, accuracy: 1e-9)
        XCTAssertEqual(second.distanceProvenance, .sourceReported)
    }

    /// Distance alone, or duration alone, is enough to mark the summary
    /// source-reported; neither has to be present for the other.
    func testRouteLessPreservesDistanceOnlyOrDurationOnly() throws {
        var distanceOnly = RunWorkout(
            routePoints: [],
            summary: RunSummary(totalDistanceMeters: 4_200),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
        WorkoutAnalyzer().analyze(&distanceOnly)
        XCTAssertEqual(distanceOnly.summary.totalDistanceMeters, 4_200, accuracy: 1e-9)
        XCTAssertEqual(distanceOnly.summary.distanceProvenance, .sourceReported)
        // No duration means no pace; the summary must not invent one.
        XCTAssertEqual(distanceOnly.summary.averagePaceSecondsPerKilometer, 0)

        var durationOnly = RunWorkout(
            routePoints: [],
            summary: RunSummary(totalElapsedSeconds: 1_800),
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
        WorkoutAnalyzer().analyze(&durationOnly)
        XCTAssertEqual(durationOnly.summary.totalElapsedSeconds, 1_800, accuracy: 1e-9)
        XCTAssertEqual(durationOnly.summary.totalDistanceMeters, 0, accuracy: 1e-9)
        XCTAssertEqual(durationOnly.summary.distanceProvenance, .sourceReported)
        XCTAssertEqual(durationOnly.summary.averageSpeedMetersPerSecond, 0)
    }

    /// An unbounded reported speed must still be clamped by the same policy
    /// that guards every other importer, so a malformed source total cannot
    /// produce an absurd pace.
    func testRouteLessRespectsMaximumSourceSpeedPolicy() throws {
        let policy = RouteQualityPolicy.runningDefault
        // 10 km in 10 s is physically impossible for a run.
        let summary = WorkoutAnalyzer.routeLessSummary(
            from: RunSummary(totalDistanceMeters: 10_000, totalElapsedSeconds: 10),
            policy: policy
        )

        XCTAssertEqual(summary.averageSpeedMetersPerSecond, 0)
        XCTAssertEqual(summary.averagePaceSecondsPerKilometer, 0)
        // The reported totals themselves are preserved; only the derived rate
        // is rejected.
        XCTAssertEqual(summary.totalDistanceMeters, 10_000, accuracy: 1e-9)
        XCTAssertEqual(summary.totalElapsedSeconds, 10, accuracy: 1e-9)
        XCTAssertEqual(summary.distanceProvenance, .sourceReported)
    }

    // MARK: - Legacy snapshots are untouched

    /// The historical case: an empty route with nothing reported stays an
    /// all-zero summary carrying the default provenance, which is omitted from
    /// the encoding. This is what every pre-change snapshot produced.
    func testEmptyRouteWithoutSourceTotalsStaysZero() throws {
        var workout = RunWorkout(
            routePoints: [],
            analysisVersion: RunWorkout.currentAnalysisVersion
        )

        WorkoutAnalyzer().analyze(&workout)

        XCTAssertEqual(workout.summary, RunSummary())
        XCTAssertEqual(workout.summary.totalDistanceMeters, 0)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 0)
        XCTAssertEqual(workout.summary.distanceProvenance, .gpsDerived)
    }

    /// The committed v0 snapshot still decodes and re-analyses without
    /// acquiring provenance, because its route is not empty.
    func testLegacyPausedSnapshotKeepsGPSDerivedProvenance() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "legacy-paused-workout-v0",
            withExtension: "json"
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)

        var decoded = try decoder.decode(RunWorkout.self, from: data)
        XCTAssertEqual(decoded.summary.distanceProvenance, .gpsDerived)
        XCTAssertFalse(decoded.routePoints.isEmpty)

        WorkoutAnalyzer().analyze(&decoded)
        XCTAssertEqual(decoded.summary.distanceProvenance, .gpsDerived)
        XCTAssertEqual(decoded.summary.totalDistanceMeters, 2_000, accuracy: 1e-9)
    }

    // MARK: - Codable contract

    /// `.gpsDerived` is omitted from the encoding and absent keys decode back
    /// to it, which is the property that keeps existing snapshot files
    /// byte-identical.
    func testGPSDerivedProvenanceIsOmittedFromEncoding() throws {
        let routed = try routedWorkout(points: suppliedDistanceRoute())
        XCTAssertEqual(routed.summary.distanceProvenance, .gpsDerived)

        let bytes = try encodedSummaryBytes(routed)
        XCTAssertFalse(bytes.contains("distanceProvenance"))

        let decoded = try JSONDecoder().decode(RunSummary.self, from: Data(bytes.utf8))
        XCTAssertEqual(decoded.distanceProvenance, .gpsDerived)
        XCTAssertEqual(decoded, routed.summary)
    }

    func testSourceReportedProvenanceRoundTrips() throws {
        let summary = RunSummary(
            totalDistanceMeters: 5_000,
            totalElapsedSeconds: 1_500,
            totalActiveSeconds: 1_500,
            distanceProvenance: .sourceReported
        )

        let data = try storeEncoder().encode(summary)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("sourceReported"))

        let decoded = try JSONDecoder().decode(RunSummary.self, from: data)
        XCTAssertEqual(decoded.distanceProvenance, SummaryDistanceProvenance.sourceReported)
        XCTAssertEqual(decoded, summary)
    }

    /// A snapshot written before provenance existed has no key at all; it must
    /// decode to the historical default rather than fail.
    func testSnapshotWithoutProvenanceKeyDecodesAsGPSDerived() throws {
        let legacyJSON = """
        {
          "totalDistanceMeters": 5000,
          "totalElapsedSeconds": 1500,
          "averagePaceSecondsPerKilometer": 300,
          "averageSpeedMetersPerSecond": 3.3333333333333335,
          "elevationGainMeters": 0,
          "elevationLossMeters": 0
        }
        """

        let decoded = try JSONDecoder().decode(RunSummary.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.distanceProvenance, .gpsDerived)
        XCTAssertEqual(decoded.totalDistanceMeters, 5_000, accuracy: 1e-9)
        // Re-encoding must not add the key, so the file stays unchanged.
        let reencoded = String(
            decoding: try storeEncoder().encode(decoded),
            as: UTF8.self
        )
        XCTAssertFalse(reencoded.contains("distanceProvenance"))
    }

    // MARK: - Byte-identical goldens

    /// Summaries captured from the analyzer **before** provenance existed, in
    /// the store's own canonical encoding. These fixtures are pure IEEE
    /// arithmetic (device-supplied distances, no altitude), so they are stable
    /// on macOS and Linux alike; coordinate-derived routes are deliberately
    /// excluded because haversine distances are not bit-identical across libm
    /// implementations. Any change here means an existing snapshot would be
    /// rewritten on reanalysis.
    func testRoutedSummariesAreByteIdenticalToPreProvenanceGoldens() throws {
        let goldenSupplied = """
        {
          "averageHeartRateBPM" : 159.5,
          "averagePaceSecondsPerKilometer" : 300,
          "averageSpeedMetersPerSecond" : 3.3333333333333335,
          "elapsedAverageSpeedMetersPerSecond" : 3.3333333333333335,
          "elapsedPaceSecondsPerKilometer" : 300,
          "elevationGainMeters" : 0,
          "elevationLossMeters" : 0,
          "maxHeartRateBPM" : 179,
          "movingAverageSpeedMetersPerSecond" : 3.3333333333333335,
          "movingPaceSecondsPerKilometer" : 300,
          "totalActiveSeconds" : 1170,
          "totalDistanceMeters" : 3900,
          "totalElapsedSeconds" : 1170,
          "totalMovingSeconds" : 1170,
          "totalPausedSeconds" : 0,
          "totalStoppedSeconds" : 0
        }
        """

        let goldenSuppliedPause = """
        {
          "averageHeartRateBPM" : 155,
          "averagePaceSecondsPerKilometer" : 300,
          "averageSpeedMetersPerSecond" : 3.3333333333333335,
          "elapsedAverageSpeedMetersPerSecond" : 2.146892655367232,
          "elapsedPaceSecondsPerKilometer" : 465.78947368421046,
          "elevationGainMeters" : 0,
          "elevationLossMeters" : 0,
          "maxHeartRateBPM" : 160,
          "movingAverageSpeedMetersPerSecond" : 3.3333333333333335,
          "movingPaceSecondsPerKilometer" : 300,
          "totalActiveSeconds" : 1140,
          "totalDistanceMeters" : 3800,
          "totalElapsedSeconds" : 1770,
          "totalMovingSeconds" : 1140,
          "totalPausedSeconds" : 630,
          "totalStoppedSeconds" : 0
        }
        """

        let goldenEmpty = """
        {
          "averagePaceSecondsPerKilometer" : 0,
          "averageSpeedMetersPerSecond" : 0,
          "elapsedAverageSpeedMetersPerSecond" : 0,
          "elapsedPaceSecondsPerKilometer" : 0,
          "elevationGainMeters" : 0,
          "elevationLossMeters" : 0,
          "movingAverageSpeedMetersPerSecond" : 0,
          "movingPaceSecondsPerKilometer" : 0,
          "totalActiveSeconds" : 0,
          "totalDistanceMeters" : 0,
          "totalElapsedSeconds" : 0,
          "totalMovingSeconds" : 0,
          "totalPausedSeconds" : 0,
          "totalStoppedSeconds" : 0
        }
        """

        let imported = try routedWorkout(points: suppliedDistanceRoute())
        XCTAssertEqual(try encodedSummaryBytes(imported), goldenSupplied)

        var reanalyzed = imported
        WorkoutAnalyzer().analyze(&reanalyzed)
        XCTAssertEqual(try encodedSummaryBytes(reanalyzed), goldenSupplied)

        let importedPause = try routedWorkout(points: suppliedDistanceRouteWithPause())
        XCTAssertEqual(try encodedSummaryBytes(importedPause), goldenSuppliedPause)

        var emptyWorkout = RunWorkout(
            routePoints: [],
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
        WorkoutAnalyzer().analyze(&emptyWorkout)
        XCTAssertEqual(try encodedSummaryBytes(emptyWorkout), goldenEmpty)
    }
}
