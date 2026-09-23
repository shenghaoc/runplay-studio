import Foundation
import XCTest
@testable import RunPlayCore

/// The library-wide DEM pass and the per-workout re-correct and opt-out on
/// `WorkoutLibraryStoreActor`, over the synthetic 2×2 tile set.
final class DEMElevationLibraryPassTests: XCTestCase {
    private var tempDir: URL!
    private var store: FileWorkoutLibraryStore!
    private var actor: WorkoutLibraryStoreActor!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DEMElevationLibraryPassTests-\(UUID().uuidString)")
        store = FileWorkoutLibraryStore(rootURL: tempDir)
        actor = WorkoutLibraryStoreActor(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testPassCorrectsEligibleWorkoutsAndSkipsOptedOutAndCurrentOnes() async throws {
        let source = SyntheticDEMTiles(height: 250)
        var optedOut = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        optedOut.demElevationCorrection = DEMElevationCorrection(outcome: .optedOut, tileSet: nil, correctedAt: Date())
        var current = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try DEMElevationCorrector().correct(&current, using: source)
        let fresh = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try seed([optedOut, current, fresh])

        let recorder = PassRecorder()
        let result = await actor.correctElevation(using: source, progress: { recorder.append($0) })

        XCTAssertEqual(result, .init(correctedCount: 1, skippedCount: 2, failedCount: 0, saveFailureCount: 0))
        XCTAssertEqual(recorder.correctedIDs, [fresh.id])
        XCTAssertEqual(recorder.completedCounts, [1, 2, 3])
        let saved = try store.loadWorkout(id: fresh.id)
        XCTAssertEqual(saved.demElevationCorrection?.outcome, .applied)
        XCTAssertTrue(saved.routePoints.allSatisfy { $0.demAltitudeMeters == 250 })
        XCTAssertEqual(try store.loadWorkout(id: optedOut.id).demElevationCorrection?.outcome, .optedOut)

        let again = await actor.correctElevation(using: source)
        XCTAssertEqual(again.correctedCount, 0, "a fully covered library is current")
        XCTAssertEqual(again.skippedCount, 3)
    }

    func testAnotherFolderMakesCorrectedWorkoutsStale() async throws {
        let workout = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try seed([workout])
        let first = SyntheticDEMTiles(height: 250)
        _ = await actor.correctElevation(using: first)
        let unchanged = await actor.correctElevation(using: first)
        XCTAssertEqual(unchanged.correctedCount, 0)

        let chosenAgain = SyntheticDEMTiles(height: 260, folderID: UUID())
        let result = await actor.correctElevation(using: chosenAgain)

        XCTAssertEqual(result.correctedCount, 1, "a newly chosen folder re-corrects the library")
        let saved = try store.loadWorkout(id: workout.id)
        XCTAssertEqual(saved.demElevationCorrection?.tileSet, chosenAgain.tileSet)
        XCTAssertTrue(saved.routePoints.allSatisfy { $0.demAltitudeMeters == 260 })
    }

    func testWorkoutsWithUncoveredPointsAreRetriedWithTheSameFolder() async throws {
        let missing = SyntheticDEMTiles.block[3]
        let partial = SyntheticDEMTiles(height: 250, tiles: SyntheticDEMTiles.block.filter { $0 != missing })
        let workout = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try seed([workout])

        _ = await actor.correctElevation(using: partial)
        let firstSave = try store.loadWorkout(id: workout.id)
        let retried = await actor.correctElevation(using: partial)
        XCTAssertEqual(partial.requests.count, 2, "the missing tile may have been added since")
        XCTAssertEqual(retried.correctedCount, 0, "nothing changed, so nothing is saved or reported")
        XCTAssertEqual(retried.skippedCount, 1)
        XCTAssertEqual(try store.loadWorkout(id: workout.id).demElevationCorrection, firstSave.demElevationCorrection)

        let tileAdded = SyntheticDEMTiles(height: 250)
        let completed = await actor.correctElevation(using: tileAdded)
        XCTAssertEqual(completed.correctedCount, 1)
        XCTAssertEqual(try store.loadWorkout(id: workout.id).demElevationCorrection?.coverage.missingTilePointCount, 0)
        let settled = await actor.correctElevation(using: tileAdded)
        XCTAssertEqual(settled.correctedCount, 0)
        XCTAssertEqual(tileAdded.requests.count, 1, "a fully covered workout is not re-checked")
    }

    func testUnloadableWorkoutsAreCountedAndThePassContinues() async throws {
        let workout = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try seed([workout])
        var manifest = try store.loadManifest()
        manifest.workoutIDs.insert(UUID(), at: 0)
        try store.saveManifest(manifest)

        let result = await actor.correctElevation(using: SyntheticDEMTiles(height: 250))

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.correctedCount, 1)
    }

