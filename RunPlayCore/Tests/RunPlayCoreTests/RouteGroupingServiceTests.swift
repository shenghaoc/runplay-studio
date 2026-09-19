import XCTest
@testable import RunPlayCore

/// Pass-orchestration tests: incremental assignment, full re-cluster parity,
/// representative derivation, and manual-state carry-over.
final class RouteGroupingServiceTests: XCTestCase {    private let service = RouteGroupingService()

    private func inMemoryLoader(_ workouts: [RunWorkout]) -> @Sendable (UUID) async throws -> RunWorkout? {
        let byID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
        return { id in byID[id] }
    }

    /// Signature helper: group membership map (workout id → group id).
    private func membership(
        _ assignments: [WorkoutRouteGroupAssignment]
    ) -> [UUID: UUID?] {
        var map: [UUID: UUID?] = [:]
        for assignment in assignments {
            map[assignment.workoutID] = assignment.groupID
        }
        return map
    }

    // MARK: - Incremental assignment

    func testIncrementalAssignGroupsRepeatsOfOneLoop() async throws {
        let runs = (0..<4).map {
            RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0)
        }
        var groups: [WorkoutRouteGroup] = []
        var records: [WorkoutRouteGroupAssignment] = []

        for run in runs {
            let result = try await service.assign(
                newWorkouts: [run],
                existingGroups: groups,
                policy: .default,
                representativeLoader: inMemoryLoader(runs)
            )
            groups = result.groups
            records.append(contentsOf: result.assignments)
        }

