import Foundation

/// Pass orchestration for automatic route grouping.
///
/// The service is pure and store-free: callers supply loaded workouts (and,
/// for incremental passes, a loader for existing group representatives) and
/// receive manifest-level values. Persistence, revision discipline, and
/// progress UI belong to `WorkoutLibraryStoreActor` and the Studio view
/// model.
///
/// One greedy rule governs both entry points so results stay consistent: a
/// workout is matched against existing groups' effective representatives
/// only — never against every member — and joins the best-scoring match.
/// Because the effective representative is a pure function of the member set
/// (highest route quality, earliest canonical date tiebreak, user pin
/// override), a chronologically imported library incremental-assigns into
/// exactly the groups a full re-cluster produces.
public struct RouteGroupingService: Sendable {
    private let matcher: RouteGroupingMatcher

    public init(matcher: RouteGroupingMatcher = RouteGroupingMatcher()) {
        self.matcher = matcher
    }

    /// Result of one incremental assignment pass.
    public struct AssignmentResult: Sendable, Equatable {
        /// Complete updated group list (existing groups with refreshed
        /// summaries plus any newly created groups).
        public var groups: [WorkoutRouteGroup]
        /// Assignment records for the new workouts only.
        public var assignments: [WorkoutRouteGroupAssignment]
        /// How many new workouts joined an existing group.
        public var joinedCount: Int
        /// How many new workouts founded a new (initially singleton) group.
        public var createdCount: Int

        public init(
            groups: [WorkoutRouteGroup],
            assignments: [WorkoutRouteGroupAssignment],
            joinedCount: Int,
            createdCount: Int
        ) {
            self.groups = groups
            self.assignments = assignments
            self.joinedCount = joinedCount
            self.createdCount = createdCount
        }
    }

    /// Result of one full re-cluster pass.
    public struct ReclusterResult: Sendable, Equatable {
        public var groups: [WorkoutRouteGroup]
        /// Assignment records for every library workout.
        public var assignments: [WorkoutRouteGroupAssignment]

        public init(
            groups: [WorkoutRouteGroup],
            assignments: [WorkoutRouteGroupAssignment]
        ) {
            self.groups = groups
            self.assignments = assignments
        }
    }

    /// One in-memory group under construction during a pass.
    private struct WorkingGroup {
        var group: WorkoutRouteGroup
        /// Effective representative identity + facts. Always populated by
        /// the pass; the derived-rule override (pin) is applied when the
        /// manifest value is materialized.
        var representativeSummary: WorkoutRouteGroupSummary
        /// The representative snapshot itself. Re-cluster holds the whole
        /// library in memory and keeps this current; incremental passes
        /// leave it `nil` and load on demand instead.
        var representativeWorkout: RunWorkout?
        /// Whether the user pinned this group's representative (pin survives
        /// re-cluster only when the pinned workout still lands here).
        var isPinned: Bool
    }

    // MARK: - Incremental assignment