    func testCancelledPassKeepsCompletedWorkoutsAndResumes() async throws {
        let workouts = try (0..<3).map { _ in try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 }) }
        try seed(workouts)
        let source = SyntheticDEMTiles(height: 250)
        let recorder = PassRecorder()
        let actor = self.actor!

        let task = Task {
            await actor.correctElevation(using: source, progress: { update in
                recorder.append(update)
                if update.correctedWorkout != nil { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let partial = await task.value

        XCTAssertEqual(partial.correctedCount, 1)
        XCTAssertEqual(partial.failedCount, 0, "cancellation is not a failure")
        let resumed = await actor.correctElevation(using: source)
        XCTAssertEqual(resumed.correctedCount, 2)
        XCTAssertEqual(resumed.skippedCount, 1)
    }

    func testOptingOutAndBackIn() async throws {
        let source = SyntheticDEMTiles(height: 250)
        let workout = try SyntheticDEMTiles.importedWorkout(recorded: { _ in 100 })
        try seed([workout])
        _ = try await actor.correctElevation(ofWorkout: workout.id, using: source)

        let optedOut = try await actor.setUsesRecordedElevation(true, ofWorkout: workout.id, source: source)
        XCTAssertEqual(optedOut.demElevationCorrection?.outcome, .optedOut)
        XCTAssertTrue(try store.loadWorkout(id: workout.id).routePoints.allSatisfy { $0.demAltitudeMeters == nil })
        let pass = await actor.correctElevation(using: source)
        XCTAssertEqual(pass.skippedCount, 1, "library passes leave an opted-out workout alone")

        let withoutFolder = try await actor.setUsesRecordedElevation(false, ofWorkout: workout.id, source: nil)
        XCTAssertNil(withoutFolder.demElevationCorrection, "eligible again for a later pass")
        _ = try await actor.setUsesRecordedElevation(true, ofWorkout: workout.id, source: nil)

        let backIn = try await actor.setUsesRecordedElevation(false, ofWorkout: workout.id, source: source)
        XCTAssertEqual(backIn.demElevationCorrection?.outcome, .applied)
        XCTAssertEqual(try store.loadWorkout(id: workout.id).demElevationCorrection?.outcome, .applied)
    }

    func testPerWorkoutEditsRequireALibraryWorkout() async throws {
        try seed([])
        let stranger = UUID()
        do {
            _ = try await actor.correctElevation(ofWorkout: stranger, using: SyntheticDEMTiles(height: 250))
            XCTFail("expected workoutNotInLibrary")
        } catch {
            XCTAssertEqual(error as? WorkoutLibraryStoreError, .workoutNotInLibrary(stranger))
        }
        do {
            _ = try await actor.setUsesRecordedElevation(true, ofWorkout: stranger, source: nil)
            XCTFail("expected workoutNotInLibrary")
        } catch {
            XCTAssertEqual(error as? WorkoutLibraryStoreError, .workoutNotInLibrary(stranger))
        }
    }

    // MARK: - Helpers

    private func seed(_ workouts: [RunWorkout]) throws {
        for workout in workouts {
            try store.saveWorkout(workout)
        }
        try store.saveManifest(WorkoutLibraryManifest(
            workoutIDs: workouts.map(\.id),
            selectedWorkoutID: workouts.first?.id
        ))
    }

    private final class PassRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [WorkoutLibraryStoreActor.DEMElevationPassUpdate] = []

        func append(_ update: WorkoutLibraryStoreActor.DEMElevationPassUpdate) {
            lock.withLock { updates.append(update) }
        }

        var correctedIDs: [UUID] {
            lock.withLock { updates.compactMap { $0.correctedWorkout?.id } }
        }

        var completedCounts: [Int] {
            lock.withLock { updates.map(\.completedCount) }
        }
    }
}
