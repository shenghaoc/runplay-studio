import Foundation
import XCTest
@testable import RunPlayCore

/// `DEMElevationCorrector` over a synthetic 2×2 tile set crossed by a route:
/// precedence, per-point fallback for missing, unreadable and wrongly sized
/// tiles, the tile budget, the opt-out, and the analysis it refreshes.
final class DEMElevationCorrectorTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 812_000_000)

    func testUnknownSensorAltitudeIsReplacedAcrossEveryTileBoundary() throws {
        let source = SyntheticDEMTiles(height: 250)
        var workout = try importedWorkout(recorded: { _ in 100 })

        let record = try DEMElevationCorrector().correct(&workout, using: source, at: date)

        XCTAssertEqual(source.requests, [SyntheticDEMTiles.block], "one request for exactly the four tiles")
        XCTAssertEqual(record.outcome, .applied)
        XCTAssertEqual(record.tileSet, source.tileSet)
        XCTAssertEqual(record.correctedAt, date)
        let count = workout.routePoints.count
        XCTAssertEqual(record.coverage.pointCount, count)
        XCTAssertEqual(record.coverage.sampledPointCount, count)
        XCTAssertEqual(record.coverage.replacedRecordedPointCount, count)
        XCTAssertEqual(record.coverage.plannedTileCount, 4)
        XCTAssertEqual(record.coverage.loadedTileCount, 4)
        XCTAssertEqual(record.coverage.tileCoverageFraction, 1)
        XCTAssertTrue(record.missingTiles.isEmpty)
        XCTAssertEqual(workout.demElevationCorrection, record)
        XCTAssertTrue(workout.routePoints.allSatisfy { $0.demAltitudeMeters == 250 && $0.altitudeMeters == 100 })
        XCTAssertFalse(record.shouldRecorrect(with: source.tileSet))
    }

    /// GPS noise on a flat route is phantom climb; flat terrain tiles remove it
    /// from the summary, the splits, and the climb highlights.
    func testFlatTilesRemovePhantomClimbFromEveryElevationResult() throws {
        var random = DemSplitMix64(seed: 965)
        var noise = 0.0
        let noisy = (0..<SyntheticDEMTiles.routePointCount).map { _ -> Double in
            noise = max(-12, min(12, noise + random.nextDouble(in: -2...2)))
            return 300 + noise
        }
        var workout = try importedWorkout(recorded: { noisy[$0] })
        let before = workout.summary.elevationGainMeters
        XCTAssertGreaterThan(before, 20, "the noise must be climb to remove")
        XCTAssertTrue(workout.splits.contains { ($0.elevationGainMeters ?? 0) > 0 })

        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 300), at: date)

        XCTAssertEqual(workout.summary.elevationGainMeters, 0)
        XCTAssertEqual(workout.summary.elevationLossMeters, 0)
        XCTAssertTrue(workout.splits.allSatisfy { ($0.elevationGainMeters ?? 0) == 0 })
        XCTAssertFalse(workout.segments.contains { $0.type == .biggestClimb || $0.type == .biggestDescent })
        XCTAssertEqual(
            workout.summary.rawElevationGainMeters,
            WorkoutAnalyzer.rawElevationTotals(in: workout.routePoints).gain,
            "raw totals stay over recorded altitude"
        )
    }

    /// A route DEM makes perfectly flat has 0 m corrected ascent and descent;
    /// Trends, records, and the library must not fall back to the raw
    /// recorded sum, which is the GPS noise the correction removed.
    func testFlatDEMRunsKeepZeroAscentEverywhereAscentIsTotalled() throws {
        var random = DemSplitMix64(seed: 17)
        var noise = 0.0
        let noisy = (0..<SyntheticDEMTiles.routePointCount).map { _ -> Double in
            noise = max(-12, min(12, noise + random.nextDouble(in: -2...2)))
            return 300 + noise
        }
        var workout = try importedWorkout(recorded: { noisy[$0] })
        workout.metadata.startDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 300), at: date)
        XCTAssertEqual(workout.summary.elevationGainMeters, 0)
        XCTAssertGreaterThan(try XCTUnwrap(workout.summary.rawElevationGainMeters), 50, "the noise the raw sum keeps")

        XCTAssertTrue(workout.hasCorrectedElevationTotals)
        XCTAssertEqual(WorkoutTrendsSummaryRow.make(from: workout)?.ascentMeters, 0)
        XCTAssertNil(
            PersonalRecordsAggregator.aggregate(workouts: [workout]).row(for: .biggestAscent)?.best,
            "0 m is not a climb record"
        )
        XCTAssertTrue(WorkoutLibraryEntry.make(from: workout, manifestIndex: 0, isFavorite: false).hasCorrectedElevation)

        try DEMElevationCorrector().useRecordedElevation(&workout, at: date)
        XCTAssertEqual(
            WorkoutTrendsSummaryRow.make(from: workout)?.ascentMeters,
            workout.summary.elevationGainMeters,
            "recorded elevation again: its corrected profile is back"
        )
    }

    func testBarometricAltitudeIsKeptAndOnlyItsGapsAreFilledWithoutASourceStep() throws {
        let gap = 200..<240
        var workout = try importedWorkout(sensor: .barometric, recorded: { gap.contains($0) ? nil : 100 })

        let record = try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 180), at: date)

        XCTAssertEqual(record.outcome, .applied)
        XCTAssertEqual(record.coverage.filledMissingPointCount, gap.count)
        XCTAssertEqual(record.coverage.keptBarometricPointCount, workout.routePoints.count - gap.count)
        XCTAssertEqual(record.coverage.replacedRecordedPointCount, 0)
        for (index, point) in workout.routePoints.enumerated() {
            XCTAssertEqual(point.demAltitudeMeters, gap.contains(index) ? 180 : nil, "point \(index)")
        }
        XCTAssertEqual(workout.summary.elevationGainMeters, 0, "the 80 m offset between sources is not climb")
        XCTAssertEqual(workout.summary.elevationLossMeters, 0)
    }

    func testMissingTileKeepsRecordedAltitudeThereWithoutFakeClimb() throws {
        let missing = DEMTileKey(x: SyntheticDEMTiles.origin.x + 1, y: SyntheticDEMTiles.origin.y + 1)
        let source = SyntheticDEMTiles(height: 70, tiles: SyntheticDEMTiles.block.filter { $0 != missing })
        var workout = try importedWorkout(recorded: { _ in 100 })

        let record = try DEMElevationCorrector().correct(&workout, using: source, at: date)

        XCTAssertEqual(record.outcome, .applied)
        XCTAssertEqual(record.missingTiles, [missing])
        XCTAssertEqual(record.coverage.missingTileCount, 1)
        XCTAssertGreaterThan(record.coverage.missingTilePointCount, 0)
        XCTAssertEqual(
            record.coverage.sampledPointCount + record.coverage.missingTilePointCount,
            workout.routePoints.count
        )
        XCTAssertEqual(record.coverage.appliedPointCount, record.coverage.sampledPointCount)
        XCTAssertEqual(workout.routePoints.last?.demAltitudeMeters, nil, "the route ends in the missing tile")
        XCTAssertEqual(workout.summary.elevationGainMeters, 0, "the 30 m step onto recorded altitude is not climb")
        XCTAssertFalse(workout.segments.contains { $0.type == .biggestClimb })
        XCTAssertTrue(record.shouldRecorrect(with: source.tileSet), "the missing tile may be added later")
    }

    func testUnreadableAndWronglySizedTilesFallBackLikeMissingOnes() throws {
        let block = SyntheticDEMTiles.block
        let source = SyntheticDEMTiles(height: 250)
        source.unreadable = [block[3]]
        source.wronglySized = [block[1]]
        var workout = try importedWorkout(recorded: { _ in 100 })

        let record = try DEMElevationCorrector().correct(&workout, using: source, at: date)

        XCTAssertEqual(record.unreadableTiles, [block[1], block[3]])
        XCTAssertEqual(record.coverage.unreadableTileCount, 2)
        XCTAssertEqual(record.coverage.loadedTileCount, 2)
        XCTAssertTrue(record.missingTiles.isEmpty)
        XCTAssertGreaterThan(record.coverage.missingTilePointCount, 0, "points in unreadable tiles lack a tile")
        XCTAssertTrue(workout.routePoints.contains { $0.demAltitudeMeters == nil })
        XCTAssertTrue(record.shouldRecorrect(with: source.tileSet))
    }

    func testRouteOverTheTileBudgetKeepsRecordedAltitudeAndClearsAnEarlierCorrection() throws {
        var workout = try importedWorkout(recorded: { $0 < 100 ? 100 : 130 })
        let recordedGain = workout.summary.elevationGainMeters
        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250), at: date)
        XCTAssertEqual(workout.summary.elevationGainMeters, 0)

        let tight = DEMElevationCorrector(policy: .init(maximumDecodedTileBytes: 32 * 32 * 4))
        let source = SyntheticDEMTiles(height: 250)
        let record = try tight.correct(&workout, using: source, at: date)

        XCTAssertEqual(record.outcome, .tileBudgetExceeded(minimumRequiredTileCount: 2, tileBudget: 1))
        XCTAssertTrue(source.requests.isEmpty, "no tile is decoded for a route over budget")
        XCTAssertTrue(workout.routePoints.allSatisfy { $0.demAltitudeMeters == nil })
        XCTAssertEqual(workout.summary.elevationGainMeters, recordedGain, accuracy: 1e-9)
        XCTAssertFalse(record.shouldRecorrect(with: source.tileSet))
    }

    func testUsingRecordedElevationRestoresTheRecordedAnalysis() throws {
        var workout = try importedWorkout(recorded: { $0 < 100 ? 100 : 130 })
        let recorded = workout
        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250), at: date)

        try DEMElevationCorrector().useRecordedElevation(&workout, at: date)

        XCTAssertEqual(workout.demElevationCorrection?.outcome, .optedOut)
        XCTAssertNil(workout.demElevationCorrection?.tileSet)
        XCTAssertEqual(workout.routePoints, recorded.routePoints)
        XCTAssertEqual(workout.summary, recorded.summary)
        // Reanalysis mints new split and segment identifiers; compare values.
        XCTAssertEqual(workout.splits.map(\.elevationGainMeters), recorded.splits.map(\.elevationGainMeters))
        XCTAssertEqual(workout.splits.map(\.paceSecondsPerKilometer), recorded.splits.map(\.paceSecondsPerKilometer))
        XCTAssertEqual(workout.segments.map(\.type), recorded.segments.map(\.type))
        XCTAssertEqual(workout.segments.map(\.elevationDeltaMeters), recorded.segments.map(\.elevationDeltaMeters))
        XCTAssertEqual(workout.analysisWarnings, recorded.analysisWarnings)
        XCTAssertEqual(workout.qualityDiagnostics, recorded.qualityDiagnostics)
    }

    func testTilesGiveElevationToARouteWithoutAltitudeAndClearItsWarning() throws {
        var workout = try importedWorkout(recorded: { _ in nil })
        XCTAssertTrue(workout.analysisWarnings.contains(.insufficientReliableElevation))

        let record = try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250), at: date)

        XCTAssertEqual(record.coverage.filledMissingPointCount, workout.routePoints.count)
        XCTAssertFalse(workout.analysisWarnings.contains(.insufficientReliableElevation))
        XCTAssertTrue(WorkoutAnalysisContext(workout: workout).elevationProfile.hasMeaningfulElevation)
    }

    func testAltitudeOutlierWarningFollowsTheSourceWhileSourceDropsAreKept() throws {
        let spike = 150
        var workout = try importedWorkout(recorded: { $0 == spike ? 400 : 100 })
        XCTAssertEqual(workout.qualityDiagnostics.discardedAltitudeSampleCount, 1)
        XCTAssertTrue(workout.analysisWarnings.contains(.altitudeOutliersIgnored))

        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250), at: date)
        XCTAssertEqual(workout.qualityDiagnostics.discardedAltitudeSampleCount, 0, "DEM replaced the spike")
        XCTAssertFalse(workout.analysisWarnings.contains(.altitudeOutliersIgnored))

        // A non-finite source altitude dropped at import stays counted.
        var withDrop = try importedWorkout(recorded: { $0 == spike ? .nan : 100 })
        XCTAssertEqual(withDrop.qualityDiagnostics.discardedAltitudeSampleCount, 1)
        try DEMElevationCorrector().correct(&withDrop, using: SyntheticDEMTiles(height: 250), at: date)
        XCTAssertEqual(withDrop.qualityDiagnostics.discardedAltitudeSampleCount, 1)
        XCTAssertTrue(withDrop.analysisWarnings.contains(.altitudeOutliersIgnored))
    }

    func testCorrectionKeepsTrainingLoadAndEverythingButDEMOnTheRoutePoints() throws {
        var workout = try importedWorkout(recorded: { _ in 100 }, heartRate: 150)
        let before = workout
        XCTAssertNotNil(before.trainingLoad)

        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250), at: date)

        XCTAssertEqual(workout.trainingLoad, before.trainingLoad)
        var stripped = workout.routePoints
        for index in stripped.indices { stripped[index].demAltitudeMeters = nil }
        XCTAssertEqual(stripped, before.routePoints)
    }

    func testCorrectingAgainWithTheSameTilesChangesOnlyTheDate() throws {
        var workout = try importedWorkout(recorded: { _ in 100 })
        let source = SyntheticDEMTiles(height: 250)
        try DEMElevationCorrector().correct(&workout, using: source, at: date)
        let first = workout

        try DEMElevationCorrector().correct(&workout, using: source, at: date.addingTimeInterval(60))

        XCTAssertEqual(workout.routePoints, first.routePoints)
        XCTAssertEqual(workout.summary, first.summary)
        XCTAssertEqual(workout.demElevationCorrection?.coverage, first.demElevationCorrection?.coverage)
        XCTAssertEqual(workout.demElevationCorrection?.correctedAt, date.addingTimeInterval(60))
    }

    func testCancellationLeavesTheWorkoutUnchanged() throws {
        let original = try importedWorkout(recorded: { _ in 100 })
        for limit in [1, 2, 3, 5, 8, 13] {
            var workout = original
            let calls = CallCounter()
            XCTAssertThrowsError(
                try DEMElevationCorrector(policy: .init(cancellationCheckStride: 64)).correct(
                    &workout,
                    using: SyntheticDEMTiles(height: 250),
                    at: date,
                    isCancelled: { calls.increment() >= limit }
                ),
                "cancelled at check \(limit)"
            ) { XCTAssertTrue($0 is CancellationError, "\($0)") }
            XCTAssertEqual(workout.routePoints, original.routePoints, "cancelled at check \(limit)")
            XCTAssertNil(workout.demElevationCorrection)
        }
    }

    func testUnsupportedTileSetsAreRejected() throws {
        var workout = try importedWorkout(recorded: { _ in 100 })
        for (zoom, tileSize) in [(25, 256), (-1, 256), (12, 1), (12, 4_097)] {
            let source = SyntheticDEMTiles(height: 250, zoom: zoom, tileSize: tileSize)
            XCTAssertThrowsError(try DEMElevationCorrector().correct(&workout, using: source)) {
                XCTAssertEqual($0 as? DEMElevationCorrectionError, .unsupportedTileSet)
            }
        }
        XCTAssertNil(workout.demElevationCorrection)
    }

    // MARK: - Helpers

    private func importedWorkout(
        sensor: RecordedAltitudeSensor = .unknown,
        recorded: (Int) -> Double?,
        heartRate: Double? = nil
    ) throws -> RunWorkout {
        let workout = try SyntheticDEMTiles.importedWorkout(sensor: sensor, recorded: recorded, heartRate: heartRate)
        XCTAssertEqual(workout.routePoints.count, SyntheticDEMTiles.routePointCount, "route quality kept every point")
        return workout
    }
}