    /// Assigns newly imported workouts to existing route groups.
    ///
    /// New workouts are processed in canonical start-date order (UUID
    /// tiebreak) so a batch import behaves like the same imports arriving
    /// one by one. Each is matched only against groups whose persisted
    /// representative summary passes the stage-1 filter; the representative
    /// snapshot for a surviving candidate comes from `representativeLoader`,
    /// which may return `nil` (unreadable snapshot) and simply removes that
    /// group from consideration. A workout matching nothing founds a new
    /// singleton group — every participating run is discoverable as a
    /// representative, which is what keeps incremental assignment and a full
    /// re-cluster equivalent.
    public func assign(
        newWorkouts: [RunWorkout],
        existingGroups: [WorkoutRouteGroup],
        policy: RouteGroupingPolicy,
        progress: (@Sendable (RouteGroupingPassProgress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        representativeLoader: @Sendable (UUID) async throws -> RunWorkout?
    ) async throws -> AssignmentResult {
        let ordered = Self.chronologicallyOrdered(newWorkouts)
        var working: [WorkingGroup] = existingGroups.map { group in
            // A group whose representative summary is missing cannot be
            // matched; it still carries its members and survives the pass.
            let summary = group.representativeSummary
                ?? WorkoutRouteGroupSummary(
                    workoutID: group.pinnedRepresentativeWorkoutID ?? UUID(),
                    startDate: nil,
                    facts: RouteGroupingRouteFacts(
                        minLatitude: 0, maxLatitude: 0,
                        minLongitude: 0, maxLongitude: 0,
                        startLatitude: 0, startLongitude: 0,
                        finishLatitude: 0, finishLongitude: 0,
                        totalDistanceMeters: 0,
                        routePointCount: 0,
                        discardedCoordinatePointCount: 0
                    )
                )
            return WorkingGroup(
                group: group,
                representativeSummary: summary,
                representativeWorkout: nil,
                isPinned: group.pinnedRepresentativeWorkoutID != nil
            )
        }

        var assignments: [WorkoutRouteGroupAssignment] = []
        assignments.reserveCapacity(ordered.count)
        var joined = 0
        var created = 0

        for (index, workout) in ordered.enumerated() {
            if isCancelled() {
                throw CancellationError()
            }
            progress?(RouteGroupingPassProgress(
                completedCount: index,
                totalCount: ordered.count,
                currentWorkoutName: workout.displayName
            ))

            let facts = RouteGroupingRouteFacts(workout: workout)
            let date = WorkoutLibraryEntry.canonicalStartDate(for: workout)

            guard facts.canParticipate(policy: policy) else {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: nil,
                    algorithmVersion: policy.algorithmVersion
                ))
                continue
            }

            // Stage 1 over representative summaries, then stage 2 against
            // loaded representative snapshots. Candidates are evaluated in a
            // deterministic order and the best-scoring match wins.
            var best: (index: Int, outcome: RouteGroupingMatchOutcome)?
            for groupIndex in working.indices {
                guard RouteGroupCandidateFilter.isCandidate(
                    facts,
                    working[groupIndex].representativeSummary.facts,
                    policy: policy
                ) else {
                    continue
                }
                let representativeID = working[groupIndex].representativeSummary.workoutID
                guard let representative = try await representativeLoader(representativeID) else {
                    continue
                }
                let outcome = try matcher.match(
                    workout: workout,
                    workoutFacts: facts,
                    representative: representative,
                    representativeFacts: working[groupIndex].representativeSummary.facts,
                    policy: policy,
                    isCancelled: isCancelled
                )
                guard outcome.matches else { continue }
                if let current = best {
                    if outcome.similarityScore > current.outcome.similarityScore {
                        best = (groupIndex, outcome)
                    }
                } else {
                    best = (groupIndex, outcome)
                }
            }

            if let best {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: working[best.index].group.id,
                    algorithmVersion: policy.algorithmVersion
                ))
                joined += 1
                // The effective representative only changes on an unpinned
                // group when the joiner outranks it.
                if !working[best.index].isPinned {
                    let joinerSummary = WorkoutRouteGroupSummary(
                        workoutID: workout.id,
                        startDate: date,
                        facts: facts
                    )
                    if joinerSummary.ranksAbove(working[best.index].representativeSummary) {
                        working[best.index].representativeSummary = joinerSummary
                    }
                }
            } else {
                let group = WorkoutRouteGroup(
                    id: UUID(),
                    name: nil,
                    pinnedRepresentativeWorkoutID: nil,
                    representativeSummary: nil
                )
                working.append(WorkingGroup(
                    group: group,
                    representativeSummary: WorkoutRouteGroupSummary(
                        workoutID: workout.id,
                        startDate: date,
                        facts: facts
                    ),
                    isPinned: false
                ))
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: group.id,
                    algorithmVersion: policy.algorithmVersion
                ))
                created += 1
            }
        }

        progress?(RouteGroupingPassProgress(
            completedCount: ordered.count,
            totalCount: ordered.count,
            currentWorkoutName: ordered.last?.displayName ?? ""
        ))

        let groups = working.map { entry in
            var group = entry.group
            group.representativeSummary = entry.representativeSummary
            return group
        }

        return AssignmentResult(
            groups: groups,
            assignments: assignments,
            joinedCount: joined,
            createdCount: created
        )
    }

    // MARK: - Full re-cluster

    /// Recomputes every group from scratch over the whole library.
    ///
    /// Workouts are processed in canonical start-date order against current
    /// effective representatives — the same greedy rule as incremental
    /// assignment, replayed from an empty state. User names and pinned
    /// representatives carry over when the referenced workout still clusters
    /// into a group; every other decision (including deliberate removals) is
    /// recomputed.
    public func recluster(
        workouts: [RunWorkout],
        previousGroups: [WorkoutRouteGroup] = [],
        policy: RouteGroupingPolicy,
        progress: (@Sendable (RouteGroupingPassProgress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ReclusterResult {
        let ordered = Self.chronologicallyOrdered(workouts)
        var working: [WorkingGroup] = []
        var assignments: [WorkoutRouteGroupAssignment] = []
        assignments.reserveCapacity(ordered.count)

        for (index, workout) in ordered.enumerated() {
            if isCancelled() {
                throw CancellationError()
            }
            progress?(RouteGroupingPassProgress(
                completedCount: index,
                totalCount: ordered.count,
                currentWorkoutName: workout.displayName
            ))

            let facts = RouteGroupingRouteFacts(workout: workout)
            let date = WorkoutLibraryEntry.canonicalStartDate(for: workout)

            guard facts.canParticipate(policy: policy) else {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: nil,
                    algorithmVersion: policy.algorithmVersion
                ))
                continue
            }

            var best: (index: Int, outcome: RouteGroupingMatchOutcome)?
            for groupIndex in working.indices {
                guard let representative = working[groupIndex].representativeWorkout else {
                    continue
                }
                let outcome = try matcher.match(
                    workout: workout,
                    workoutFacts: facts,
                    representative: representative,
                    representativeFacts: working[groupIndex].representativeSummary.facts,
                    policy: policy,
                    isCancelled: isCancelled
                )
                guard outcome.matches else { continue }
                if let current = best {
                    if outcome.similarityScore > current.outcome.similarityScore {
                        best = (groupIndex, outcome)
                    }
                } else {
                    best = (groupIndex, outcome)
                }
            }

            if let best {
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: working[best.index].group.id,
                    algorithmVersion: policy.algorithmVersion
                ))
                let joinerSummary = WorkoutRouteGroupSummary(
                    workoutID: workout.id,
                    startDate: date,
                    facts: facts
                )
                if joinerSummary.ranksAbove(working[best.index].representativeSummary) {
                    working[best.index].representativeSummary = joinerSummary
                    working[best.index].representativeWorkout = workout
                }
            } else {
                working.append(WorkingGroup(
                    group: WorkoutRouteGroup(),
                    representativeSummary: WorkoutRouteGroupSummary(
                        workoutID: workout.id,
                        startDate: date,
                        facts: facts
                    ),
                    representativeWorkout: workout,
                    isPinned: false
                ))
                assignments.append(WorkoutRouteGroupAssignment(
                    workoutID: workout.id,
                    groupID: working[working.count - 1].group.id,
                    algorithmVersion: policy.algorithmVersion
                ))
            }
        }

        progress?(RouteGroupingPassProgress(
            completedCount: ordered.count,
            totalCount: ordered.count,
            currentWorkoutName: ordered.last?.displayName ?? ""
        ))

        var groups = working.map { entry -> WorkoutRouteGroup in
            var group = entry.group
            group.representativeSummary = entry.representativeSummary
            return group
        }
        Self.carryOverManualState(
            from: previousGroups,
            into: &groups,
            assignments: assignments,
            workoutsByID: Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        )

        return ReclusterResult(groups: groups, assignments: assignments)
    }

    // MARK: - Shared helpers

    private static func chronologicallyOrdered(_ workouts: [RunWorkout]) -> [RunWorkout] {
        workouts
            .filter { WorkoutLibraryEntry.canonicalStartDate(for: $0) != nil }
            .sorted { lhs, rhs in
                let lhsDate = WorkoutLibraryEntry.canonicalStartDate(for: lhs) ?? .distantPast
                let rhsDate = WorkoutLibraryEntry.canonicalStartDate(for: rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Transfers user names and pinned representatives from the previous
    /// groups into the recomputed ones. A manual value survives when the
    /// referenced workout (pin) or the previous effective representative
    /// (name) still clusters into one new group, and each new group accepts
    /// at most one transfer. Deterministic: previous groups in stable id
    /// order.
    private static func carryOverManualState(
        from previousGroups: [WorkoutRouteGroup],
        into groups: inout [WorkoutRouteGroup],
        assignments: [WorkoutRouteGroupAssignment],
        workoutsByID: [UUID: RunWorkout]
    ) {
        guard !previousGroups.isEmpty else { return }
        let groupIDByWorkout: [UUID: UUID] = {
            var map: [UUID: UUID] = [:]
            for assignment in assignments {
                if let groupID = assignment.groupID {
                    map[assignment.workoutID] = groupID
                }
            }
            return map
        }()

        let orderedPrevious = previousGroups.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var claimedNewGroupIDs = Set<UUID>()

        for previous in orderedPrevious {
            let referenceID = previous.pinnedRepresentativeWorkoutID
                ?? previous.representativeSummary?.workoutID
            guard let referenceID,
                  let newGroupID = groupIDByWorkout[referenceID],
                  !claimedNewGroupIDs.contains(newGroupID),
                  let newIndex = groups.firstIndex(where: { $0.id == newGroupID })
            else {
                continue
            }
            claimedNewGroupIDs.insert(newGroupID)
            if let name = previous.name {
                groups[newIndex].name = name
            }
            if let pinned = previous.pinnedRepresentativeWorkoutID,
               let pinnedWorkout = workoutsByID[pinned],
               groupIDByWorkout[pinned] == newGroupID {
                groups[newIndex].pinnedRepresentativeWorkoutID = pinned
                groups[newIndex].representativeSummary = WorkoutRouteGroupSummary(
                    workoutID: pinned,
                    startDate: WorkoutLibraryEntry.canonicalStartDate(for: pinnedWorkout),
                    facts: RouteGroupingRouteFacts(workout: pinnedWorkout)
                )
            }
        }
    }
}