        XCTAssertEqual(groups.count, 1, "four repeats of one loop must form one group")
        let assigned = membership(records).values.compactMap { $0 }
        XCTAssertEqual(assigned.count, 4)
        XCTAssertEqual(Set(assigned).count, 1)
    }

    func testIncrementalAssignmentCreatesSingletonForUniqueRoute() async throws {
        let loop = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0)
        let otherLoop = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.rectangleLoop(
                widthMeters: 1_000,
                heightMeters: 400,
                date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
            ),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let first = try await service.assign(
            newWorkouts: [loop],
            existingGroups: [],
            policy: .default,
            representativeLoader: inMemoryLoader([loop])
        )
        XCTAssertEqual(first.createdCount, 1)

        let second = try await service.assign(
            newWorkouts: [otherLoop],
            existingGroups: first.groups,
            policy: .default,
            representativeLoader: inMemoryLoader([loop, otherLoop])
        )
        XCTAssertEqual(second.joinedCount, 0)
        XCTAssertEqual(second.createdCount, 1)
        XCTAssertEqual(second.groups.count, 2)
    }

    func testNonParticipatingWorkoutReceivesNilAssignment() async throws {
        let date = RouteGroupingFixtures.epoch
        let tiny = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 80),
            date: date
        )

        let result = try await service.assign(
            newWorkouts: [tiny],
            existingGroups: [],
            policy: .default,
            representativeLoader: inMemoryLoader([tiny])
        )

        XCTAssertEqual(result.assignments.count, 1)
        XCTAssertNil(result.assignments[0].groupID)
        XCTAssertTrue(result.groups.isEmpty)
    }

    // MARK: - Parity: incremental vs full re-cluster

    func testIncrementalAssignmentMatchesFullReclusterForChronologicalImports() async throws {
        let routes: [[RunWorkout]] = [
            (0..<3).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) },
            (3..<5).map {
                RouteGroupingFixtures.workout(
                    points: RouteGroupingFixtures.rectangleLoop(
                        widthMeters: 1_000,
                        heightMeters: 400,
                        date: RouteGroupingFixtures.epoch.addingTimeInterval(Double($0) * 86_400)
                    ),
                    date: RouteGroupingFixtures.epoch.addingTimeInterval(Double($0) * 86_400)
                )
            }
        ]
        let all = routes.flatMap { $0 }.sorted { $0.metadata.startDate! < $1.metadata.startDate! }

        // Incremental: one import at a time, chronological.
        var incrementalGroups: [WorkoutRouteGroup] = []
        var incrementalRecords: [WorkoutRouteGroupAssignment] = []
        for run in all {
            let result = try await service.assign(
                newWorkouts: [run],
                existingGroups: incrementalGroups,
                policy: .default,
                representativeLoader: inMemoryLoader(all)
            )
            incrementalGroups = result.groups
            incrementalRecords.append(contentsOf: result.assignments)
        }

        // Full re-cluster over the same library.
        let reclustered = try service.recluster(workouts: all, policy: .default)

        // Group UUIDs differ between independent passes by design; the
        // partition into member sets must not.
        XCTAssertEqual(
            coMemberships(incrementalRecords),
            coMemberships(reclustered.assignments),
            "chronological incremental assignment must equal a full re-cluster"
        )

        // The effective representative is a pure function of the member set,
        // so it must also agree per member.
        XCTAssertEqual(
            representativeByWorkout(incrementalRecords, groups: incrementalGroups),
            representativeByWorkout(reclustered.assignments, groups: reclustered.groups)
        )
    }

    /// Workouts that share a group with each workout (empty set when
    /// ungrouped) — a partition comparison that ignores group UUIDs.
    private func coMemberships(
        _ records: [WorkoutRouteGroupAssignment]
    ) -> [UUID: Set<UUID>] {
        var membersByGroup: [UUID: Set<UUID>] = [:]
        for record in records {
            guard let groupID = record.groupID else { continue }
            membersByGroup[groupID, default: []].insert(record.workoutID)
        }
        var result: [UUID: Set<UUID>] = [:]
        for record in records {
            guard let groupID = record.groupID else {
                result[record.workoutID] = []
                continue
            }
            result[record.workoutID] = membersByGroup[groupID]?.subtracting([record.workoutID]) ?? []
        }
        return result
    }

    /// Effective representative workout per member workout.
    private func representativeByWorkout(
        _ records: [WorkoutRouteGroupAssignment],
        groups: [WorkoutRouteGroup]
    ) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for record in records {
            guard let groupID = record.groupID,
                  let group = groups.first(where: { $0.id == groupID }),
                  let representative = group.pinnedRepresentativeWorkoutID
                      ?? group.representativeSummary?.workoutID
            else { continue }
            result[record.workoutID] = representative
        }
        return result
    }

    // MARK: - Representative derivation

    func testRepresentativePrefersCleanestGPSThenDensestThenEarliest() async throws {
        // Same loop; the earliest run is clean, a later run carries a
        // discarded-point count, and a third is clean but sparser.
        let clean = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0, noiseMeters: 0)
        let noisyDate = RouteGroupingFixtures.epoch.addingTimeInterval(2 * 86_400)
        let noisy = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.seededNoise(
                on: RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: noisyDate),
                noiseMeters: 8,
                seed: 99
            ),
            date: noisyDate
        )
        // Simulate a route-quality penalty via the diagnostics field.
        let withDiscards = workoutWithDiscardedCoordinatePoints(noisy, discarded: 5)

        let result = try await service.assign(
            newWorkouts: [clean, withDiscards],
            existingGroups: [],
            policy: .default,
            representativeLoader: inMemoryLoader([clean, withDiscards])
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].representativeSummary?.workoutID, clean.id)
    }

    private func workoutWithDiscardedCoordinatePoints(
        _ workout: RunWorkout,
        discarded: Int
    ) -> RunWorkout {
        var copy = workout
        copy.qualityDiagnostics = RouteQualityDiagnostics(
            discardedCoordinatePointCount: discarded
        )
        return copy
    }

    // MARK: - Manual-state carry-over on re-cluster

    func testReclusterCarriesOverNameAndPin() async throws {
        let runs = (0..<2).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) }
        let initial = try service.recluster(workouts: runs, policy: .default)
        XCTAssertEqual(initial.groups.count, 1)

        var named = initial.groups[0]
        named.name = "Morning Loop"
        named.pinnedRepresentativeWorkoutID = runs[1].id

        let reclustered = try service.recluster(
            workouts: runs,
            previousGroups: [named],
            policy: .default
        )

        XCTAssertEqual(reclustered.groups.count, 1)
        XCTAssertEqual(reclustered.groups[0].name, "Morning Loop")
        XCTAssertEqual(reclustered.groups[0].pinnedRepresentativeWorkoutID, runs[1].id)
        XCTAssertEqual(reclustered.groups[0].representativeSummary?.workoutID, runs[1].id)
    }

    func testReclusterDropsPinWhenPinnedRunClustersElsewhere() async throws {
        let loopRun = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0)
        let farDate = RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        let farPoints = RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: farDate).map { point in
            RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + 30_000 / RouteGroupingFixtures.metersPerDegreeLatitude,
                longitude: point.longitude,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        let farRun = RouteGroupingFixtures.workout(points: farPoints, date: farDate)

        let previous = WorkoutRouteGroup(
            id: UUID(),
            name: "Renamed",
            pinnedRepresentativeWorkoutID: loopRun.id
        )

        let result = try service.recluster(
            workouts: [loopRun, farRun],
            previousGroups: [previous],
            policy: .default
        )

        // Two distinct routes; the pin referenced a workout that no longer
        // clusters with the named group's other members (there are none), so
        // the name follows the pinned run's group.
        let loopGroup = result.groups.first {
            result.assignments.first { $0.workoutID == loopRun.id }?.groupID == $0.id
        }
        XCTAssertEqual(loopGroup?.name, "Renamed")
        XCTAssertEqual(loopGroup?.pinnedRepresentativeWorkoutID, loopRun.id)
        XCTAssertEqual(loopGroup?.representativeSummary?.workoutID, loopRun.id)
    }

    // MARK: - Cancellation

    func testReclusterCancellationLeavesNoPartialOutput() async throws {
        let runs = (0..<20).map { RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: $0) }

        // Cancel after the first check, using a lock-based token so the
        // @Sendable closure stays Swift-6 clean.
        let token = CancelAfterFirstCallCheckToken()
        do {
            _ = try service.recluster(
                workouts: runs,
                policy: .default,
                isCancelled: { token.isCancelled }
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: the pass aborts rather than returning partial groups.
        }
    }
}

/// Thread-safe token that reports cancellation from the second call on.
private final class CancelAfterFirstCallCheckToken: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls > 1
    }
}