/// In-memory tiles for corrector tests: the block (2130, 1450)–(2131, 1451) at
/// zoom 12 with 32-pixel tiles, every height the same.
final class SyntheticDEMTiles: DEMTileSource, @unchecked Sendable {
    static let zoom = 12
    static let tileSize = 32
    static let origin = DEMTileKey(x: 2_130, y: 1_450)
    static let block = [
        origin,
        DEMTileKey(x: origin.x + 1, y: origin.y),
        DEMTileKey(x: origin.x, y: origin.y + 1),
        DEMTileKey(x: origin.x + 1, y: origin.y + 1),
    ]
    /// About 30 m between points over the roughly 14 km diagonal.
    static let routePointCount = 480

    let tileSet: DEMTileSetIdentity
    private let height: Float
    private let tiles: Set<DEMTileKey>
    var unreadable: Set<DEMTileKey> = []
    var wronglySized: Set<DEMTileKey> = []
    private(set) var requests: [[DEMTileKey]] = []

    static let folderID = UUID(uuidString: "6A1D1C0E-8E43-4C8B-9D6E-2B7A1C5D9E04")!

    init(
        height: Float,
        tiles: [DEMTileKey] = block,
        folderID: UUID = folderID,
        zoom: Int = zoom,
        tileSize: Int = tileSize
    ) {
        self.height = height
        self.tiles = Set(tiles)
        self.tileSet = DEMTileSetIdentity(folderID: folderID, zoom: zoom, tileSize: tileSize)
    }

