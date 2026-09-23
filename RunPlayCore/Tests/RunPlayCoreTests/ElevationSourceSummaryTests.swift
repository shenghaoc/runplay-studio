import Foundation
import XCTest
@testable import RunPlayCore

/// The words the elevation chart, its source note, the import summary,
/// VoiceOver, and the JSON export use for a workout's elevation source.
final class ElevationSourceSummaryTests: XCTestCase {
    private let tileSet = DEMTileSetIdentity(folderID: UUID(), zoom: 13, tileSize: 256)

    func testLabelsNameEverySourceAndSensor() {
        let cases: [(ElevationSourceSummary.Source, RecordedAltitudeSensor, String)] = [
            (.none, .unknown, "No elevation data"),
            (.recorded, .barometric, "Barometric altimeter"),
            (.recorded, .unknown, "Recorded altitude (sensor unknown)"),
            (.dem, .unknown, "DEM tiles"),
            (.dem, .barometric, "DEM tiles"),
            (.demAndRecorded, .barometric, "Barometric altimeter and DEM tiles"),
            (.demAndRecorded, .unknown, "DEM tiles and recorded altitude"),
        ]
        for (source, sensor, label) in cases {
            let summary = ElevationSourceSummary(source: source, recordedAltitudeSensor: sensor, correction: nil)
            XCTAssertEqual(summary.label, label)
            XCTAssertTrue(summary.notes.isEmpty, "never corrected: nothing to add")
        }
    }

    func testSourceFollowsTheProfileCounts() throws {
        let workout = RunWorkout(routePoints: [])
        let cases: [(Int, Int, ElevationSourceSummary.Source)] = [
            (0, 0, .none), (0, 5, .recorded), (5, 0, .dem), (3, 2, .demAndRecorded),
        ]
        for (dem, recorded, source) in cases {
            let counts = ElevationSourceCounts(demPointCount: dem, recordedPointCount: recorded)
            XCTAssertEqual(ElevationSourceSummary(workout: workout, sourceCounts: counts).source, source)
        }
    }

    /// Decision 5: a barometric GPX or TCX overridden by DEM must be visible.
    func testReplacingAltitudeFromAnUnstatedSensorSaysSoPlainly() {
        var coverage = DEMElevationCoverage()
        coverage.pointCount = 1_000
        coverage.sampledPointCount = 1_000
        coverage.replacedRecordedPointCount = 1_000
        let summary = summary(.dem, .unknown, outcome: .applied, coverage: coverage)

        XCTAssertEqual(summary.notes, [
            "DEM tiles replaced the recorded altitude at 100% of points. This file does not say which "
                + "sensor recorded that altitude; if it was a barometric altimeter, choose Use Recorded "
                + "Elevation to keep it."
        ])
        XCTAssertEqual(
            summary.spokenSummary,
            "Elevation source: DEM tiles. " + summary.notes[0]
        )
    }

    func testBarometricGapFillAndPartialCoverageNotes() {
        var coverage = DEMElevationCoverage()
        coverage.pointCount = 1_000
        coverage.sampledPointCount = 996
        coverage.missingTilePointCount = 4
        coverage.keptBarometricPointCount = 995
        coverage.filledMissingPointCount = 1
        coverage.plannedTileCount = 5
        coverage.loadedTileCount = 3
        coverage.unreadableTileCount = 1

        XCTAssertEqual(summary(.demAndRecorded, .barometric, outcome: .applied, coverage: coverage).notes, [
            "The recorded barometric altitude is kept wherever it exists.",
            "DEM tiles filled 1 point that had no recorded altitude.",
            "DEM tiles covered 99% of the route; 1 tile is missing from the folder.",
            "1 tile could not be read.",
        ])
    }

    func testOutcomesWithoutDEMExplainThemselves() {
        XCTAssertEqual(summary(.recorded, .unknown, outcome: .noCoverage).notes, [
            "Not corrected: no DEM tile in the folder covers this route."
        ])
        XCTAssertEqual(summary(.recorded, .unknown, outcome: .optedOut).notes, [
            "DEM correction is off for this workout because Use Recorded Elevation is chosen."
        ])
        XCTAssertEqual(
            summary(.recorded, .unknown, outcome: .tileBudgetExceeded(minimumRequiredTileCount: 300, tileBudget: 256)).notes,
            ["Not corrected: this route needs at least 300 DEM tiles, more than the 256 one correction may read. "
                + "Tiles at a lower zoom cover more ground each."]
        )
    }

