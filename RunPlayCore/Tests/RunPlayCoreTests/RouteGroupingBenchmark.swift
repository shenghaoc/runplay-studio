import XCTest
@testable import RunPlayCore

/// Release-only benchmark comparing stage-1 candidate filtering against
/// brute-force all-pairs matching on a 2,000-workout synthetic library.
///
/// Three arms over the same library:
/// - **production**: the real `RouteGroupingService.recluster` pass.
/// - **filtered**: an instrumented greedy replay of the same rule that
///   counts stage-1 evaluations and stage-2 solves.
/// - **brute force**: the same greedy replay with stage 1 disabled (every
///   pair reaches the DTW solve).
///
/// The filtered and brute-force partitions must be identical: the candidate
/// filter may only remove pairs stage 2 would reject anyway.
///
/// Run via `scripts/run-route-grouping-benchmark.sh` (env-gated; never in CI).
final class RouteGroupingBenchmark: XCTestCase {
    private static let routeFamilyCount = 160
    private static let repeatsPerFamily = 12
    private static let uniqueRouteCount = 80
    private static var librarySize: Int {
        routeFamilyCount * repeatsPerFamily + uniqueRouteCount
    }

    func testCandidateFilterVersusBruteForce() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_ROUTE_GROUPING_BENCHMARK"] == "1",
            "Set RUNPLAY_ROUTE_GROUPING_BENCHMARK=1 to run the route-grouping benchmark"
        )

        let workouts = Self.makeLibrary()
        XCTAssertEqual(workouts.count, Self.librarySize)
        let matcher = RouteGroupingMatcher()

        print("BEGIN RUNPLAY ROUTE GROUPING BENCHMARK")
        print("library: \(workouts.count) workouts, \(Self.routeFamilyCount) repeated routes x \(Self.repeatsPerFamily) runs, \(Self.uniqueRouteCount) unique runs")

        // Production pass.
        let service = RouteGroupingService(matcher: matcher)
        let productionStart = ContinuousClock.now
        let production = try service.recluster(workouts: workouts, policy: .default)
        let productionNanos = ContinuousClock.now - productionStart
        print("production recluster: \(Self.milliseconds(from: productionNanos)) ms, \(production.groups.count) groups")

        // Instrumented filtered replay.
        let filteredStart = ContinuousClock.now
        let filtered = try greedyCluster(
            workouts: workouts,
            matcher: matcher,
            stage1Enabled: true
        )
        let filteredNanos = ContinuousClock.now - filteredStart
        print("filtered: \(Self.milliseconds(from: filteredNanos)) ms, \(filtered.groups.count) groups, stage1-evals \(filtered.stage1Evaluations), stage2-solves \(filtered.stage2Solves)")

        // Brute force: stage 1 admits everything, so every (workout, group)
        // pair reaches the DTW solve.
        let bruteStart = ContinuousClock.now
        let brute = try greedyCluster(
            workouts: workouts,
            matcher: matcher,
            stage1Enabled: false
        )
        let bruteNanos = ContinuousClock.now - bruteStart
        print("brute force: \(Self.milliseconds(from: bruteNanos)) ms, \(brute.groups.count) groups, stage2-solves \(brute.stage2Solves)")

        // Parity: the candidate filter never removes a pair stage 2 accepts.
        XCTAssertEqual(
            partitionSignature(filtered.assignments),
            partitionSignature(brute.assignments),
            "candidate filtering must not change the resulting groups"
        )
        XCTAssertEqual(production.groups.count, filtered.groups.count)

        let savedSolves = brute.stage2Solves - filtered.stage2Solves
        let ratio = filtered.stage2Solves > 0
            ? Double(brute.stage2Solves) / Double(filtered.stage2Solves)
            : 1
        print("merge gate: brute-force/filtered stage-2 solve ratio \(String(format: "%.1fx", ratio)) (\(savedSolves) solves avoided)")
        if let peak = Self.peakResidentMemoryBytes() {
            print("peak RSS: \(peak / 1_024) KiB")
        }
        print("END RUNPLAY ROUTE GROUPING BENCHMARK")    }

    // MARK: - Instrumented greedy replay

    private struct ClusterRun {
        var groups: [UUID: [UUID]]
        var assignments: [WorkoutRouteGroupAssignment]
        var stage1Evaluations = 0
        var stage2Solves = 0
    }

    /// The service's greedy rule, replayed with counters. When
    /// `stage1Enabled` is false, the candidate filter is neutralized by a
    /// wide-open policy so every pair reaches stage 2.
    private func greedyCluster(
        workouts: [RunWorkout],
        matcher: RouteGroupingMatcher,
        stage1Enabled: Bool
    ) throws -> ClusterRun {
        let ordered = workouts.sorted {
            let lhs = WorkoutLibraryEntry.canonicalStartDate(for: $0) ?? .distantPast
            let rhs = WorkoutLibraryEntry.canonicalStartDate(for: $1) ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }
        let orderedByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        let filterPolicy = stage1Enabled
            ? RouteGroupingPolicy.default
            : RouteGroupingPolicy(
                boundingBoxOverlapMarginMeters: 1e9,
                endpointProximityMeters: 1e9
            )

        var summaries: [WorkoutRouteGroupSummary] = []
        var groupIDs: [UUID] = []
        var members: [UUID: [UUID]] = [:]
        var assignments: [WorkoutRouteGroupAssignment] = []
        var stage1Evaluations = 0
        var stage2Solves = 0

        for workout in ordered {
            let facts = RouteGroupingRouteFacts(workout: workout)
            guard facts.canParticipate(policy: .default) else {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id, groupID: nil, algorithmVersion: 1
                ))
                continue
            }
            let date = WorkoutLibraryEntry.canonicalStartDate(for: workout)

            var best: (index: Int, score: Double)?
            for index in summaries.indices {
                stage1Evaluations += 1
                if stage1Enabled,
                   !RouteGroupCandidateFilter.isCandidate(
                       facts,
                       summaries[index].facts,
                       policy: filterPolicy
                   ) {
                    continue
                }
                stage2Solves += 1
                let outcome = try matcher.match(
                    workout: workout,
                    workoutFacts: facts,
                    representative: orderedByID[summaries[index].workoutID]!,
                    representativeFacts: summaries[index].facts,
                    policy: .default,
                    isCancelled: { false }
                )
                guard outcome.matches else { continue }
                if best == nil || outcome.similarityScore > best!.score {
                    best = (index, outcome.similarityScore)
                }
            }

            if let best {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id, groupID: groupIDs[best.index], algorithmVersion: 1
                ))
                members[groupIDs[best.index]]?.append(workout.id)
                let joiner = WorkoutRouteGroupSummary(workoutID: workout.id, startDate: date, facts: facts)
                if joiner.ranksAbove(summaries[best.index]) {
                    summaries[best.index] = joiner
                }
            } else {
                let groupID = UUID()
                groupIDs.append(groupID)
                summaries.append(WorkoutRouteGroupSummary(workoutID: workout.id, startDate: date, facts: facts))
                members[groupID] = [workout.id]
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id, groupID: groupID, algorithmVersion: 1
                ))
            }
        }

        return ClusterRun(
            groups: members,
            assignments: assignments,
            stage1Evaluations: stage1Evaluations,
            stage2Solves: stage2Solves
        )
    }

    /// Partition signature that ignores group UUIDs.
    private func partitionSignature(_ assignments: [WorkoutRouteGroupAssignment]) -> [UUID: [UUID]] {
        var membersByGroup: [UUID: [UUID]] = [:]
        for assignment in assignments {
            if let groupID = assignment.groupID {
                membersByGroup[groupID, default: []].append(assignment.workoutID)
            }
        }
        var signature: [UUID: [UUID]] = [:]
        for assignment in assignments {
            guard let groupID = assignment.groupID else {
                signature[assignment.workoutID] = []
                continue
            }
            signature[assignment.workoutID] = (membersByGroup[groupID] ?? [])
                .sorted { $0.uuidString < $1.uuidString }
        }
        return signature
    }

    // MARK: - Library construction

    /// Route families are spatially separated by latitude; every repeat
    /// carries seeded GPS jitter so stage 2 does real work.
    private static func makeLibrary() -> [RunWorkout] {
        var workouts: [RunWorkout] = []
        workouts.reserveCapacity(librarySize)
        var familyIndex = 0
        for _ in 0..<routeFamilyCount {
            let latitudeOffset = Double(familyIndex) * 0.06
            let side = 900.0 + Double(familyIndex % 7) * 150
            for repeatIndex in 0..<repeatsPerFamily {
                let date = RouteGroupingFixtures.epoch
                    .addingTimeInterval(Double(repeatIndex) * 86_400)
                let clean = RouteGroupingFixtures.squareLoop(
                    sideMeters: side,
                    stepMeters: 25,
                    date: date
                )
                let jittered = clean.map { point in
                    RoutePoint(
                        timestamp: point.timestamp,
                        latitude: point.latitude + latitudeOffset,
                        longitude: point.longitude,
                        distanceFromStartMeters: point.distanceFromStartMeters,
                        elapsedSeconds: point.elapsedSeconds,
                        paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                        routeSegmentIndex: point.routeSegmentIndex
                    )
                }
                workouts.append(RouteGroupingFixtures.workout(
                    points: RouteGroupingFixtures.seededNoise(
                        on: jittered,
                        noiseMeters: 10,
                        seed: UInt64(100_000 + familyIndex * 32 + repeatIndex)
                    ),
                    date: date
                ))
            }
            familyIndex += 1
        }
        for uniqueIndex in 0..<uniqueRouteCount {
            let date = RouteGroupingFixtures.epoch
                .addingTimeInterval(Double(3_650 + uniqueIndex) * 86_400)
            let clean = RouteGroupingFixtures.straightLine(
                distanceMeters: 2_000 + Double(uniqueIndex % 11) * 300,
                stepMeters: 25,
                date: date
            )
            let eastOffsetDegrees = Double(uniqueIndex) * 400 / RouteGroupingFixtures.metersPerDegreeLongitude
            let shifted = clean.map { point in
                RoutePoint(
                    timestamp: point.timestamp,
                    latitude: point.latitude,
                    longitude: point.longitude + eastOffsetDegrees,
                    distanceFromStartMeters: point.distanceFromStartMeters,
                    elapsedSeconds: point.elapsedSeconds,
                    paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                    routeSegmentIndex: point.routeSegmentIndex
                )
            }
            workouts.append(RouteGroupingFixtures.workout(points: shifted, date: date))
        }
        return workouts
    }

    // MARK: - Helpers

    private static func milliseconds(from duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }

    private static func peakResidentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
        #else
        // Linux equivalent: peak resident set size (VmHWM) from procfs.
        guard
            let status = try? String(
                contentsOfFile: "/proc/self/status",
                encoding: String.Encoding.utf8
            ),
            let line = status
                .components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("VmHWM:") })
        else { return nil }
        let parts = line.dropFirst("VmHWM:".count)
            .split(separator: " ")
            .filter { !$0.isEmpty }
        guard let kib = parts.first.flatMap({ UInt64($0) }) else { return nil }
        return kib * 1_024
        #endif
    }
}
