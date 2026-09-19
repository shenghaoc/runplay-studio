import Foundation
import RunPlayCore
import SwiftUI

/// One route-group row in the Routes list.
struct RouteGroupRow: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let runCount: Int
    let lastRunDate: Date?
    let bestPaceSecondsPerKilometer: Double?
    let medianPaceSecondsPerKilometer: Double?
    let latestPaceSecondsPerKilometer: Double?
    let representativeDistanceMeters: Double
    let userNamed: Bool
}

/// One member run of a route group (detail list).
struct RouteGroupMemberRow: Identifiable, Hashable {
    /// Workout ID.
    let id: UUID
    let workoutName: String
    let date: Date?
    let paceSecondsPerKilometer: Double?
    /// The run traverses the representative's route in the opposite
    /// direction (derived from start proximity to the representative's
    /// finish versus its start). A hilly loop reversed has a different pace
    /// profile, so the detail list marks it rather than leaving an
    /// unexplained chart outlier.
    let isReversed: Bool
    let isRepresentative: Bool
}

/// One point on the active-pace-over-date progression chart.
struct RouteGroupProgressionPoint: Identifiable, Hashable {
    /// Workout ID.
    let id: UUID
    let date: Date
    let paceSecondsPerKilometer: Double
}

/// View model for the Routes workspace: derived route-group rows, the
/// selected group's members and progression, and feature-local pass
/// progress. Task orchestration (incremental assignment, backfill,
/// re-cluster) lives in `AppState`, following the Personal Records split;
/// the library-wide route-groups revision bumps once per pass there.
@MainActor
final class RouteGroupsViewModel: ObservableObject {
    @Published private(set) var rows: [RouteGroupRow] = []
    @Published var selectedGroupID: UUID? {
        didSet {
            if oldValue != selectedGroupID {
                rebuildDetail()
            }
        }
    }
    @Published private(set) var memberRows: [RouteGroupMemberRow] = []
    @Published private(set) var progressionPoints: [RouteGroupProgressionPoint] = []
    @Published private(set) var representativeWorkoutID: UUID?
    @Published private(set) var pendingAssignmentCount = 0
    /// Reversal flags per member workout, computed off the main actor with
    /// the coarse direction probe. Closed loops need the sequence probe —
    /// their start and finish coincide, so endpoint proximity cannot
    /// distinguish direction.
    @Published private(set) var reversalFlags: [UUID: Bool] = [:]

    // Feature-local pass progress. Never a library-wide invalidation token.
    @Published private(set) var isAssigning = false
    @Published private(set) var assignmentCurrentName = ""
    @Published private(set) var isReclustering = false
    @Published private(set) var reclusterCompletedCount = 0
    @Published private(set) var reclusterTotalCount = 0
    @Published private(set) var reclusterCurrentName = ""
    @Published private(set) var lastReclusterSummary: String?

    /// Start-to-finish distance under which the representative counts as a
    /// loop for the derived default name.
    static let loopClosureDistanceMeters: Double = 100

    private var workouts: [RunWorkout] = []
    private var workoutsByID: [UUID: RunWorkout] = [:]
    private var groups: [WorkoutRouteGroup] = []
    private var assignments: [WorkoutRouteGroupAssignment] = []
    private var assignmentByWorkout: [UUID: WorkoutRouteGroupAssignment] = [:]
    /// Cache key guarding the async reversal pass.
    private var reversalCacheKey: String?
    private var reversalTask: Task<Void, Never>?

    init() {}

    deinit {
        reversalTask?.cancel()
    }

