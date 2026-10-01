import Combine
import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

/// The Apple Health review sheet: its derivations, its selection rules, and the
/// lifecycle it shares with the other batch sheets.
///
/// The scan and the archive read are `RunPlayPlatform`'s to prove. Proven here
/// is everything above them: what a row says, which rows start checked, what the
/// report claims afterwards, and that a pass which does not commit leaves the
/// library exactly as it was.
@MainActor
final class AppleHealthReviewTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleHealthReviewTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let running = "HKWorkoutActivityTypeRunning"

    private func candidate(
        index: Int,
        start: Int64,
        end: Int64,
        activity: String = running,
        route: String? = nil,
        heartRateBeats: [Double] = [],
        distanceMeters: Double? = 5_000,
        status: AppleHealthCandidateStatus = .ready,
        origin: AppleHealthDuplicateOrigin? = nil,
        utcOffsetSeconds: Int = 0
    ) -> AppleHealthWorkoutCandidate {
        let statistics = distanceMeters.map { meters in
            [AppleHealthWorkoutStatistic(
                type: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                unit: "km",
                sum: meters / 1_000
            )]
        } ?? []
        let heartRate = heartRateBeats.enumerated().map { offset, beats in
            AppleHealthHeartRateReading(
                startSeconds: start + Int64(offset) * 60,
                durationSeconds: 0,
                beatsPerMinute: beats
            )
        }
        return AppleHealthWorkoutCandidate(
            id: "\(start)-\(end)-\(activity)-\(index)",
            sourceIndex: index,
            window: AppleHealthWorkoutWindow(
                startSeconds: start,
                endSeconds: end,
                activityType: activity,
                utcOffsetSeconds: utcOffsetSeconds
            ),
            statistics: statistics,
            routeArchivePath: route,
            heartRate: heartRate,
            sourceDistanceMeters: distanceMeters,
            status: status,
            duplicateOrigin: origin
        )
    }

    private func scanResult(
        candidates: [AppleHealthWorkoutCandidate],
        dropped: Int = 0,
        unmatchedRoutes: Int = 0,
        excluded: [String: Int] = [:]
    ) -> AppleHealthArchiveScanResult {
        AppleHealthArchiveScanResult(
            scan: AppleHealthExportScan(
                workouts: candidates.map {
                    AppleHealthExportScan.WorkoutEntry(
                        window: $0.window,
                        statistics: $0.statistics,
                        routeArchivePath: $0.routeArchivePath,
                        heartRate: $0.heartRate
                    )
                },
                droppedWorkoutCount: dropped
            ),
            candidates: candidates,
            exportXMLEntryPath: "apple_health_export/export.xml",
            usedCaseInsensitiveXMLLookup: false,
            report: AppleHealthArchiveReport(
                workoutCount: candidates.count,
                candidateCount: candidates.count,
                duplicateCandidateCount: candidates.count { $0.status != .ready },
                droppedWorkoutCount: dropped,
                unmatchedRouteReferenceCount: unmatchedRoutes,
                routeEntryCount: 0,
                entryCount: 1,
                uncompressedXMLBytes: 0,
                excludedWorkoutsByActivityType: excluded
            )
        )
    }

    private func makeSession(_ candidates: [AppleHealthWorkoutCandidate]) -> AppleHealthImportSession {
        AppleHealthImportSession(
            archiveURL: tempDir.appendingPathComponent("export.zip"),
            scanResult: scanResult(candidates: candidates),
            securityScoped: false
        )
    }

    private func makeAppState(
        announcer: any AccessibilityAnnouncing = AccessibilityAnnouncer.shared
    ) -> AppState {
        AppState(
            storeActor: WorkoutLibraryStoreActor(
                store: FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))
            ),
            importService: WorkoutImportService(),
            appleHealthArchiveService: AppleHealthArchiveService(),
            accessibilityAnnouncer: announcer
        )
    }

    private func present(_ appState: AppState, _ result: AppleHealthArchiveScanResult) {
        appState.presentAppleHealthReview(
            result,
            archiveURL: tempDir.appendingPathComponent("export.zip"),
            securityScoped: false
        )
    }

    /// Wait for the sheet to reach a terminal phase, or to be dismissed.
    private func waitForTerminalPhase(_ appState: AppState) async {
        for _ in 0..<400 {
            guard let session = appState.appleHealthSession else { return }
            if session.phase == .report { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Apple Health import did not reach a terminal phase")
    }

    // MARK: - Row wording

    func testActivityNamesAreReadableAndAnUnknownShapeIsLeftAlone() {
        let expected = [
            ("HKWorkoutActivityTypeRunning", "Running"),
            ("HKWorkoutActivityTypeHighIntensityIntervalTraining", "High Intensity Interval Training"),
            ("HKWorkoutActivityTypeSwimmingPoolSwim", "Swimming Pool Swim"),
            ("Cycling", "Cycling"),
            ("", "Workout"),
        ]
        for (raw, readable) in expected {
            XCTAssertEqual(AppleHealthReviewPresentation.activityName(raw), readable, raw)
        }
    }

    func testDurationComesFromTheWindowInHoursAndMinutes() {
        let expected: [(Int64, String)] = [(2_645, "44m 5s"), (3_900, "1h 5m"), (-5, "0m 0s")]
        for (span, text) in expected {
            let window = AppleHealthWorkoutWindow(
                startSeconds: 0, endSeconds: span, activityType: Self.running, utcOffsetSeconds: 0
            )
            XCTAssertEqual(AppleHealthReviewPresentation.durationText(window), text)
        }
    }

    func testDistanceIsKilometresAndADashMeansNoNumber() {
        XCTAssertEqual(AppleHealthReviewPresentation.distanceText(
            candidate(index: 0, start: 0, end: 60, distanceMeters: 5_000)), "5.00 km")
        XCTAssertEqual(AppleHealthReviewPresentation.distanceText(
            candidate(index: 0, start: 0, end: 60, distanceMeters: 21_097)), "21.1 km")
        XCTAssertEqual(AppleHealthReviewPresentation.distanceText(
            candidate(index: 0, start: 0, end: 60, distanceMeters: nil)), "—")
        XCTAssertEqual(AppleHealthReviewPresentation.distanceText(
            candidate(index: 0, start: 0, end: 60, distanceMeters: 0)), "—")
    }

    func testDistanceHelpSaysWhereTheNumberComesFrom() {
        let routed = candidate(index: 0, start: 0, end: 60, route: "apple_health_export/workout-routes/a.gpx")
        XCTAssertEqual(routed.distanceProvenance, .gpsDerived)
        XCTAssertEqual(
            AppleHealthReviewPresentation.distanceHelp(routed),
            "Measured from this workout's route when it is imported"
        )

        let routeLess = candidate(index: 0, start: 0, end: 60, route: nil)
        XCTAssertEqual(routeLess.distanceProvenance, .sourceReported)
        XCTAssertEqual(
            AppleHealthReviewPresentation.distanceHelp(routeLess),
            "Reported by the export itself"
        )
    }

    func testRouteAndHeartRateIndicatorsFollowTheCandidate() {
        let withBoth = candidate(
            index: 0, start: 0, end: 60,
            route: "apple_health_export/workout-routes/a.gpx",
            heartRateBeats: [140]
        )
        XCTAssertTrue(AppleHealthReviewPresentation.hasRoute(withBoth))
        XCTAssertTrue(AppleHealthReviewPresentation.hasHeartRate(withBoth))
        XCTAssertEqual(AppleHealthReviewPresentation.routeAccessibilityLabel(withBoth), "Has a route")

        let withNeither = candidate(index: 0, start: 0, end: 60, route: nil, heartRateBeats: [])
        XCTAssertFalse(AppleHealthReviewPresentation.hasRoute(withNeither))
        XCTAssertFalse(AppleHealthReviewPresentation.hasHeartRate(withNeither))
        XCTAssertEqual(AppleHealthReviewPresentation.heartRateAccessibilityLabel(withNeither), "No heart rate")
    }

    func testRowAccessibilityLabelIncludesTheEntireFlagReasonAndProvenance() {
        let row = candidate(index: 0, start: 0, end: 60,
                            heartRateBeats: [140], status: .possibleDuplicate, origin: .withinExport)
        let reason = AppleHealthReviewPresentation.flagText(row)!
        let label = AppleHealthReviewPresentation.rowAccessibilityLabel(row)
        XCTAssertTrue(label.contains(reason))
        XCTAssertTrue(label.contains("Running"))
        XCTAssertTrue(label.contains("Duration 1m 0s"))
        XCTAssertTrue(label.contains("Distance 5.00 km, Reported by the export itself"))
        XCTAssertTrue(label.contains("No route; Has heart rate"))
    }

    func testFlagDetailShowsTheSelectedFlaggedRowsFullReason() {
        let row = candidate(index: 0, start: 0, end: 60,
                            status: .possibleDuplicate, origin: .existingLibrary)
        XCTAssertEqual(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: row, flaggedCount: 2),
            "Possible duplicate — Overlaps a run already in your library")
    }

    func testFlagDetailSummarizesFlagsWhenNoFlaggedRowIsSelected() {
        let expected = "2 rows flagged as duplicates or possible duplicates."
        XCTAssertEqual(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: nil, flaggedCount: 2), expected)
        XCTAssertEqual(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: candidate(index: 0, start: 0, end: 60), flaggedCount: 2), expected)
        XCTAssertEqual(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: nil, flaggedCount: 1),
            "1 row flagged as duplicates or possible duplicates.")
    }

    func testFlagDetailIsAbsentWhenThereAreNoFlags() {
        XCTAssertNil(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: nil, flaggedCount: 0))
        XCTAssertNil(AppleHealthReviewPresentation.flagDetailText(
            selectedCandidate: candidate(index: 0, start: 0, end: 60), flaggedCount: 0))
    }

    func testEveryFlagStatesWhatItIsAndWhatItMatched() {
        XCTAssertEqual(
            AppleHealthReviewPresentation.flagText(candidate(
                index: 0, start: 0, end: 60, status: .duplicate, origin: .withinExport)),
            "Duplicate — Overlaps another workout in this export"
        )
        XCTAssertEqual(
            AppleHealthReviewPresentation.flagText(candidate(
                index: 1, start: 100, end: 200, status: .possibleDuplicate, origin: .existingLibrary)),
            "Possible duplicate — Overlaps a run already in your library"
        )
        XCTAssertNil(AppleHealthReviewPresentation.flagText(candidate(index: 2, start: 300, end: 400)))
    }

    func testRecordedOffsetIsShownOnlyWhenTheExportStatedOne() {
        let expected = [(0, ""), (28_800, " (UTC+08:00)"), (-18_000, " (UTC−05:00)"), (19_800, " (UTC+05:30)")]
        for (offset, text) in expected {
            XCTAssertEqual(AppleHealthReviewPresentation.offsetText(offset), text)
        }
    }

    // MARK: - Selection and filtering

    func testOnlyUnflaggedCandidatesStartChecked() {
        let candidates = [
            candidate(index: 0, start: 0, end: 60),
            candidate(index: 1, start: 100, end: 200, status: .duplicate, origin: .existingLibrary),
            candidate(index: 2, start: 300, end: 400, status: .possibleDuplicate, origin: .withinExport),
        ]
        XCTAssertEqual(AppleHealthReviewPresentation.defaultSelection(candidates), [candidates[0].id])
        XCTAssertEqual(AppleHealthReviewPresentation.readyCount(candidates), 1)
        XCTAssertEqual(AppleHealthReviewPresentation.flaggedCount(candidates), 2)
    }

    func testSelectAllReadyAndSelectNoneRestoreTheUnflaggedRows() {
        let candidates = [
            candidate(index: 0, start: 0, end: 60),
            candidate(index: 1, start: 100, end: 200, status: .duplicate, origin: .withinExport),
        ]
        let session = makeSession(candidates)
        session.selectedIDs.insert(candidates[1].id)
        XCTAssertEqual(session.selectedCount, 2)

        session.selectAllReady()
        XCTAssertEqual(session.selectedIDs, [candidates[0].id])

        session.selectNone()
        XCTAssertEqual(session.selectedCount, 0)
    }

    func testSearchMatchesWhatTheTableShowsAndFlaggedOnlyIsASeparateSwitch() {
        let candidates = [
            candidate(index: 0, start: 0, end: 60, activity: "HKWorkoutActivityTypeCycling",
                      route: "apple_health_export/workout-routes/route_2024-01-01.gpx"),
            candidate(index: 1, start: 100, end: 200, status: .duplicate, origin: .withinExport),
        ]
        func filtered(
            _ candidates: [AppleHealthWorkoutCandidate],
            _ query: String,
            _ flaggedOnly: Bool
        ) -> [AppleHealthWorkoutCandidate] {
            AppleHealthReviewPresentation.filtered(candidates, query: query, flaggedOnly: flaggedOnly)
        }
        XCTAssertEqual(filtered(candidates, "cycl", false).map(\.sourceIndex), [0])
        XCTAssertEqual(filtered(candidates, "hkworkoutactivitytyperunning", false).map(\.sourceIndex), [1])
        XCTAssertEqual(filtered(candidates, "route_2024-01-01", false).map(\.sourceIndex), [0])
        XCTAssertTrue(filtered(candidates, "nothing matches", false).isEmpty)

        XCTAssertEqual(filtered(candidates, "", true).map(\.sourceIndex), [1])
        XCTAssertEqual(filtered(candidates, "duplicate", true).map(\.sourceIndex), [1])    }

    func testSelectionFollowsExportOrderRatherThanClickOrder() {
        let candidates = (0..<3).map { index in
            candidate(index: index, start: Int64(index) * 100, end: Int64(index) * 100 + 60)
        }
        let session = makeSession(candidates)
        session.selectNone()
        session.selectedIDs.insert(candidates[2].id)

        let selection = session.candidates.filter { session.selectedIDs.contains($0.id) }
        XCTAssertEqual(selection.map(\.sourceIndex), [2])
    }

    // MARK: - Report wording

    func testReportHeadlineNamesWhatHappened() {
        XCTAssertEqual(
            AppleHealthImportSummary(report: AppleHealthImportReport(importedWorkoutIDs: [UUID(), UUID()])).headline,
            "Imported 2 runs"
        )
        XCTAssertEqual(
            AppleHealthImportSummary(report: AppleHealthImportReport(importedWorkoutIDs: [UUID()])).headline,
            "Imported 1 run"
        )
        XCTAssertEqual(
            AppleHealthImportSummary(report: AppleHealthImportReport(wasCancelled: true)).outcome,
            .cancelled
        )
        XCTAssertEqual(
            AppleHealthImportSummary(report: AppleHealthImportReport(commitFailed: true)).outcome,
            .failed
        )
        XCTAssertEqual(
            AppleHealthImportSummary(report: AppleHealthImportReport()).outcome,
            .nothingNew
        )
    }

    func testNonRunningExclusionsArePlainLanguageInReviewAndReport() {
        XCTAssertNil(AppleHealthReviewPresentation.skippedNonRunningText(0))
        let singular = "1 non-running workout was skipped. Only running workouts are offered for import."
        let plural = "3 non-running workouts were skipped. Only running workouts are offered for import."
        XCTAssertEqual(AppleHealthReviewPresentation.skippedNonRunningText(1), singular)
        XCTAssertEqual(AppleHealthReviewPresentation.skippedNonRunningText(3), plural)
        let report = AppleHealthImportReport(excludedWorkoutsByActivityType: [
            "HKWorkoutActivityTypeCycling": 2, "HKWorkoutActivityTypeWalking": 1,
        ])
        XCTAssertEqual(AppleHealthImportSummary(report: report).lines, [plural])
        XCTAssertTrue(AppleHealthImportSummary(report: AppleHealthImportReport()).lines.isEmpty)
    }

    func testReportStatesDroppedWorkoutsAndUnmatchedRoutesInPlainLanguage() {
        let report = AppleHealthImportReport(
            items: [],
            importedWorkoutIDs: [UUID()],
            droppedWorkoutCount: 3,
            unmatchedRouteReferenceCount: 2
        )
        let summary = AppleHealthImportSummary(report: report)
        XCTAssertEqual(summary.droppedWorkoutCount, 3)
        XCTAssertEqual(summary.unmatchedRouteReferenceCount, 2)
        XCTAssertEqual(summary.lines.count, 2)
        XCTAssertTrue(
            summary.lines[0].contains("The export describes 3 workouts this import cannot read"),
            summary.lines[0]
        )
        XCTAssertTrue(
            summary.lines[1].contains("2 workouts name a route file the archive does not contain"),
            summary.lines[1]
        )
    }

    func testReportNamesTimeMismatchesWithoutCallingTheirFilesMissing() {
        for count in [1, 8] {
            let items = (0..<count).map { index in
                AppleHealthImportItemResult(candidateID: "mismatch-\(index)", activityType: Self.running,
                    startSeconds: 0, outcome: .importedWithoutRoute, routeFallbackReason: .routeWindowMismatch)
            }
            let summary = AppleHealthImportSummary(report: AppleHealthImportReport(items: items))
            XCTAssertEqual(summary.lines, ["\(count) \(count == 1 ? "run" : "runs") imported without a map because their route file didn't match the run's time."])
        }
    }

    func testReportSeparatesTrimmedRoutesFromUnavailableFilesAndIgnoresDiscardedItems() {
        let items = [
            AppleHealthImportItemResult(candidateID: "trimmed", activityType: Self.running,
                startSeconds: 0, outcome: .imported, wasRouteTrimmed: true),
            AppleHealthImportItemResult(candidateID: "missing", activityType: Self.running,
                startSeconds: 0, outcome: .importedWithoutRoute, routeFallbackReason: .routeFileUnavailable),
            AppleHealthImportItemResult(candidateID: "discarded", activityType: Self.running,
                startSeconds: 0, outcome: .discarded, routeFallbackReason: .routeWindowMismatch, wasRouteTrimmed: true),
        ]
        let report = AppleHealthImportReport(items: items)
        XCTAssertEqual(report.routeWindowMismatchCount, 0)
        XCTAssertEqual(report.trimmedRouteCount, 1)
        let summary = AppleHealthImportSummary(report: report)
        XCTAssertTrue(summary.lines.contains("1 run had their route trimmed to match the run's recorded time."))
        XCTAssertTrue(summary.lines.contains("1 run has no route, because its route file could not be read."))
        XCTAssertFalse(summary.lines.contains { $0.contains("didn't match") })
    }

    func testReportSaysNothingBeyondTheHeadlineWhenNothingWentWrong() {
        let summary = AppleHealthImportSummary(report: AppleHealthImportReport(importedWorkoutIDs: [UUID()]))
        XCTAssertTrue(summary.lines.isEmpty)
    }

    func testReportDistinguishesLeftAloneFromNotSaved() {
        let items = [
            AppleHealthImportItemResult(candidateID: "a", activityType: Self.running,
                                        startSeconds: 0, outcome: .alreadyInLibrary),
            AppleHealthImportItemResult(candidateID: "b", activityType: Self.running,
                                        startSeconds: 100, outcome: .discarded),
            AppleHealthImportItemResult(candidateID: "c", activityType: Self.running,
                                        startSeconds: 200, outcome: .failed),
        ]
        let summary = AppleHealthImportSummary(report: AppleHealthImportReport(items: items))
        XCTAssertEqual(summary.lines.count, 3)
        XCTAssertTrue(summary.lines[0].contains("1 run was already in your library"), summary.lines[0])
        XCTAssertTrue(summary.lines[1].contains("1 workout could not be read"), summary.lines[1])
        XCTAssertTrue(summary.lines[2].contains("1 workout was ready to import but not saved"), summary.lines[2])
        XCTAssertTrue(summary.lines[2].contains("library was left unchanged"), summary.lines[2])
    }

    func testReportRowTextNeverCallsAStagedWorkoutAFailure() {
        let discarded = AppleHealthImportItemResult(
            candidateID: "a", activityType: Self.running, startSeconds: 0, outcome: .discarded
        )
        XCTAssertEqual(AppleHealthReviewPresentation.itemOutcomeText(discarded), "Ready but not saved")

        let failed = AppleHealthImportItemResult(
            candidateID: "b", activityType: "HKWorkoutActivityTypeCycling",
            startSeconds: 0, outcome: .failed
        )
        XCTAssertEqual(AppleHealthReviewPresentation.itemOutcomeText(failed), "Could not be read")
        XCTAssertTrue(AppleHealthReviewPresentation.itemTitle(failed).hasPrefix("Cycling · "))
    }

    // MARK: - Sheet lifecycle

    func testReviewOpensWithDuplicatesUncheckedAndKeepsTheArchiveCounts() {
        let appState = makeAppState()
        let candidates = [
            candidate(index: 0, start: 0, end: 600),
            candidate(index: 1, start: 0, end: 600, status: .duplicate, origin: .existingLibrary),
        ]
        present(appState, scanResult(candidates: candidates, dropped: 4, unmatchedRoutes: 1))

        XCTAssertEqual(appState.appleHealthSession?.phase, .reviewing)
        XCTAssertEqual(appState.appleHealthSession?.selectedIDs, [candidates[0].id])
        XCTAssertEqual(appState.appleHealthSession?.scanResult.report.droppedWorkoutCount, 4)
        XCTAssertEqual(appState.appleHealthSession?.scanResult.report.unmatchedRouteReferenceCount, 1)
        XCTAssertTrue(appState.isModalPresentationActive)
    }

    func testCancellingTheReviewClosesItAndLeavesTheLibraryUntouched() {
        let appState = makeAppState()
        present(appState, scanResult(candidates: [candidate(index: 0, start: 0, end: 600)]))

        appState.cancelAppleHealthImport()

        XCTAssertNil(appState.appleHealthSession)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.workouts.isEmpty)
    }

    func testImportKeepsTheHeartRateAndStatesTheExportsOwnDistance() async throws {
        let appState = makeAppState()
        let candidates = [
            candidate(index: 0, start: 0, end: 600, route: nil, heartRateBeats: [150, 152]),
            candidate(index: 1, start: 5_000, end: 6_200, route: nil, distanceMeters: 3_200),
        ]
        present(appState, scanResult(candidates: candidates, dropped: 2, unmatchedRoutes: 1,
                                     excluded: ["HKWorkoutActivityTypeCycling": 3]))

        appState.confirmAppleHealthImport()
        await waitForTerminalPhase(appState)

        XCTAssertEqual(appState.appleHealthSession?.phase, .report)
        XCTAssertEqual(appState.appleHealthSession?.progress.phase, .completed)
        XCTAssertEqual(appState.workouts.count, 2)

        let report = try XCTUnwrap(appState.appleHealthSession?.report)
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertEqual(report.addedWorkoutCount, 2)
        XCTAssertEqual(report.droppedWorkoutCount, 2)
        XCTAssertEqual(report.unmatchedRouteReferenceCount, 1)
        XCTAssertEqual(report.excludedWorkoutsByActivityType, ["HKWorkoutActivityTypeCycling": 3])

        let stored = try XCTUnwrap(appState.workouts.first { $0.id == report.items[0].importedWorkoutID })
        XCTAssertEqual(stored.source, .healthKit)
        XCTAssertEqual(stored.summary.distanceProvenance, .sourceReported)
        XCTAssertTrue(stored.routePoints.isEmpty)
        XCTAssertEqual(stored.heartRateSeries?.count, 2)
        XCTAssertEqual(stored.importProvenance?.provider, .appleHealthExport)
    }

    func testImportingTheSameReviewTwiceAddsNothingTheSecondTime() async {
        let appState = makeAppState()
        present(appState, scanResult(candidates: [
            candidate(index: 0, start: 1_000, end: 1_600),
            candidate(index: 1, start: 9_000, end: 9_600),
        ]))
        appState.confirmAppleHealthImport()
        await waitForTerminalPhase(appState)
        XCTAssertEqual(appState.workouts.count, 2)
        appState.dismissAppleHealthSession()

        // The same export read again arrives with every row flagged, so nothing
        // is checked and confirming is a no-op rather than a second copy.
        present(appState, scanResult(candidates: [
            candidate(index: 0, start: 1_000, end: 1_600, status: .duplicate, origin: .existingLibrary),
            candidate(index: 1, start: 9_000, end: 9_600, status: .duplicate, origin: .existingLibrary),
        ]))
        XCTAssertEqual(appState.appleHealthSession?.selectedIDs, [])

        appState.confirmAppleHealthImport()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.appleHealthSession?.phase, .reviewing)
        XCTAssertEqual(appState.workouts.count, 2)
        XCTAssertEqual(appState.operationState, .idle)
    }

    func testAFlaggedCandidateImportsWhenTheUserChecksItDeliberately() async {
        let appState = makeAppState()
        let flagged = candidate(
            index: 0, start: 500, end: 1_100,
            status: .possibleDuplicate, origin: .withinExport
        )
        present(appState, scanResult(candidates: [flagged]))
        XCTAssertEqual(appState.appleHealthSession?.selectedCount, 0)

        // Turning the row on by hand is the only way a flagged workout reaches
        // the library, and it must then import like any other.
        appState.appleHealthSession?.selectedIDs.insert(flagged.id)
        appState.confirmAppleHealthImport()
        await waitForTerminalPhase(appState)

        XCTAssertEqual(appState.workouts.count, 1)
        XCTAssertEqual(appState.appleHealthSession?.report?.importedCount, 1)
    }

    func testAnImportThatIsCancelledMidFlightIsAllOrNothing() async {
        let appState = makeAppState()
        let candidates = (0..<40).map { index in
            candidate(index: index, start: Int64(index) * 600, end: Int64(index) * 600 + 500)
        }
        present(appState, scanResult(candidates: candidates))

        appState.confirmAppleHealthImport()
        appState.cancelAppleHealthImport()
        await waitForTerminalPhase(appState)

        // The cancel races the pass, so either outcome is legitimate. A partial
        // batch is not: the batch seam commits everything or nothing.
        let stored = appState.workouts.count
        XCTAssertTrue(stored == 0 || stored == 40, "a cancelled import stored \(stored) of 40 workouts")
        XCTAssertEqual(appState.operationState, .idle)
    }

    // MARK: - A cancelled import ends on a report

    /// Assert the library holds nothing, in memory and on disk. A library that
    /// was never written has no manifest, which is exactly the state an import
    /// that rolled back leaves behind.
    private func assertLibraryUntouched(
        _ appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertTrue(appState.workouts.isEmpty, "a cancelled import must add nothing", file: file, line: line)
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("library"))
        XCTAssertThrowsError(try store.loadManifest(), "a cancelled import must write no manifest", file: file, line: line) { error in
            guard case WorkoutLibraryError.manifestMissing = error else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }
        let hasActiveBatch = await appState.storeActor?.hasActiveBatch
        XCTAssertEqual(hasActiveBatch, false, "a cancelled import must release the batch", file: file, line: line)
    }

    func testCancellingAfterStagingEndsOnACancelledReportAndLeavesTheLibraryUnchanged() async throws {
        let announcer = RecordingAccessibilityAnnouncer()
        let appState = makeAppState(announcer: announcer)
        let candidates = (0..<6).map { index in
            candidate(index: index, start: Int64(index) * 600, end: Int64(index) * 600 + 500)
        }
        present(appState, scanResult(candidates: candidates))
        let session = try XCTUnwrap(appState.appleHealthSession)

        // Cancel from inside the progress stream once two workouts are staged.
        // That fixes the cancel at a point of the pass, after staging and before
        // the commit, instead of racing it.
        let cancelOnceTwoAreStaged = session.$progress.sink { progress in
            if progress.stagedCount >= 2 { appState.cancelAppleHealthImport() }
        }
        defer { cancelOnceTwoAreStaged.cancel() }

        appState.confirmAppleHealthImport()
        await waitForTerminalPhase(appState)

        // The sheet stays open on a report until the user dismisses it.
        let open = try XCTUnwrap(appState.appleHealthSession, "a cancelled import must not close the sheet")
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertTrue(report.wasCancelled)
        XCTAssertGreaterThanOrEqual(report.discardedCount, 2, "the staged workouts were rolled back")
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(report.addedWorkoutCount, 0)

        let summary = AppleHealthImportSummary(report: report)
        XCTAssertEqual(summary.outcome, .cancelled)
        XCTAssertEqual(summary.headline, "Import cancelled")
        XCTAssertEqual(summary.lines.first, BatchImportReportPresentation.cancelledNotice)

        await assertLibraryUntouched(appState)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.isModalPresentationActive, "the report is the open sheet")
        XCTAssertEqual(announcer.messages, ["Import cancelled."], "announced once, when the report appears")

        appState.dismissAppleHealthSession()
        XCTAssertNil(appState.appleHealthSession)
        XCTAssertFalse(appState.isModalPresentationActive)
    }

    func testCancellingBeforeAnythingIsStagedEndsOnTheSameCancelledReport() async throws {
        let announcer = RecordingAccessibilityAnnouncer()
        let appState = makeAppState(announcer: announcer)
        present(appState, scanResult(
            candidates: [candidate(index: 0, start: 0, end: 600)],
            dropped: 3,
            unmatchedRoutes: 2,
            excluded: ["HKWorkoutActivityTypeCycling": 5]
        ))

        // The task has not started when the cancel arrives, so the service
        // stops before it stages anything.
        appState.confirmAppleHealthImport()
        appState.cancelAppleHealthImport()
        await waitForTerminalPhase(appState)

        let open = try XCTUnwrap(appState.appleHealthSession, "a cancelled import must not close the sheet")
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.items.isEmpty, "nothing had been staged")

        // The scan's own counts survive, so the report does not understate the export.
        XCTAssertEqual(report.droppedWorkoutCount, 3)
        XCTAssertEqual(report.unmatchedRouteReferenceCount, 2)
        XCTAssertEqual(report.excludedWorkoutsByActivityType, ["HKWorkoutActivityTypeCycling": 5])

        let summary = AppleHealthImportSummary(report: report)
        XCTAssertEqual(summary.outcome, .cancelled)
        XCTAssertEqual(summary.lines.first, BatchImportReportPresentation.cancelledNotice)

        await assertLibraryUntouched(appState)
        XCTAssertEqual(appState.operationState, .idle)
        XCTAssertTrue(appState.isModalPresentationActive, "the report is the open sheet")
        XCTAssertEqual(announcer.messages, ["Import cancelled."], "announced once, when the report appears")
    }

    func testANormalCompletionStillEndsOnTheAddedOutcome() async throws {
        let appState = makeAppState()
        present(appState, scanResult(candidates: [
            candidate(index: 0, start: 0, end: 600),
            candidate(index: 1, start: 5_000, end: 5_600),
        ]))

        appState.confirmAppleHealthImport()
        await waitForTerminalPhase(appState)

        let open = try XCTUnwrap(appState.appleHealthSession)
        XCTAssertEqual(open.phase, .report)
        let report = try XCTUnwrap(open.report)
        XCTAssertFalse(report.wasCancelled)
        let summary = AppleHealthImportSummary(report: report)
        XCTAssertEqual(summary.outcome, .added)
        XCTAssertEqual(summary.headline, "Imported 2 runs")
        XCTAssertFalse(summary.lines.contains(BatchImportReportPresentation.cancelledNotice))
        XCTAssertEqual(appState.workouts.count, 2)
    }

    func testACancelledReportSaysNothingWasSavedBeforeAnythingElse() {
        let cancelled = AppleHealthImportSummary(report: AppleHealthImportReport(
            wasCancelled: true,
            droppedWorkoutCount: 1,
            excludedWorkoutsByActivityType: ["HKWorkoutActivityTypeCycling": 2]
        ))
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.lines.first, BatchImportReportPresentation.cancelledNotice)
        XCTAssertGreaterThan(cancelled.lines.count, 1, "the export's own counts still follow the notice")

        // Only a cancel carries the notice: a failed commit is never softened by
        // it, and a completed pass has nothing to say about cancelling.
        for report in [
            AppleHealthImportReport(commitFailed: true),
            AppleHealthImportReport(),
            AppleHealthImportReport(importedWorkoutIDs: [UUID()]),
        ] {
            XCTAssertFalse(
                AppleHealthImportSummary(report: report).lines.contains(BatchImportReportPresentation.cancelledNotice)
            )
        }
    }
}