    func loadTiles(_ keys: [DEMTileKey], isCancelled: @Sendable () -> Bool) throws -> DEMTileLoadResult {
        requests.append(keys)
        var result = DEMTileLoadResult()
        for key in keys where tiles.contains(key) {
            if unreadable.contains(key) {
                result.unreadableTiles.append(key)
            } else {
                let count = tileSet.tileSize * tileSet.tileSize - (wronglySized.contains(key) ? 1 : 0)
                result.tiles.append(DEMDecodedTile(key: key, heightsMeters: Array(repeating: height, count: count)))
            }
        }
        return result
    }

    /// A route across the block, from inside its north-west tile to inside its
    /// south-east tile through the shared corner region, imported through route
    /// quality and analysis like a file.
    static func importedWorkout(
        sensor: RecordedAltitudeSensor = .unknown,
        recorded: (Int) -> Double?,
        heartRate: Double? = nil
    ) throws -> RunWorkout {
        let points = (0..<routePointCount).map { index -> RoutePoint in
            let t = Double(index) / Double(routePointCount - 1)
            let position = coordinate(tileX: 0.3 + 1.4 * t, tileY: 0.25 + 1.5 * t)
            return RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index) * 8),
                latitude: position.latitude,
                longitude: position.longitude,
                altitudeMeters: recorded(index),
                heartRateBPM: heartRate
            )
        }
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "DEM corrector"),
            source: .fit,
            routePoints: points
        )
        workout.recordedAltitudeSensor = sensor
        try WorkoutAnalyzer().normalizeAndAnalyze(&workout, distancePolicy: .computeFromCoordinates)
        return workout
    }

    /// The coordinate at a position in tile units from the block's north-west
    /// corner.
    static func coordinate(tileX: Double, tileY: Double) -> (latitude: Double, longitude: Double) {
        let tiles = Double(1 << zoom)
        let x = (Double(origin.x) + tileX) / tiles
        let y = (Double(origin.y) + tileY) / tiles
        return (atan(sinh(Double.pi * (1 - 2 * y))) * 180 / .pi, x * 360 - 180)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