    func testPercentagesNeverOverstateCoverage() {
        XCTAssertEqual(ElevationSourceSummary.percent(1), "100%")
        XCTAssertEqual(ElevationSourceSummary.percent(0.999), "99%")
        XCTAssertEqual(ElevationSourceSummary.percent(0.004), "less than 1%")
        XCTAssertEqual(ElevationSourceSummary.percent(0), "0%")
        XCTAssertEqual(ElevationSourceSummary.percent(.nan), "0%")
        XCTAssertEqual(ElevationSourceSummary.percent(3, of: 0), "0%")
    }

    func testImportSummaries() {
        var coverage = DEMElevationCoverage()
        coverage.pointCount = 100
        coverage.sampledPointCount = 92
        coverage.missingTilePointCount = 8
        coverage.replacedRecordedPointCount = 92
        let replaced = record(.applied, coverage: coverage)
        XCTAssertEqual(
            replaced.importSummary(recordedAltitudeSensor: .unknown),
            "Elevation corrected from DEM tiles covering 92% of the route, replacing recorded altitude from an unstated sensor."
        )

        coverage.replacedRecordedPointCount = 0
        coverage.filledMissingPointCount = 92
        XCTAssertEqual(
            record(.applied, coverage: coverage).importSummary(recordedAltitudeSensor: .unknown),
            "Elevation corrected from DEM tiles covering 92% of the route."
        )

        coverage.filledMissingPointCount = 2
        coverage.keptBarometricPointCount = 90
        XCTAssertEqual(
            record(.applied, coverage: coverage).importSummary(recordedAltitudeSensor: .barometric),
            "Barometric elevation kept; DEM tiles filled 2 points without it."
        )
        XCTAssertEqual(
            record(.noCoverage).importSummary(recordedAltitudeSensor: .unknown),
            "Elevation not corrected: no DEM tile covers this route."
        )
    }

    func testBatchImportSummaryTotalsOutcomes() {
        XCTAssertNil(DEMElevationCorrection.batchImportSummary([]))
        XCTAssertEqual(
            DEMElevationCorrection.batchImportSummary([
                record(.applied), record(.applied), record(.noCoverage),
                record(.tileBudgetExceeded(minimumRequiredTileCount: 9, tileBudget: 4)), nil,
            ]),
            "DEM elevation for 5 runs: 2 corrected, 1 outside the tiles, "
                + "1 needing more tiles than one correction may read, 1 not corrected after an error."
        )
    }

    func testExportNamesTheSourceWithoutTheFolder() throws {
        var workout = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try DEMElevationCorrector().correct(&workout, using: SyntheticDEMTiles(height: 250))

        let data = try JSONEncoder().encode(WorkoutExportSummary(workout: workout, segments: []))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["exportVersion"] as? String, "4.2")
        let source = try XCTUnwrap(object["elevationSource"] as? [String: Any])
        XCTAssertEqual(source["source"] as? String, "dem")
        XCTAssertEqual(source["recordedAltitudeSensor"] as? String, "unknown")
        XCTAssertEqual(source["demPointCount"] as? Int, workout.routePoints.count)
        let correction = try XCTUnwrap(source["demCorrection"] as? [String: Any])
        XCTAssertEqual(correction["outcome"] as? String, "applied")
        XCTAssertEqual(correction["zoom"] as? Int, SyntheticDEMTiles.zoom)
        XCTAssertEqual(correction["tileCoverageFraction"] as? Double, 1)
        XCTAssertNil(correction["folderID"], "the export never identifies the tile folder")
    }

    // MARK: - Helpers

    private func record(
        _ outcome: DEMElevationCorrection.Outcome,
        coverage: DEMElevationCoverage = DEMElevationCoverage()
    ) -> DEMElevationCorrection {
        DEMElevationCorrection(
            outcome: outcome,
            tileSet: outcome == .optedOut ? nil : tileSet,
            correctedAt: Date(timeIntervalSinceReferenceDate: 0),
            coverage: coverage
        )
    }

    private func summary(
        _ source: ElevationSourceSummary.Source,
        _ sensor: RecordedAltitudeSensor,
        outcome: DEMElevationCorrection.Outcome,
        coverage: DEMElevationCoverage = DEMElevationCoverage()
    ) -> ElevationSourceSummary {
        ElevationSourceSummary(source: source, recordedAltitudeSensor: sensor, correction: record(outcome, coverage: coverage))
    }
}