    /// Re-derive every row (and the selected detail) from the current
    /// library and organization state.
    func refresh(
        workouts: [RunWorkout],
        organization: WorkoutLibraryOrganizationSnapshot
    ) {
        self.workouts = workouts
        self.workoutsByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.id, $0) })
        self.groups = organization.routeGroups
        self.assignments = organization.routeGroupAssignments
        var indexed: [UUID: WorkoutRouteGroupAssignment] = [:]
        indexed.reserveCapacity(organization.routeGroupAssignments.count)
        for assignment in organization.routeGroupAssignments {
            indexed[assignment.workoutID] = assignment
        }
        assignmentByWorkout = indexed
        pendingAssignmentCount = workouts.filter { indexed[$0.id] == nil }.count

        rebuildRows()
        rebuildDetail()
    }

    // MARK: - Row derivation

    private func rebuildRows() {
        let memberIDsByGroup: [UUID: [UUID]] = {
            var map: [UUID: [UUID]] = [:]
            for assignment in assignments {
                guard let groupID = assignment.groupID else { continue }
                map[groupID, default: []].append(assignment.workoutID)
            }
            return map
        }()

        var built: [RouteGroupRow] = []
        built.reserveCapacity(groups.count)
        for group in groups {
            let memberIDs = memberIDsByGroup[group.id] ?? []
            let members = memberIDs.compactMap { workoutsByID[$0] }
            let representativeID = effectiveRepresentativeID(for: group, memberIDs: memberIDs)
            let representative = representativeID.flatMap { workoutsByID[$0] }
            let paces = members.compactMap { entry -> Double? in
                let pace = entry.summary.averagePaceSecondsPerKilometer
                return pace.isFinite && pace > 0 ? pace : nil
            }
            let dates = members.compactMap { WorkoutLibraryEntry.canonicalStartDate(for: $0) }
            let displayName: String
            if let name = group.name, !name.isEmpty {
                displayName = name
            } else if let representative {
                displayName = WorkoutRouteGroup.defaultDisplayName(
                    distanceMeters: representative.summary.totalDistanceMeters,
                    closesLoop: Self.representativeClosesLoop(representative)
                )
            } else {
                displayName = String(localized: "route_group.unnamed", defaultValue: "Route")
            }
            built.append(RouteGroupRow(
                id: group.id,
                displayName: displayName,
                runCount: members.count,
                lastRunDate: dates.max(),
                bestPaceSecondsPerKilometer: paces.min(),
                medianPaceSecondsPerKilometer: Self.median(of: paces),
                latestPaceSecondsPerKilometer: Self.latestPace(members),
                representativeDistanceMeters: representative?.summary.totalDistanceMeters ?? 0,
                userNamed: !(group.name ?? "").isEmpty
            ))
        }

        // Most-run routes first, then most recently run, then stable id.
        built.sort { lhs, rhs in
            if lhs.runCount != rhs.runCount {
                return lhs.runCount > rhs.runCount
            }
            if lhs.lastRunDate != rhs.lastRunDate {
                return (lhs.lastRunDate ?? .distantPast) > (rhs.lastRunDate ?? .distantPast)
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        rows = built

        if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = nil
        }
    }

    private func rebuildDetail() {
        guard let groupID = selectedGroupID,
              let group = groups.first(where: { $0.id == groupID })
        else {
            memberRows = []
            progressionPoints = []
            representativeWorkoutID = nil
            return
        }

        let memberIDs = assignments.compactMap { assignment -> UUID? in
            assignment.groupID == groupID ? assignment.workoutID : nil
        }
        let representativeID = effectiveRepresentativeID(for: group, memberIDs: memberIDs)

        var members: [RouteGroupMemberRow] = []
        var progression: [RouteGroupProgressionPoint] = []
        members.reserveCapacity(memberIDs.count)
        for workoutID in memberIDs {
            guard let workout = workoutsByID[workoutID] else { continue }
            let pace = workout.summary.averagePaceSecondsPerKilometer
            let validPace = pace.isFinite && pace > 0 ? pace : nil
            members.append(RouteGroupMemberRow(
                id: workoutID,
                workoutName: workout.displayName,
                date: WorkoutLibraryEntry.canonicalStartDate(for: workout),
                paceSecondsPerKilometer: validPace,
                isReversed: reversalFlags[workoutID] ?? false,
                isRepresentative: workoutID == representativeID
            ))
            if let validPace, let date = WorkoutLibraryEntry.canonicalStartDate(for: workout) {
                progression.append(RouteGroupProgressionPoint(
                    id: workoutID,
                    date: date,
                    paceSecondsPerKilometer: validPace
                ))
            }
        }

        // Members newest first; chart points ascend by date.
        members.sort { lhs, rhs in
            let lhsDate = lhs.date ?? .distantPast
            let rhsDate = rhs.date ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        progression.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        memberRows = members
        progressionPoints = progression
        representativeWorkoutID = representativeID
        refreshReversalFlags(
            groupID: groupID,
            representativeID: representativeID,
            memberIDs: memberIDs.filter { workoutsByID[$0] != nil }
        )
    }

    /// Computes member reversal flags off the main actor. Results publish
    /// once for the whole group; the cache key covers membership and
    /// representative identity so pinning a representative recomputes.
    private func refreshReversalFlags(
        groupID: UUID,
        representativeID: UUID?,
        memberIDs: [UUID]
    ) {
        guard let representativeID,
              let representative = workoutsByID[representativeID]
        else {
            reversalFlags = [:]
            return
        }
        let key = [
            groupID.uuidString,
            representativeID.uuidString,
            "\(memberIDs.count)"
        ].joined(separator: "|") + "|" + memberIDs.map { $0.uuidString }.sorted().prefix(64).joined(separator: ",")
        if key == reversalCacheKey {
            return
        }
        reversalCacheKey = key
        let members = memberIDs.compactMap { workoutsByID[$0] }
        let flags = reversalFlags
        reversalTask?.cancel()
        reversalTask = Task { [weak self] in
            var computed: [UUID: Bool] = [:]
            for member in members {
                if Task.isCancelled { return }
                computed[member.id] = RouteGroupingMatcher.memberRunsOppositeDirection(
                    member: member,
                    representative: representative
                )
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.mergeReversalFlags(computed, into: flags, key: key)
            }
        }
    }

    private func mergeReversalFlags(
        _ computed: [UUID: Bool],
        into previous: [UUID: Bool],
        key: String
    ) {
        guard key == reversalCacheKey else { return }
        var merged = computed
        for (id, value) in previous where merged[id] == nil {
            merged[id] = value
        }
        reversalFlags = merged
        // Re-apply the freshly computed flags onto the member rows.
        if memberRows.isEmpty { return }
        memberRows = memberRows.map { row in
            RouteGroupMemberRow(
                id: row.id,
                workoutName: row.workoutName,
                date: row.date,
                paceSecondsPerKilometer: row.paceSecondsPerKilometer,
                isReversed: reversalFlags[row.id] ?? false,
                isRepresentative: row.isRepresentative
            )
        }
    }

    /// The pinned representative when it is still a member, else the cached
    /// derived summary, else the first member.
    private func effectiveRepresentativeID(
        for group: WorkoutRouteGroup,
        memberIDs: [UUID]
    ) -> UUID? {
        if let pinned = group.pinnedRepresentativeWorkoutID,
           memberIDs.contains(pinned) {
            return pinned
        }
        if let summary = group.representativeSummary,
           memberIDs.contains(summary.workoutID) {
            return summary.workoutID
        }
        return memberIDs.first
    }

    /// The workout backing the selected group's representative map overlay.
    func representativeWorkout(for groupID: UUID) -> RunWorkout? {
        guard let group = groups.first(where: { $0.id == groupID }) else { return nil }
        let memberIDs = assignments.compactMap { $0.groupID == groupID ? $0.workoutID : nil }
        guard let id = effectiveRepresentativeID(for: group, memberIDs: memberIDs) else {
            return nil
        }
        return workoutsByID[id]
    }

    // MARK: - Pass progress (feature-local)

    func assignmentStarted() {
        isAssigning = true
    }

    func assignmentProgress(currentWorkoutName: String) {
        assignmentCurrentName = currentWorkoutName
    }

    func assignmentFinished() {
        isAssigning = false
        assignmentCurrentName = ""
    }

    func reclusterStarted(totalCount: Int) {
        isReclustering = true
        reclusterCompletedCount = 0
        reclusterTotalCount = totalCount
        reclusterCurrentName = ""
    }

    func reclusterProgress(
        completedCount: Int,
        totalCount: Int,
        currentWorkoutName: String
    ) {
        reclusterCompletedCount = completedCount
        reclusterTotalCount = totalCount
        reclusterCurrentName = currentWorkoutName
    }

    func reclusterFinished(summary: String?) {
        isReclustering = false
        reclusterCurrentName = ""
        lastReclusterSummary = summary
    }

    // MARK: - Geometry helpers

    /// Whether the representative starts and finishes within the loop
    /// closure distance — the derived name says "Loop" instead of "Route".
    static func representativeClosesLoop(_ representative: RunWorkout) -> Bool {
        let points = representative.routePoints
        guard let start = points.first(where: { Self.isValid($0) }),
              let finish = points.last(where: { Self.isValid($0) })
        else {
            return false
        }
        let separation = GeoDistance.distanceMeters(
            fromLat: start.latitude,
            lon: start.longitude,
            toLat: finish.latitude,
            lon: finish.longitude
        )
        return separation <= loopClosureDistanceMeters
    }

    private static func isValid(_ point: RoutePoint) -> Bool {
        GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude)
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func latestPace(_ members: [RunWorkout]) -> Double? {
        let dated = members.compactMap { workout -> (Date, Double)? in
            let pace = workout.summary.averagePaceSecondsPerKilometer
            guard pace.isFinite, pace > 0,
                  let date = WorkoutLibraryEntry.canonicalStartDate(for: workout)
            else { return nil }
            return (date, pace)
        }
        return dated.max { $0.0 < $1.0 }?.1
    }
}
