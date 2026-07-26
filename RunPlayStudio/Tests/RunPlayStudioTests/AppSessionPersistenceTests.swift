import XCTest
import RunPlayCore
@testable import RunPlayStudio

@MainActor
final class AppSessionPersistenceTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSessionPersistenceTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSnapshotJSONRoundTripsWithDurableOnlyState() throws {
        let workoutID = UUID()
        let peerID = UUID()
        let tagID = UUID()
        let collectionID = UUID()
        let query = WorkoutLibrarySavedQuery(
            searchText: "race",
            filter: WorkoutLibraryFilter(
                date: .custom(
                    start: Date(timeIntervalSince1970: 100),
                    end: Date(timeIntervalSince1970: 200)
                ),
                tags: .selected(tagIDs: [tagID], match: .all)
            ),
            sort: .distanceLongest
        )
        let snapshot = AppSessionSnapshot(
            destination: .smartCollection(collectionID),
            sidebarVisibilityRaw: "all",
            workout: AppSessionWorkoutState(tabRaw: "Charts", mapDisplayModeRaw: "3D"),
            library: AppSessionLibraryState(
                manualQuery: query,
                activeSmartCollectionID: collectionID,
                activeSmartCollectionModified: true,
                modifiedWorkingQuery: query
            ),
            heatmap: AppSessionHeatmapState(
                datePresetRaw: "custom",
                customStartDate: Date(timeIntervalSince1970: 300),
                customEndDate: Date(timeIntervalSince1970: 400),
                resolutionRaw: "fine",
                minimumWorkoutCount: 3
            ),
            comparison: AppSessionComparisonState(peerWorkoutID: peerID, distanceMeters: 250),
            replay: AppSessionReplayState(
                workoutID: workoutID,
                elapsedSeconds: 42,
                playbackSpeed: 2
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppSessionSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("routePoints"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("resultIDs"))
    }

    func testValidatorRepairsDanglingReferencesAndClampsScalars() {
        let selectedID = UUID()
        let peerID = UUID()
        let collectionID = UUID()
        let knownTagID = UUID()
        let missingCollectionID = UUID()
        let snapshot = AppSessionSnapshot(
            destination: .smartCollection(missingCollectionID),
            workout: AppSessionWorkoutState(tabRaw: "Unknown", mapDisplayModeRaw: "sideways"),
            library: AppSessionLibraryState(
                manualQuery: WorkoutLibrarySavedQuery(
                    searchText: String(repeating: "x", count: 501),
                    filter: WorkoutLibraryFilter(
                        tags: .selected(tagIDs: [knownTagID, UUID()], match: .any)
                    )
                ),
                activeSmartCollectionID: collectionID,
                activeSmartCollectionModified: true,
                modifiedWorkingQuery: WorkoutLibrarySavedQuery(
                    searchText: "working"
                )
            ),
            heatmap: AppSessionHeatmapState(
                datePresetRaw: "bad",
                resolutionRaw: "bad",
                minimumWorkoutCount: 0
            ),
            comparison: AppSessionComparisonState(peerWorkoutID: peerID, distanceMeters: .nan),
            replay: AppSessionReplayState(
                workoutID: selectedID,
                elapsedSeconds: 500,
                playbackSpeed: 64
            )
        )
        let context = AppSessionValidationContext(
            workoutIDs: [selectedID, peerID],
            selectedWorkoutID: selectedID,
            smartCollectionIDs: [collectionID],
            tagIDs: [knownTagID],
            replayDuration: 120,
            comparisonDistanceLimit: 80
        )

        let result = AppSessionValidator.validate(snapshot, context: context)

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.snapshot.destination, .allRuns)
        XCTAssertEqual(result.snapshot.workout.tabRaw, "Overview")
        XCTAssertEqual(result.snapshot.workout.mapDisplayModeRaw, "2D")
        XCTAssertEqual(result.snapshot.library.manualQuery.searchText.unicodeScalars.count, 500)
        XCTAssertEqual(
            result.snapshot.library.manualQuery.filter.tags,
            .selected(tagIDs: [knownTagID], match: .any)
        )
        XCTAssertEqual(result.snapshot.library.manualQuery.sort, .dateNewest)
        XCTAssertNil(result.snapshot.library.activeSmartCollectionID)
        XCTAssertEqual(result.snapshot.heatmap.datePresetRaw, "allTime")
        XCTAssertEqual(result.snapshot.heatmap.resolutionRaw, "standard")
        XCTAssertEqual(result.snapshot.heatmap.minimumWorkoutCount, 1)
        XCTAssertNil(result.snapshot.comparison)
        XCTAssertEqual(result.snapshot.replay?.elapsedSeconds, 120)
        XCTAssertEqual(result.snapshot.replay?.playbackSpeed, 1)
        XCTAssertTrue(result.issues.count >= 4)
    }

    func testValidatorKeepsValidComparisonAndClampsDistance() {
        let selectedID = UUID()
        let peerID = UUID()
        let snapshot = AppSessionSnapshot(
            destination: .comparison,
            comparison: AppSessionComparisonState(peerWorkoutID: peerID, distanceMeters: 999),
            replay: AppSessionReplayState(workoutID: selectedID, elapsedSeconds: 10, playbackSpeed: 0.5)
        )

        let result = AppSessionValidator.validate(
            snapshot,
            context: AppSessionValidationContext(
                workoutIDs: [selectedID, peerID],
                selectedWorkoutID: selectedID,
                replayDuration: 100,
                comparisonDistanceLimit: 300
            )
        )

        XCTAssertEqual(result.snapshot.destination, .comparison)
        XCTAssertEqual(result.snapshot.comparison?.peerWorkoutID, peerID)
        XCTAssertEqual(result.snapshot.comparison?.distanceMeters, 300)
        XCTAssertEqual(result.snapshot.comparison?.alignmentModeRaw, ComparisonAlignmentMode.distance.rawValue)
        XCTAssertEqual(result.snapshot.replay?.playbackSpeed, 0.5)
        XCTAssertFalse(result.snapshot.replay?.elapsedSeconds == 0)
    }

