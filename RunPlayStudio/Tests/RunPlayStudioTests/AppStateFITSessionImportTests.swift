import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

/// Routing between direct FIT import and the multi-session review sheet.
@MainActor
final class AppStateFITSessionImportTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateFITSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeAppState() -> AppState {
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))
        return AppState(
            storeActor: WorkoutLibraryStoreActor(store: store),
            importService: WorkoutImportService(),
            fitSessionService: FITSessionImportService(digest: CryptoKitContentDigest())
        )
    }

    private func writeFixture(_ data: Data, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeJSONWorkout() throws -> URL {
        var points: [RoutePoint] = []
        for index in 0..<12 {
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 10),
                latitude: 37.0 + Double(index) * 0.0005,
                longitude: -122.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(index) * 50,
                elapsedSeconds: Double(index) * 10
            ))
        }
        let workout = RunWorkout(
            metadata: WorkoutMetadata(
                name: "JSON Run",
                startDate: Date(timeIntervalSince1970: 1_000_000)
            ),
            source: .json,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 550, totalElapsedSeconds: 110)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = tempDir.appendingPathComponent("run.json")
        try encoder.encode(workout).write(to: url, options: .atomic)
        return url
    }

    private func importAndWaitForReport(_ appState: AppState) async {
        appState.confirmFITSessionImport()
        for _ in 0..<400 {
            if appState.fitSessionImportSession?.phase == .report
                || appState.fitSessionImportSession == nil {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("FIT session import did not reach a terminal phase")
    }

    // MARK: - Routing

    func testNonFITFileStillImportsDirectly() async throws {
        let appState = makeAppState()
        let url = try writeJSONWorkout()

        await appState.importWorkout(from: url)

        XCTAssertNil(appState.fitSessionImportSession, "JSON must never reach the FIT scanner")
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testSingleSessionFITImportsDirectlyWithoutAReviewSheet() async throws {
        let appState = makeAppState()
        let url = try writeFixture(
            FITFixtureBuilder.buildSampleRunWithSession(elapsedSeconds: 290, timerSeconds: 290),
            named: "single.fit"
        )

        await appState.importWorkout(from: url)

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.selectedWorkout?.source, .fit)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testLegacyFITWithoutSessionsImportsDirectly() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildSampleRun(), named: "legacy.fit")

        await appState.importWorkout(from: url)

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertEqual(appState.workouts.count, 1)
    }

    func testMultiSessionFITOpensTheReviewSheet() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")

        await appState.importWorkout(from: url)

        let session = try XCTUnwrap(appState.fitSessionImportSession)
        XCTAssertEqual(session.phase, .reviewing)
        XCTAssertEqual(session.scanResult.candidates.count, 2)
        XCTAssertEqual(session.selectedCount, 2)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(
            appState.workouts.isEmpty,
            "Nothing may be imported before the user confirms"
        )
    }

    func testMixedSportReviewDisablesTheUnsupportedSession() async throws {
        let appState = makeAppState()
        let url = try writeFixture(
            FITFixtureBuilder.buildRunningPlusCyclingSessions(),
            named: "mixed.fit"
        )

        await appState.importWorkout(from: url)

        let session = try XCTUnwrap(appState.fitSessionImportSession)
        XCTAssertEqual(session.scanResult.candidates.count, 2)
        XCTAssertTrue(session.isSelectable(session.scanResult.candidates[0]))
        XCTAssertFalse(
            session.isSelectable(session.scanResult.candidates[1]),
            "Cycling stays visible but not selectable"
        )
        XCTAssertEqual(session.selectedCount, 1)

        // Force-selecting a disabled row is a no-op.
        session.setSelected(true, for: session.scanResult.candidates[1])
        XCTAssertEqual(session.selectedCount, 1)
    }

    func testInvalidFITFileUsesTheExistingImportErrorPath() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildInvalidDataType(), named: "broken.fit")

        await appState.importWorkout(from: url)

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertTrue(appState.showingError)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertEqual(appState.operationState, .idle)
    }

    // MARK: - Selection controls

    func testSelectNoneAndSelectAllImportable() async throws {
        let appState = makeAppState()
        let url = try writeFixture(
            FITFixtureBuilder.buildRunningPlusCyclingSessions(),
            named: "mixed.fit"
        )
        await appState.importWorkout(from: url)
        let session = try XCTUnwrap(appState.fitSessionImportSession)

        session.selectNone()
        XCTAssertEqual(session.selectedCount, 0)
        XCTAssertFalse(session.canImport)

        session.selectAllImportable()
        XCTAssertEqual(session.selectedCount, 1, "Only importable rows are selected")
        XCTAssertTrue(session.canImport)
    }

    func testCandidatesAreDisplayedInFITSourceOrder() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        let session = try XCTUnwrap(appState.fitSessionImportSession)

        XCTAssertEqual(session.displayedCandidates.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(
            session.displayedCandidates.map(\.providerActivityID),
            session.scanResult.candidates.map(\.providerActivityID)
        )
    }

    func testSelectionSummaryReportsImportableCount() async throws {
        let appState = makeAppState()
        let url = try writeFixture(
            FITFixtureBuilder.buildRunningPlusCyclingSessions(),
            named: "mixed.fit"
        )
        await appState.importWorkout(from: url)
        let session = try XCTUnwrap(appState.fitSessionImportSession)

        XCTAssertEqual(
            session.selectionAccessibilityValue,
            "1 of 1 importable sessions selected"
        )
        session.selectNone()
        XCTAssertEqual(
            session.selectionAccessibilityValue,
            "0 of 1 importable sessions selected"
        )
    }

    // MARK: - Import

    func testImportingBothSessionsCommitsAtomicallyAndSelectsTheNewest() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        XCTAssertNotNil(appState.fitSessionImportSession)

        await importAndWaitForReport(appState)

        let session = try XCTUnwrap(appState.fitSessionImportSession)
        let report = try XCTUnwrap(session.report)
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertFalse(report.commitFailed)
        XCTAssertEqual(appState.workouts.count, 2)
        XCTAssertEqual(appState.libraryWorkoutIDs.count, 2)
        XCTAssertTrue(appState.hasPersistedLibrary)
        XCTAssertEqual(appState.operationState, .idle)

        let newest = appState.workouts.max {
            ($0.metadata.startDate ?? .distantPast) < ($1.metadata.startDate ?? .distantPast)
        }
        XCTAssertEqual(appState.selectedWorkout?.id, newest?.id)

        for workout in appState.workouts {
            XCTAssertEqual(workout.importProvenance?.provider, .fitMultiSessionFile)
            XCTAssertNotNil(workout.importProvenance?.sourceContainerSHA256)
        }
    }

    func testReimportingTheSameFileMarksBothSessionsAlreadyImported() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        await importAndWaitForReport(appState)
        appState.dismissFITSessionImport()
        XCTAssertEqual(appState.workouts.count, 2)

        await appState.importWorkout(from: url)
        let session = try XCTUnwrap(appState.fitSessionImportSession)
        XCTAssertEqual(session.scanResult.duplicateCount, 2)
        XCTAssertEqual(session.selectedCount, 0)
    }

    func testRenamingTheFileStillDetectsTheSameSessions() async throws {
        let appState = makeAppState()
        let data = FITFixtureBuilder.buildTwoRunningSessions()
        let original = try writeFixture(data, named: "multi.fit")
        await appState.importWorkout(from: original)
        await importAndWaitForReport(appState)
        appState.dismissFITSessionImport()

        let renamed = try writeFixture(data, named: "renamed-run.fit")
        await appState.importWorkout(from: renamed)
        let session = try XCTUnwrap(appState.fitSessionImportSession)
        XCTAssertEqual(
            session.scanResult.duplicateCount, 2,
            "Identity is container-derived, not filename-derived"
        )
    }

    // MARK: - Lifecycle

    func testCancellingReviewImportsNothing() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        XCTAssertNotNil(appState.fitSessionImportSession)

        appState.cancelFITSessionImport()

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testDismissingTheReportClearsTheSession() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        await importAndWaitForReport(appState)

        appState.dismissFITSessionImport()

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertEqual(appState.workouts.count, 2, "Committed workouts survive dismissal")
    }

    func testOpenImportedRunSelectsTheReportedWorkout() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        await importAndWaitForReport(appState)
        let expected = try XCTUnwrap(appState.fitSessionImportSession?.report?.selectedWorkoutID)

        appState.viewMostRecentFITImportedRun()

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertEqual(appState.selectedWorkout?.id, expected)
        XCTAssertEqual(appState.workspaceMode, .workout)
    }

    func testOpenAllRunsShowsTheLibraryWorkspace() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        await importAndWaitForReport(appState)

        appState.showAllRunsAfterFITImport()

        XCTAssertNil(appState.fitSessionImportSession)
        XCTAssertEqual(appState.workspaceMode, .workoutLibrary)
    }

    // MARK: - Modal command blocking

    func testReviewSheetBlocksBackgroundCommands() async throws {
        let appState = makeAppState()
        XCTAssertFalse(appState.isModalPresentationActive)

        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        XCTAssertTrue(appState.isModalPresentationActive)

        appState.cancelFITSessionImport()
        XCTAssertFalse(appState.isModalPresentationActive)
    }

    func testASecondImportCannotStartWhileTheReviewSheetIsOpen() async throws {
        let appState = makeAppState()
        let url = try writeFixture(FITFixtureBuilder.buildTwoRunningSessions(), named: "multi.fit")
        await appState.importWorkout(from: url)
        let session = try XCTUnwrap(appState.fitSessionImportSession)

        let jsonURL = try writeJSONWorkout()
        await appState.importWorkout(from: jsonURL)

        XCTAssertTrue(appState.workouts.isEmpty)
        XCTAssertTrue(appState.fitSessionImportSession === session)
    }
}
