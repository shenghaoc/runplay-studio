import Foundation
import XCTest
@testable import RunPlayCore

/// `RunWorkout.recordedAltitudeSensor` and `RunWorkout.demElevationCorrection`
/// persist with the snapshot. Snapshots that never had them keep their exact
/// keys, older snapshots decode, and a value this build cannot read degrades
/// instead of failing the whole workout (#207).
final class DEMElevationCorrectionCodingTests: XCTestCase {
    private let tileSet = DEMTileSetIdentity(
        folderID: UUID(uuidString: "0F3C2A71-8E43-4C8B-9D6E-2B7A1C5D9E04")!,
        zoom: 12,
        tileSize: 256
    )

    // MARK: - Round trips

    func testBarometricSensorAndCorrectionRoundTrip() throws {
        var workout = makeWorkout()
        workout.recordedAltitudeSensor = .barometric
        workout.demElevationCorrection = makeCorrection(outcome: .applied)

        let decoded = try roundTrip(workout)

        XCTAssertEqual(decoded.recordedAltitudeSensor, .barometric)
        XCTAssertEqual(decoded.demElevationCorrection, workout.demElevationCorrection)
    }

    func testEveryOutcomeRoundTrips() throws {
        let outcomes: [DEMElevationCorrection.Outcome] = [
            .applied,
            .noCoverage,
            .tileBudgetExceeded(minimumRequiredTileCount: 513, tileBudget: 512),
            .optedOut,
        ]
        for outcome in outcomes {
            var workout = makeWorkout()
            workout.demElevationCorrection = makeCorrection(
                outcome: outcome,
                tileSet: outcome == .optedOut ? nil : tileSet
            )
            XCTAssertEqual(try roundTrip(workout).demElevationCorrection, workout.demElevationCorrection, "\(outcome)")
        }
    }

    // MARK: - No growth for workouts without the data

    func testUnknownSensorAndNoCorrectionWriteNoKeys() throws {
        let object = try jsonObject(Self.libraryStoreEncoder().encode(makeWorkout()))

        XCTAssertNil(object["recordedAltitudeSensor"], "the default sensor is not written")
        XCTAssertNil(object["demElevationCorrection"], "an uncorrected workout has no record key")
    }

    // MARK: - Older and newer snapshots

    func testLegacyFixtureDecodesWithUnknownSensorAndNoCorrection() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy-paused-workout-v0", withExtension: "json"))
        let workout = try Self.libraryStoreDecoder().decode(RunWorkout.self, from: Data(contentsOf: url))

