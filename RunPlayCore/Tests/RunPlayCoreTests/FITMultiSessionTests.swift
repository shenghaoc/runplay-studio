import XCTest
@testable import RunPlayCore

/// Session discovery, routing, statuses, identity, and the batch transaction.
final class FITMultiSessionTests: XCTestCase {

    private var tempDir: URL!
    private let digest = TestContentDigest()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FITMultiSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeService(
        policy: FITMultiSessionImportPolicy = .default
    ) -> FITSessionImportService {
        FITSessionImportService(digest: digest, policy: policy)
    }

    @discardableResult
    private func write(_ data: Data, named name: String = "workout.fit") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func scan(
        _ data: Data,
        named name: String = "workout.fit",
        existing: [RunWorkout] = [],
        policy: FITMultiSessionImportPolicy = .default
    ) async throws -> FITSessionScanResult {
        let url = try write(data, named: name)
        return try await makeService(policy: policy).scanFITFile(
            at: url,
            existingWorkouts: existing
        ) { _ in }
    }

    // MARK: - Routing

    func testLegacyFileWithNoSessionsRoutesDirect() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.legacyNoSessions())
        XCTAssertEqual(result.routing, .direct)
        XCTAssertEqual(result.totalSessionMessageCount, 0)
        XCTAssertTrue(result.candidates.isEmpty, "A legacy file must not open a review sheet")
    }

    func testSingleSessionFileRoutesDirect() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.singleRunningSession())
        XCTAssertEqual(result.routing, .direct)
        XCTAssertEqual(result.totalSessionMessageCount, 1)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testTwoSessionFileRoutesToReview() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.twoSequentialRuns())
        XCTAssertEqual(result.routing, .review)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.readyCount, 2)
        XCTAssertEqual(result.defaultSelectedCount, 2)
    }

    // MARK: - Discovery

    func testCandidatesFollowFITSourceOrderNotDate() async throws {
        // Second session in source order starts earlier in time.
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: 2_000 + UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 2_000, endOffsetSeconds: 2_090),
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates.map(\.sourceIndex), [0, 1])
        XCTAssertTrue(
            (result.candidates[0].startDate ?? .distantPast)
                > (result.candidates[1].startDate ?? .distantPast),
            "Display order must be source order, not chronological order"
        )
    }

    func testRunningPlusCyclingMarksCyclingUnsupported() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.runningPlus(sport: .cycling))
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].status, .ready)
        XCTAssertTrue(result.candidates[0].isSelectedByDefault)
        XCTAssertEqual(result.candidates[1].status, .unsupportedSport)
        XCTAssertFalse(result.candidates[1].isSelectedByDefault)
        XCTAssertEqual(result.candidates[1].sportDescription, "Cycling")
    }

    func testRunningPlusSwimmingMarksSwimmingUnsupported() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.runningPlus(sport: .swimming))
        XCTAssertEqual(result.candidates[1].status, .unsupportedSport)
        XCTAssertEqual(result.candidates[1].sportDescription, "Swimming")
    }

    func testWalkingFollowsExistingUnsupportedFITPolicy() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.runningPlus(sport: .walking))
        XCTAssertEqual(
            result.candidates[1].status, .unsupportedSport,
            "FIT policy on main only imports FITSport.running"
        )
    }

    func testSeveralUnsupportedSessionsAreAllVisible() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90, sport: .cycling),
                .init(startOffsetSeconds: 200, endOffsetSeconds: 290, sport: .swimming),
                .init(startOffsetSeconds: 400, endOffsetSeconds: 490, sport: .rowing)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates.count, 3, "Every session stays visible for transparency")
        XCTAssertEqual(result.unsupportedCount, 3)
        XCTAssertEqual(result.defaultSelectedCount, 0)
    }

    func testUnknownSportIsTreatedAsRunningWithAWarning() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(startOffsetSeconds: 1_000, endOffsetSeconds: 1_090, sport: nil)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[1].sport, .unknownTreatedAsRunning)
        XCTAssertEqual(result.candidates[1].status, .ready)
        XCTAssertNotNil(result.candidates[1].statusDetail)
    }

    func testSessionWithoutGPSIsNotImportable() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<5).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), hasValidCoordinates: false)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(startOffsetSeconds: 1_000, endOffsetSeconds: 1_040)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[0].status, .ready)
        XCTAssertEqual(result.candidates[1].status, .noGPSRoute)
        XCTAssertEqual(result.candidates[1].gpsRecordCount, 0)
    }

    func testMalformedStartBoundaryIsReported() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                // No start time and an invalid elapsed total.
                .init(
                    startOffsetSeconds: nil,
                    endOffsetSeconds: 1_090,
                    elapsedMillisecondsOverride: 0xFFFF_FFFF
                )
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[1].status, .invalidBoundaries)
        XCTAssertFalse(result.candidates[1].isSelectedByDefault)
    }

    func testDerivedStartFromElapsedKeepsSessionImportable() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(startOffsetSeconds: nil, endOffsetSeconds: 1_090, elapsedSeconds: 90)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[1].status, .ready)
        XCTAssertEqual(result.candidates[1].gpsRecordCount, 10)
    }

    func testOverlappingSessionsAreAmbiguousAndNotSelected() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<20).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 150),
                .init(startOffsetSeconds: 100, endOffsetSeconds: 190)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[0].status, .ambiguousAttribution)
        XCTAssertEqual(result.candidates[1].status, .ambiguousAttribution)
        XCTAssertEqual(result.defaultSelectedCount, 0)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testSharedBoundaryRecordIsNotCountedTwice() async throws {
        // Session A ends exactly where session B starts.
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<20).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 100),
                .init(startOffsetSeconds: 100, endOffsetSeconds: 190)
            ]
        )
        let result = try await scan(data)
        XCTAssertEqual(result.candidates[0].status, .ready)
        XCTAssertEqual(result.candidates[1].status, .ready)
        let total = result.candidates.reduce(0) { $0 + $1.gpsRecordCount }
        XCTAssertEqual(total, 20, "The boundary record must belong to exactly one session")
        XCTAssertEqual(result.candidates[0].gpsRecordCount, 10)
        XCTAssertEqual(result.candidates[1].gpsRecordCount, 10)
    }

    func testTooManySessionsIsRejected() async throws {
        let policy = FITMultiSessionImportPolicy(maxScannedSessions: 3)
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<8).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            },
            sessions: (0..<4).map { index in
                .init(
                    startOffsetSeconds: UInt32(index) * 1_000,
                    endOffsetSeconds: UInt32(index) * 1_000 + 90
                )
            }
        )
        do {
            _ = try await scan(data, policy: policy)
            XCTFail("Expected tooManySessions")
        } catch let error as FITSessionImportError {
            XCTAssertEqual(error, .tooManySessions(3))
        }
    }

    func testNonLocalURLIsRejected() async throws {
        let service = makeService()
        do {
            _ = try await service.scanFITFile(
                at: URL(string: "https://example.com/run.fit")!,
                existingWorkouts: []
            ) { _ in }
            XCTFail("Expected notLocalFile")
        } catch let error as FITSessionImportError {
            XCTAssertEqual(error, .notLocalFile)
        }
    }

    func testDirectoryURLIsRejected() async throws {
        let service = makeService()
        do {
            _ = try await service.scanFITFile(at: tempDir, existingWorkouts: []) { _ in }
            XCTFail("Expected cannotReadFile")
        } catch let error as FITSessionImportError {
            guard case .cannotReadFile = error else {
                return XCTFail("Expected cannotReadFile, got \(error)")
            }
        }
    }

    func testScanCancellationDoesNotSurfaceAsAParseError() async throws {
        let url = try write(FITMultiSessionFixtureBuilder.twoSequentialRuns())
        let service = makeService()
        let task = Task {
            try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Scan must not complete successfully after cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Cancellation surfaced as \(error)")
        }
    }

    func testExceedsResourceLimitMarksSessionsNotImportable() async throws {
        let result = try await scan(
            FITMultiSessionFixtureBuilder.twoSequentialRuns(),
            policy: FITMultiSessionImportPolicy(maxRecords: 5)
        )
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(
            result.candidates.allSatisfy { $0.status == .exceedsResourceLimit },
            "Over-limit containers must mark every session, not leave them Ready"
        )
        XCTAssertEqual(result.defaultSelectedCount, 0)
        XCTAssertEqual(result.readyCount, 0)
    }

    func testContainerTooLargeIsRejected() async throws {
        let url = try write(FITMultiSessionFixtureBuilder.twoSequentialRuns())
        let service = makeService(policy: FITMultiSessionImportPolicy(maxContainerBytes: 16))
        do {
            _ = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
            XCTFail("Expected containerTooLarge")
        } catch let error as FITSessionImportError {
            XCTAssertEqual(error, .containerTooLarge)
        }
    }

    // MARK: - Identity and provenance

    func testSiblingSessionIdentitiesDiffer() async throws {
        let result = try await scan(FITMultiSessionFixtureBuilder.twoSequentialRuns())
        XCTAssertNotEqual(
            result.candidates[0].providerActivityID,
            result.candidates[1].providerActivityID
        )
        XCTAssertTrue(result.candidates[0].providerActivityID.hasPrefix("fit-session-v1:"))
    }

    func testIdentityIsStableAcrossScans() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let first = try await scan(data, named: "a.fit")
        let second = try await scan(data, named: "a.fit")
        XCTAssertEqual(
            first.candidates.map(\.providerActivityID),
            second.candidates.map(\.providerActivityID)
        )
    }

    func testRenamingTheFileDoesNotChangeIdentity() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let original = try await scan(data, named: "morning-run.fit")
        let renamed = try await scan(data, named: "completely-different-name.fit")
        XCTAssertEqual(
            original.candidates.map(\.providerActivityID),
            renamed.candidates.map(\.providerActivityID)
        )
        XCTAssertNotEqual(
            original.candidates[0].displayName,
            renamed.candidates[0].displayName,
            "The display name follows the filename even though identity does not"
        )
    }

    func testIdenticalSessionMetadataInDifferentContainersDoesNotCollide() {
        var session = FITSessionMessage()
        session.startTime = 1_000
        session.timestamp = 2_000
        session.sport = FITSport.running.rawValue

        let first = FITSessionIdentity.providerActivityID(
            containerSHA256: String(repeating: "a", count: 64),
            sourceIndex: 0,
            session: session,
            digest: digest
        )
        let second = FITSessionIdentity.providerActivityID(
            containerSHA256: String(repeating: "b", count: 64),
            sourceIndex: 0,
            session: session,
            digest: digest
        )
        XCTAssertNotEqual(first, second)
    }

    func testDisplayNameContainsNoFingerprintOrPath() async throws {
        let result = try await scan(
            FITMultiSessionFixtureBuilder.twoSequentialRuns(),
            named: "run.fit"
        )
        for candidate in result.candidates {
            XCTAssertFalse(candidate.displayName.contains("fit-session-v1"))
            XCTAssertFalse(candidate.displayName.contains(tempDir.path))
            XCTAssertFalse(candidate.displayName.contains("/"))
            XCTAssertTrue(candidate.displayName.hasPrefix("run — "))
        }
    }

    func testDisplayNameFallsBackToOrdinalWithoutADate() async throws {
        // Both sessions derive their start from elapsed totals only, so the
        // second has no resolvable start at all.
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(
                    startOffsetSeconds: nil,
                    endOffsetSeconds: nil,
                    elapsedMillisecondsOverride: 0xFFFF_FFFF
                )
            ]
        )
        let result = try await scan(data, named: "run.fit")
        XCTAssertEqual(result.candidates[1].displayName, "run — Run 2")
    }

    func testExistingSessionIsMarkedDuplicate() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let initial = try await scan(data)
        var alreadyImported = makeStubWorkout()
        alreadyImported.importProvenance = WorkoutImportProvenance(
            provider: .fitMultiSessionFile,
            providerActivityID: initial.candidates[0].providerActivityID,
            sourceContainerSHA256: initial.containerSHA256
        )

        let rescan = try await scan(data, existing: [alreadyImported])
        XCTAssertEqual(rescan.candidates[0].status, .duplicate)
        XCTAssertEqual(
            rescan.candidates[1].status, .ready,
            "A shared container hash must not make siblings duplicates"
        )
    }

    func testMatchingContainerHashAloneDoesNotMarkDuplicates() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let initial = try await scan(data)
        var other = makeStubWorkout()
        other.importProvenance = WorkoutImportProvenance(
            provider: .fitMultiSessionFile,
            providerActivityID: "fit-session-v1:something-else",
            sourceContainerSHA256: initial.containerSHA256
        )
        let rescan = try await scan(data, existing: [other])
        XCTAssertEqual(rescan.readyCount, 2)
    }

    func testDuplicateRequiresFitMultiSessionProvider() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let initial = try await scan(data)
        var singleFileWithMatchingID = makeStubWorkout()
        // Same activity ID under a different provider must not count as a
        // multi-session exact duplicate.
        singleFileWithMatchingID.importProvenance = WorkoutImportProvenance(
            provider: .singleFile,
            providerActivityID: initial.candidates[0].providerActivityID,
            sourceContainerSHA256: initial.containerSHA256
        )

        let rescan = try await scan(data, existing: [singleFileWithMatchingID])
        XCTAssertEqual(
            rescan.candidates[0].status, .ready,
            "Duplicate detection requires provider .fitMultiSessionFile"
        )
        XCTAssertEqual(rescan.candidates[1].status, .ready)
    }

    func testOldProvenanceDecodesWithoutTheNewField() throws {
        let legacyJSON = """
        {"provider":"singleFile","originalFilename":"run.fit"}
        """
        let decoded = try JSONDecoder().decode(
            WorkoutImportProvenance.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.provider, .singleFile)
        XCTAssertNil(decoded.sourceContainerSHA256)
    }

    // MARK: - Batch transaction

    func testTwoValidSessionsCommitTogether() async throws {
        let (report, store) = try await runImport(
            data: FITMultiSessionFixtureBuilder.twoSequentialRuns()
        )
        XCTAssertEqual(report.importedCount, 2)
        XCTAssertFalse(report.commitFailed)
        XCTAssertFalse(report.wasCancelled)

        let manifest = try store.loadManifest()
        XCTAssertEqual(manifest.workoutIDs.count, 2)
        XCTAssertEqual(
            manifest.workoutIDs, report.importedWorkoutIDs,
            "Manifest order follows FIT source order"
        )
        XCTAssertEqual(manifest.selectedWorkoutID, report.selectedWorkoutID)
    }

    func testNewestImportedSessionIsSelected() async throws {
        let (report, store) = try await runImport(
            data: FITMultiSessionFixtureBuilder.twoSequentialRuns()
        )
        let workouts = try report.importedWorkoutIDs.map { try store.loadWorkout(id: $0) }
        let newest = workouts.max {
            ($0.metadata.startDate ?? .distantPast) < ($1.metadata.startDate ?? .distantPast)
        }
        XCTAssertEqual(report.selectedWorkoutID, newest?.id)
    }

    func testValidSiblingCommitsWhenAnotherSelectedSessionFails() async throws {
        // Session 2 has no GPS, so it fails while session 1 still commits.
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<5).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), hasValidCoordinates: false)
            },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(startOffsetSeconds: 1_000, endOffsetSeconds: 1_040)
            ]
        )
        let (report, store) = try await runImport(data: data, selectAll: true)
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.count(for: .noGPSRoute), 1)
        XCTAssertEqual(try store.loadManifest().workoutIDs.count, 1)
    }

    func testZeroStagedWorkoutsRollBackAndWriteNoManifest() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map { .init(offsetSeconds: UInt32($0 * 10), hasValidCoordinates: false) },
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 40),
                .init(startOffsetSeconds: 50, endOffsetSeconds: 90)
            ]
        )
        let (report, store) = try await runImport(data: data, selectAll: true)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertFalse(report.commitFailed)
        XCTAssertThrowsError(try store.loadManifest())
    }

    func testDuplicateIsSkippedWhileValidSiblingCommits() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }

        var alreadyImported = makeStubWorkout()
        alreadyImported.importProvenance = WorkoutImportProvenance(
            provider: .fitMultiSessionFile,
            providerActivityID: scanResult.candidates[0].providerActivityID
        )

        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let report = try await service.importSessions(
            FITSessionImportSelection(
                selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
                candidates: scanResult.candidates
            ),
            from: url,
            existingWorkouts: [alreadyImported],
            storeActor: storeActor
        ) { _ in }

        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.count(for: .duplicate), 1)
    }

    func testCommitFailureLeavesNothingImported() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }

        let backing = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let failing = FailingManifestStore(wrapped: backing)
        let storeActor = WorkoutLibraryStoreActor(store: failing)

        let report = try await service.importSessions(
            FITSessionImportSelection(
                selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
                candidates: scanResult.candidates
            ),
            from: url,
            existingWorkouts: [],
            storeActor: storeActor
        ) { _ in }

        XCTAssertTrue(report.commitFailed)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(
            report.count(for: .ready), 0,
            "A staged session whose commit failed must not be reported as imported"
        )
        XCTAssertThrowsError(try backing.loadManifest())
        for id in report.items.compactMap(\.importedWorkoutID) {
            XCTAssertFalse(backing.workoutExists(id: id), "No workout file may survive a failed commit")
        }
    }

    func testCancellationBeforeStagingImportsNothing() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let selection = FITSessionImportSelection(
            selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
            candidates: scanResult.candidates
        )

        let task = Task {
            try await service.importSessions(
                selection,
                from: url,
                existingWorkouts: [],
                storeActor: storeActor
            ) { _ in }
        }
        task.cancel()
        let report = try await task.value

        XCTAssertTrue(report.wasCancelled, "Cancellation must be a structured result, not an error")
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertThrowsError(try store.loadManifest())
        let hasActiveBatch = await storeActor.hasActiveBatch
        XCTAssertFalse(hasActiveBatch)
    }

    func testCancellationAfterStagingRollsBackAndCommitsNothing() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let selection = FITSessionImportSelection(
            selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
            candidates: scanResult.candidates
        )

        // Cancel deterministically once the first workout has been staged.
        let box = TaskBox()
        let task = Task { () -> FITSessionBatchImportReport in
            try await service.importSessions(
                selection,
                from: url,
                existingWorkouts: [],
                storeActor: storeActor
            ) { progress in
                if progress.phase == .staging {
                    box.cancel()
                }
            }
        }
        box.task = task
        let report = try await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.importedCount, 0, "No workout may be imported after cancellation")
        XCTAssertThrowsError(try store.loadManifest())
        for id in report.items.compactMap(\.importedWorkoutID) {
            XCTAssertFalse(store.workoutExists(id: id), "Cancellation must leave no staged file")
        }
        let hasActiveBatch = await storeActor.hasActiveBatch
        XCTAssertFalse(hasActiveBatch)
    }

    func testCancellationAtCommitIsStructuredCancelNotCommitFailure() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib-commit-cancel"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let selection = FITSessionImportSelection(
            selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
            candidates: scanResult.candidates
        )

        // Cancel once both candidates are staged and the service moves to commit.
        let box = TaskBox()
        let task = Task { () -> FITSessionBatchImportReport in
            try await service.importSessions(
                selection,
                from: url,
                existingWorkouts: [],
                storeActor: storeActor
            ) { progress in
                if progress.phase == .committing {
                    box.cancel()
                }
            }
        }
        box.task = task
        let report = try await task.value

        XCTAssertTrue(report.wasCancelled, "Cancel at commit must be wasCancelled, not commitFailed")
        XCTAssertFalse(report.commitFailed)
        XCTAssertEqual(report.importedCount, 0)
        XCTAssertThrowsError(try store.loadManifest())
        let hasActiveBatch = await storeActor.hasActiveBatch
        XCTAssertFalse(hasActiveBatch)
    }

    func testTooManySelectedSessionsIsRejected() async throws {
        let data = FITMultiSessionFixtureBuilder.twoSequentialRuns()
        let url = try write(data)
        let service = makeService(policy: FITMultiSessionImportPolicy(maxSelectedSessions: 1))
        let scanService = makeService()
        let scanResult = try await scanService.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)

        do {
            _ = try await service.importSessions(
                FITSessionImportSelection(
                    selectedCandidateIDs: scanResult.candidates.map(\.providerActivityID),
                    candidates: scanResult.candidates
                ),
                from: url,
                existingWorkouts: [],
                storeActor: storeActor
            ) { _ in }
            XCTFail("Expected tooManySelectedSessions")
        } catch let error as FITSessionImportError {
            XCTAssertEqual(error, .tooManySelectedSessions(1))
        }
    }

    // MARK: - Imported workout construction

    func testImportedSessionsCarryDistinctRoutesAndCorrectProvenance() async throws {
        let (report, store) = try await runImport(
            data: FITMultiSessionFixtureBuilder.twoSequentialRuns()
        )
        XCTAssertEqual(report.importedCount, 2)
        let workouts = try report.importedWorkoutIDs.map { try store.loadWorkout(id: $0) }

        for workout in workouts {
            XCTAssertEqual(workout.source, .fit)
            XCTAssertEqual(workout.metadata.activityType, "running")
            XCTAssertEqual(workout.routePoints.count, 10)
            XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.currentSourceStructureVersion)
            XCTAssertEqual(workout.normalizationVersion, RunWorkout.currentNormalizationVersion)
            XCTAssertEqual(workout.analysisVersion, RunWorkout.currentAnalysisVersion)

            let provenance = try XCTUnwrap(workout.importProvenance)
            XCTAssertEqual(provenance.provider, .fitMultiSessionFile)
            XCTAssertNotNil(provenance.sourceContainerSHA256)
            XCTAssertNil(
                provenance.contentSHA256,
                "Siblings must not share a per-activity content hash"
            )
            XCTAssertEqual(provenance.originalFilename, "workout.fit")
            XCTAssertFalse(provenance.originalFilename?.contains("/") ?? false)
        }

        // No route point crosses the session boundary.
        let firstLatitudes = Set(workouts[0].routePoints.map(\.latitude))
        let secondLatitudes = Set(workouts[1].routePoints.map(\.latitude))
        XCTAssertTrue(firstLatitudes.isDisjoint(with: secondLatitudes))
    }

    func testTimerEventsDoNotSplitTheSiblingSession() async throws {
        // A pause/resume pair inside session 1 only.
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            events: [
                .init(offsetSeconds: 0, timerEventType: 0),
                .init(offsetSeconds: 40, timerEventType: 1),
                .init(offsetSeconds: 60, timerEventType: 0),
                .init(offsetSeconds: 90, timerEventType: 4)
            ],
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90),
                .init(startOffsetSeconds: 1_000, endOffsetSeconds: 1_090)
            ]
        )
        let (report, store) = try await runImport(data: data)
        XCTAssertEqual(report.importedCount, 2)
        let workouts = try report.importedWorkoutIDs.map { try store.loadWorkout(id: $0) }

        let firstSegments = Set(workouts[0].routePoints.map(\.routeSegmentIndex))
        let secondSegments = Set(workouts[1].routePoints.map(\.routeSegmentIndex))
        XCTAssertGreaterThan(firstSegments.count, 1, "Session 1 is split by its own timer events")
        XCTAssertEqual(secondSegments.count, 1, "Session 2 has no timer events of its own")
    }

    func testLapsAreScopedToTheirOwnSession() async throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                .init(offsetSeconds: UInt32($0 * 10), coordinateStep: Int32($0) * 2_000)
            } + (0..<10).map {
                .init(offsetSeconds: 1_000 + UInt32($0 * 10), coordinateStep: 500_000 + Int32($0) * 2_000)
            },
            laps: [
                .init(messageIndex: 0, startOffsetSeconds: 0, endOffsetSeconds: 40, elapsedSeconds: 40),
                .init(messageIndex: 1, startOffsetSeconds: 40, endOffsetSeconds: 90, elapsedSeconds: 50),
                .init(
                    messageIndex: 2,
                    startOffsetSeconds: 1_000,
                    endOffsetSeconds: 1_090,
                    elapsedSeconds: 90
                )
            ],
            sessions: [
                .init(startOffsetSeconds: 0, endOffsetSeconds: 90, firstLapIndex: 0, numberOfLaps: 2),
                .init(
                    startOffsetSeconds: 1_000,
                    endOffsetSeconds: 1_090,
                    firstLapIndex: 2,
                    numberOfLaps: 1
                )
            ]
        )
        let scanResult = try await scan(data)
        XCTAssertEqual(scanResult.candidates[0].recordedLapCount, 2)
        XCTAssertEqual(scanResult.candidates[1].recordedLapCount, 1)

        let (report, store) = try await runImport(data: data)
        let workouts = try report.importedWorkoutIDs.map { try store.loadWorkout(id: $0) }
        XCTAssertEqual(workouts[0].recordedLaps.count, 2)
        XCTAssertEqual(workouts[1].recordedLaps.count, 1)
    }

    // MARK: - Test support

    private func makeStubWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<3).map { index in
            RoutePoint(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 37 + Double(index) * 0.0001,
                longitude: -122,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index)
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Existing", startDate: start),
            source: .fit,
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 20, totalElapsedSeconds: 2)
        )
    }

    private func runImport(
        data: Data,
        selectAll: Bool = false
    ) async throws -> (FITSessionBatchImportReport, FileWorkoutLibraryStore) {
        let url = try write(data)
        let service = makeService()
        let scanResult = try await service.scanFITFile(at: url, existingWorkouts: []) { _ in }
        let ids = selectAll
            ? scanResult.candidates.map(\.providerActivityID)
            : scanResult.candidates.filter(\.isSelectedByDefault).map(\.providerActivityID)
        let store = FileWorkoutLibraryStore(rootURL: tempDir.appendingPathComponent("lib"))
        let storeActor = WorkoutLibraryStoreActor(store: store)
        let report = try await service.importSessions(
            FITSessionImportSelection(selectedCandidateIDs: ids, candidates: scanResult.candidates),
            from: url,
            existingWorkouts: [],
            storeActor: storeActor
        ) { _ in }
        return (report, store)
    }
}

