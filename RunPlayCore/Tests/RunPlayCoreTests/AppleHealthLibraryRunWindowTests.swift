import XCTest
@testable import RunPlayCore

/// The Core pieces the Apple Health import layer stands on: the library-window
/// derivation it compares against, and the import-provenance value it writes.
final class AppleHealthLibraryRunWindowTests: XCTestCase {

    private func workout(
        start: Date?,
        end: Date? = nil,
        elapsedSeconds: Double = 0
    ) -> RunWorkout {
        var summary = RunSummary()
        summary.totalElapsedSeconds = elapsedSeconds
        return RunWorkout(
            metadata: WorkoutMetadata(startDate: start, endDate: end),
            summary: summary,
            analysisVersion: RunWorkout.currentAnalysisVersion
        )
    }

    private func instant(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: - Window from a stored run

    func testWindowRoundTripsWholeSecondsStartAndEnd() throws {
        let run = workout(start: instant(1_756_650_000), end: instant(1_756_653_600))
        let window = try XCTUnwrap(AppleHealthLibraryRunWindow(workout: run))
        XCTAssertEqual(window.startSeconds, 1_756_650_000)
        XCTAssertEqual(window.endSeconds, 1_756_653_600)
    }

    func testWindowFallsBackToElapsedSecondsWhenEndIsMissing() throws {
        let run = workout(start: instant(1_756_650_000), end: nil, elapsedSeconds: 1_800)
        let window = try XCTUnwrap(AppleHealthLibraryRunWindow(workout: run))
        XCTAssertEqual(window.startSeconds, 1_756_650_000)
        XCTAssertEqual(window.endSeconds, 1_756_651_800)
    }

    func testWindowIsNilWithoutAStart() {
        XCTAssertNil(AppleHealthLibraryRunWindow(workout: workout(start: nil, end: instant(1_756_653_600))))
    }

    /// A run whose end precedes its start cannot describe a window, and a
    /// window that ran backwards would flag unrelated runs as overlapping.
    func testWindowIsNilWhenTheEndPrecedesTheStart() {
        let run = workout(start: instant(1_756_653_600), end: instant(1_756_650_000))
        XCTAssertNil(AppleHealthLibraryRunWindow(workout: run))
    }

    func testWindowIsNilWhenElapsedTimeIsUnusable() {
        XCTAssertNil(AppleHealthLibraryRunWindow(
            workout: workout(start: instant(1_756_650_000), end: nil, elapsedSeconds: .nan)
        ))
        XCTAssertNil(AppleHealthLibraryRunWindow(
            workout: workout(start: instant(1_756_650_000), end: nil, elapsedSeconds: -1)
        ))
    }

    // MARK: - Batch derivation

    func testWindowsKeepInputOrderAndDropRunsThatCannotStateOne() {
        let runs = [
            workout(start: instant(1_700_000_000), end: instant(1_700_000_600)),
            workout(start: nil, end: instant(1_700_000_600)),
            workout(start: instant(1_700_001_000), end: instant(1_700_001_600)),
        ]

        let windows = AppleHealthLibraryRunWindow.windows(for: runs)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.startSeconds), [1_700_000_000, 1_700_001_000])
    }

    // MARK: - Import provenance

    func testAppleHealthImportProviderRoundTripsThroughCodable() throws {
        let provenance = WorkoutImportProvenance(
            provider: .appleHealthExport,
            providerActivityID: "1756650000-1756653600-HKWorkoutActivityTypeRunning-0",
            contentSHA256: "abc123",
            originalFilename: "route_1.gpx"
        )

        let data = try JSONEncoder().encode(provenance)
        let decoded = try JSONDecoder().decode(WorkoutImportProvenance.self, from: data)

        XCTAssertEqual(decoded, provenance)
        // The persisted raw value is stable: snapshots written today must decode
        // as themselves after any future case is added to the enum.
        XCTAssertEqual(WorkoutImportProvider.appleHealthExport.rawValue, "appleHealthExport")
    }

    /// An existing snapshot's raw value must keep decoding, because adding this
    /// case must not invalidate libraries written before it existed.
    func testPreExistingProviderRawValuesStillDecode() throws {
        for raw in ["singleFile", "stravaBulkExport", "fitMultiSessionFile", "unknown"] {
            let json = Data(#"{"provider":"\#(raw)"}"#.utf8)
            let decoded = try JSONDecoder().decode(WorkoutImportProvenance.self, from: json)
            XCTAssertEqual(decoded.provider.rawValue, raw)
            XCTAssertNotEqual(decoded.provider, .appleHealthExport)
        }
    }

    func testAppleHealthImportIsSearchableByItsProvider() {
        let provenance = WorkoutImportProvenance(
            provider: .appleHealthExport,
            providerActivityID: "1756650000-1756653600-HKWorkoutActivityTypeRunning-0",
            originalFilename: "route_1.gpx"
        )
        let run = RunWorkout(
            metadata: WorkoutMetadata(startDate: instant(1_756_650_000)),
            source: .healthKit,
            analysisVersion: RunWorkout.currentAnalysisVersion,
            importProvenance: provenance
        )
        let entry = WorkoutLibraryEntry.make(from: run, manifestIndex: 0, isFavorite: false)
        XCTAssertEqual(entry.importProvider, .appleHealthExport)

        let document = WorkoutLibrarySearchDocument.make(from: entry)

        XCTAssertTrue(
            document.normalizedText.contains("apple health"),
            "a user searching for the source should find it, got: \(document.normalizedText)"
        )
        XCTAssertTrue(document.normalizedText.contains("applehealthexport"))
    }
}