    func testVersion1ComparisonSessionMigratesToDistanceAlignment() throws {
        let peerID = UUID()
        // Encode a v1-shaped payload by omitting alignment fields from a full
        // snapshot JSON, then decode as the current schema.
        let v1Base = AppSessionSnapshot(
            version: 1,
            destination: .comparison,
            comparison: AppSessionComparisonState(peerWorkoutID: peerID, distanceMeters: 250)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(v1Base)) as! [String: Any]
        object["version"] = 1
        if var comparison = object["comparison"] as? [String: Any] {
            comparison.removeValue(forKey: "alignmentModeRaw")
            comparison.removeValue(forKey: "alignedProgressMeters")
            object["comparison"] = comparison
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.comparison?.peerWorkoutID, peerID)
        XCTAssertEqual(decoded.comparison?.distanceMeters, 250)
        XCTAssertEqual(decoded.comparison?.alignmentModeRaw, ComparisonAlignmentMode.distance.rawValue)
        XCTAssertEqual(decoded.comparison?.alignedProgressMeters, 0)
    }

    func testInvalidAlignmentModeFallsBackToDistance() {
        let selectedID = UUID()
        let peerID = UUID()
        let snapshot = AppSessionSnapshot(
            destination: .comparison,
            comparison: AppSessionComparisonState(
                peerWorkoutID: peerID,
                distanceMeters: 100,
                alignmentModeRaw: "not-a-mode",
                alignedProgressMeters: 50
            )
        )
        let result = AppSessionValidator.validate(
            snapshot,
            context: AppSessionValidationContext(
                workoutIDs: [selectedID, peerID],
                selectedWorkoutID: selectedID,
                comparisonDistanceLimit: 200
            )
        )
        XCTAssertEqual(result.snapshot.comparison?.alignmentModeRaw, ComparisonAlignmentMode.distance.rawValue)
        XCTAssertTrue(result.usedFallback)
    }

    func testValidatorRepairsInvalidHeatmapDateRangeAndMinimum() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let result = AppSessionValidator.validate(
            AppSessionSnapshot(
                heatmap: AppSessionHeatmapState(
                    datePresetRaw: "custom",
                    customStartDate: referenceDate.addingTimeInterval(100),
                    customEndDate: referenceDate.addingTimeInterval(-100),
                    minimumWorkoutCount: 4
                )
            ),
            context: AppSessionValidationContext(referenceDate: referenceDate)
        )

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.snapshot.heatmap.datePresetRaw, "allTime")
        XCTAssertNil(result.snapshot.heatmap.customStartDate)
        XCTAssertNil(result.snapshot.heatmap.customEndDate)
        XCTAssertEqual(result.snapshot.heatmap.minimumWorkoutCount, 1)
    }

    func testValidatorFutureVersionUsesSafeDefault() {
        let selectedID = UUID()
        let result = AppSessionValidator.validate(
            AppSessionSnapshot(version: AppSessionSnapshot.currentVersion + 1),
            context: AppSessionValidationContext(
                workoutIDs: [selectedID],
                selectedWorkoutID: selectedID
            )
        )

        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.snapshot.destination, .workout)
        XCTAssertEqual(result.snapshot.replay?.workoutID, selectedID)
        XCTAssertEqual(result.snapshot.replay?.elapsedSeconds, 0)
    }

    func testFileStoreSavesLoadsAndClearsAtomically() async throws {
        let store = FileAppSessionStore(rootURL: tempDir)
        let snapshot = AppSessionSnapshot(
            destination: .personalHeatmap,
            heatmap: AppSessionHeatmapState(
                datePresetRaw: "last30Days",
                customStartDate: Date(timeIntervalSince1970: 100),
                customEndDate: Date(timeIntervalSince1970: 200),
                resolutionRaw: "broad",
                minimumWorkoutCount: 2
            )
        )

        try await store.save(snapshot)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("session.json").path
        ))
        let loaded = await store.load()
        XCTAssertEqual(loaded, snapshot)

        try await store.clear()
        let cleared = await store.load()
        XCTAssertNil(cleared)
    }

    func testFileStoreReplacesAnExistingSnapshot() async throws {
        let store = FileAppSessionStore(rootURL: tempDir)
        let first = AppSessionSnapshot(destination: .allRuns)
        let second = AppSessionSnapshot(destination: .personalHeatmap)

        try await store.save(first)
        try await store.save(second)

        let loaded = await store.load()
        XCTAssertEqual(loaded, second)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "tmp" }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testFileStoreRejectsOversizedSnapshot() async {
        let store = FileAppSessionStore(rootURL: tempDir, maxFileBytes: 32)

        do {
            try await store.save(AppSessionSnapshot())
            XCTFail("Expected the bounded store to reject the snapshot.")
        } catch FileAppSessionStoreError.tooLarge(let limit) {
            XCTAssertEqual(limit, 32)
        } catch {
            XCTFail("Unexpected store error: \(error)")
        }
    }

    func testFileStoreTreatsMalformedDataAsMissing() async throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: tempDir.appendingPathComponent("session.json"),
            options: .atomic
        )

        let store = FileAppSessionStore(rootURL: tempDir)

        let loaded = await store.load()
        XCTAssertNil(loaded)
    }
}