/// Lets a progress callback cancel the task that owns it, so cancellation
/// lands at a specific phase instead of a racy "cancel immediately".
private final class TaskBox: @unchecked Sendable {
    var task: Task<FITSessionBatchImportReport, Error>?
    func cancel() { task?.cancel() }
}

/// Store that stages successfully but always fails the final manifest write.
private struct FailingManifestStore: WorkoutLibraryStoring {
    let wrapped: FileWorkoutLibraryStore

    func loadManifest() throws -> WorkoutLibraryManifest { try wrapped.loadManifest() }
    func saveManifest(_ manifest: WorkoutLibraryManifest) throws {
        throw WorkoutLibraryError.writeFailed("Injected manifest failure")
    }
    func loadWorkout(id: UUID) throws -> RunWorkout { try wrapped.loadWorkout(id: id) }
    func saveWorkout(_ workout: RunWorkout) throws { try wrapped.saveWorkout(workout) }
    func deleteWorkout(id: UUID) throws { try wrapped.deleteWorkout(id: id) }
    func workoutExists(id: UUID) -> Bool { wrapped.workoutExists(id: id) }
    var libraryRootURL: URL { wrapped.libraryRootURL }
    func stageWorkout(_ workout: RunWorkout, batchID: UUID) throws {
        try wrapped.stageWorkout(workout, batchID: batchID)
    }
    func loadStagedWorkout(id: UUID, batchID: UUID) throws -> RunWorkout {
        try wrapped.loadStagedWorkout(id: id, batchID: batchID)
    }
    func promoteStagedWorkouts(ids: [UUID], batchID: UUID) throws {
        try wrapped.promoteStagedWorkouts(ids: ids, batchID: batchID)
    }
    func removeStaging(batchID: UUID) throws { try wrapped.removeStaging(batchID: batchID) }
    func cleanupStaleStaging() throws { try wrapped.cleanupStaleStaging() }
    func cleanupUnreferencedWorkoutFiles(referencedIDs: Set<UUID>) throws {
        try wrapped.cleanupUnreferencedWorkoutFiles(referencedIDs: referencedIDs)
    }
}