        XCTAssertEqual(workout.recordedAltitudeSensor, .unknown)
        XCTAssertNil(workout.demElevationCorrection)
    }

    func testUnknownSensorValueDecodesAsUnknown() throws {
        let object = try snapshotObject { object in
            object["recordedAltitudeSensor"] = "laserAltimeter"
        }
        let workout = try decodeSnapshot(object)
        XCTAssertEqual(workout.recordedAltitudeSensor, .unknown)
    }

    func testUnreadableCorrectionRecordDropsTheRecordNotTheWorkout() throws {
        var corrected = makeWorkout()
        corrected.demElevationCorrection = makeCorrection(outcome: .applied)
        let encoded = try jsonObject(Self.libraryStoreEncoder().encode(corrected))

        let malformedRecords: [(String, Any)] = [
            ("an outcome a later build added", { () -> [String: Any] in
                var record = encoded["demElevationCorrection"] as! [String: Any]
                record["outcome"] = "hybridDatum"
                return record
            }()),
            ("a record of the wrong shape", "not a record"),
            ("a budget outcome missing its counts", { () -> [String: Any] in
                var record = encoded["demElevationCorrection"] as! [String: Any]
                record["outcome"] = "tileBudgetExceeded"
                return record
            }()),
        ]
        for (name, record) in malformedRecords {
            var object = encoded
            object["demElevationCorrection"] = record
            let workout = try decodeSnapshot(object)
            XCTAssertNil(workout.demElevationCorrection, name)
            XCTAssertEqual(workout.id, corrected.id, "\(name): the workout still loads")
            XCTAssertEqual(workout.routePoints.count, corrected.routePoints.count, name)
        }
    }

    func testCoverageCountsAddedByALaterBuildAreIgnoredAndMissingOnesDefaultToZero() throws {
        var corrected = makeWorkout()
        corrected.demElevationCorrection = makeCorrection(outcome: .applied)
        var object = try jsonObject(Self.libraryStoreEncoder().encode(corrected))
        var record = object["demElevationCorrection"] as! [String: Any]
        var coverage = record["coverage"] as! [String: Any]
        coverage["somethingNewCount"] = 7
        coverage.removeValue(forKey: "unreadableTileCount")
        record["coverage"] = coverage
        object["demElevationCorrection"] = record

        let decoded = try XCTUnwrap(decodeSnapshot(object).demElevationCorrection)
        XCTAssertEqual(decoded.coverage.sampledPointCount, 90)
        XCTAssertEqual(decoded.coverage.unreadableTileCount, 0)
    }

    // MARK: - Coverage and staleness

    func testCoverageFractionCountsOnlyCoverablePoints() {
        var coverage = DEMElevationCoverage()
        XCTAssertNil(coverage.tileCoverageFraction, "no coverable point")
        coverage.pointCount = 100
        coverage.sampledPointCount = 45
        coverage.missingTilePointCount = 4
        coverage.implausibleHeightPointCount = 1
        coverage.invalidCoordinatePointCount = 30
        coverage.outsideProjectionPointCount = 20
        XCTAssertEqual(coverage.coverablePointCount, 50)
        XCTAssertEqual(try XCTUnwrap(coverage.tileCoverageFraction), 0.9, accuracy: 1e-12)

        coverage.plannedTileCount = 10
        coverage.loadedTileCount = 7
        coverage.unreadableTileCount = 1
        XCTAssertEqual(coverage.missingTileCount, 2)
    }

    func testShouldRecorrectMatrix() {
        let otherZoom = DEMTileSetIdentity(folderID: tileSet.folderID, zoom: 14, tileSize: 256)
        let otherFolder = DEMTileSetIdentity(folderID: UUID(), zoom: 12, tileSize: 256)

        let covered = makeCorrection(outcome: .applied, missingPoints: 0, unreadableTiles: 0)
        XCTAssertFalse(covered.shouldRecorrect(with: tileSet), "fully covered with the same tiles")
        XCTAssertTrue(covered.shouldRecorrect(with: otherZoom), "another zoom")
        XCTAssertTrue(covered.shouldRecorrect(with: otherFolder), "another folder")

        XCTAssertTrue(
            makeCorrection(outcome: .applied, missingPoints: 3, unreadableTiles: 0).shouldRecorrect(with: tileSet),
            "missing tiles may have been added"
        )
        XCTAssertTrue(
            makeCorrection(outcome: .noCoverage, missingPoints: 0, unreadableTiles: 1).shouldRecorrect(with: tileSet),
            "an unreadable tile may have been repaired"
        )

        let overBudget = makeCorrection(
            outcome: .tileBudgetExceeded(minimumRequiredTileCount: 513, tileBudget: 512),
            missingPoints: 0,
            unreadableTiles: 0
        )
        XCTAssertFalse(overBudget.shouldRecorrect(with: tileSet), "the same tiles still exceed the budget")
        XCTAssertTrue(overBudget.shouldRecorrect(with: otherZoom), "a coarser zoom may fit")

        let optedOut = makeCorrection(outcome: .optedOut, tileSet: nil)
        XCTAssertFalse(optedOut.shouldRecorrect(with: tileSet), "the user chose recorded elevation")
        XCTAssertFalse(optedOut.shouldRecorrect(with: otherFolder))
    }

    func testListedTilesAreSortedAndCapped() {
        let keys = (0..<40).map { DEMTileKey(x: 40 - $0, y: $0 % 3) }
        let correction = DEMElevationCorrection(
            outcome: .applied,
            tileSet: tileSet,
            correctedAt: Date(timeIntervalSinceReferenceDate: 0),
            missingTiles: keys,
            unreadableTiles: keys
        )
        XCTAssertEqual(correction.missingTiles.count, DEMElevationCorrection.listedTileLimit)
        XCTAssertEqual(correction.missingTiles, Array(keys.sorted().prefix(DEMElevationCorrection.listedTileLimit)))
        XCTAssertEqual(correction.unreadableTiles, correction.missingTiles)
    }

    // MARK: - Helpers

    private func makeWorkout() -> RunWorkout {
        var points: [RoutePoint] = []
        for index in 0..<3 {
            let step: Double = Double(index)
            let seconds: TimeInterval = 800_000_000 + step
            let latitude: Double = 46 + step * 0.0001
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                latitude: latitude,
                longitude: 7.5,
                altitudeMeters: 1_200,
                elapsedSeconds: step
            ))
        }
        return RunWorkout(metadata: WorkoutMetadata(name: "Coding"), source: .fit, routePoints: points)
    }

    private func makeCorrection(
        outcome: DEMElevationCorrection.Outcome,
        tileSet: DEMTileSetIdentity? = nil,
        missingPoints: Int = 6,
        unreadableTiles: Int = 1
    ) -> DEMElevationCorrection {
        var coverage = DEMElevationCoverage()
        coverage.pointCount = 100
        coverage.sampledPointCount = 90
        coverage.missingTilePointCount = missingPoints
        coverage.implausibleHeightPointCount = 100 - 90 - missingPoints
        coverage.replacedRecordedPointCount = 80
        coverage.filledMissingPointCount = 10
        coverage.plannedTileCount = 9
        coverage.loadedTileCount = 9 - unreadableTiles - 1
        coverage.unreadableTileCount = unreadableTiles
        return DEMElevationCorrection(
            outcome: outcome,
            tileSet: outcome == .optedOut ? tileSet : (tileSet ?? self.tileSet),
            correctedAt: Date(timeIntervalSinceReferenceDate: 812_000_000),
            coverage: coverage,
            missingTiles: [DEMTileKey(x: 2_131, y: 1_451)],
            unreadableTiles: unreadableTiles > 0 ? [DEMTileKey(x: 2_130, y: 1_451)] : []
        )
    }

    private func roundTrip(_ workout: RunWorkout) throws -> RunWorkout {
        try Self.libraryStoreDecoder().decode(RunWorkout.self, from: Self.libraryStoreEncoder().encode(workout))
    }

    private func snapshotObject(_ mutate: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var object = try jsonObject(Self.libraryStoreEncoder().encode(makeWorkout()))
        mutate(&object)
        return object
    }

    private func decodeSnapshot(_ object: [String: Any]) throws -> RunWorkout {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try Self.libraryStoreDecoder().decode(RunWorkout.self, from: data)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func libraryStoreEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func libraryStoreDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
