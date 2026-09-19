import Foundation

/// Organisation snapshot returned with a successful library load.
public struct WorkoutLibraryOrganizationSnapshot: Sendable, Equatable {
    public var tags: [WorkoutTag]
    public var tagAssignments: [WorkoutTagAssignment]
    public var smartCollections: [WorkoutSmartCollection]
    public var routeGroups: [WorkoutRouteGroup]
    public var routeGroupAssignments: [WorkoutRouteGroupAssignment]

    public init(
        tags: [WorkoutTag] = [],
        tagAssignments: [WorkoutTagAssignment] = [],
        smartCollections: [WorkoutSmartCollection] = [],
        routeGroups: [WorkoutRouteGroup] = [],
        routeGroupAssignments: [WorkoutRouteGroupAssignment] = []
    ) {
        self.tags = tags
        self.tagAssignments = tagAssignments
        self.smartCollections = smartCollections
        self.routeGroups = routeGroups
        self.routeGroupAssignments = routeGroupAssignments
    }

    public static let empty = WorkoutLibraryOrganizationSnapshot()

    public var tagIDsByWorkout: [UUID: Set<UUID>] {
        var map: [UUID: Set<UUID>] = [:]
        for assignment in tagAssignments {
            map[assignment.workoutID] = assignment.tagIDSet
        }
        return map
    }

    public var tagsByID: [UUID: WorkoutTag] {
        Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
    }

    /// Group ID per evaluated workout; workouts with no record are absent
    /// (assignment pending) and a `nil` value means deliberately ungrouped.
    public var routeGroupIDByWorkout: [UUID: UUID?] {
        var map: [UUID: UUID?] = [:]
        map.reserveCapacity(routeGroupAssignments.count)
        for assignment in routeGroupAssignments {
            map[assignment.workoutID] = assignment.groupID
        }
        return map
    }

    public var routeGroupsByID: [UUID: WorkoutRouteGroup] {
        Dictionary(uniqueKeysWithValues: routeGroups.map { ($0.id, $0) })
    }

    public var isEmpty: Bool {
        tags.isEmpty && tagAssignments.isEmpty && smartCollections.isEmpty
            && routeGroups.isEmpty && routeGroupAssignments.isEmpty
    }
}

/// Result of reading the persisted workout library before UI state is applied.
public enum WorkoutLibraryLoadResult: Sendable {
    /// No usable persisted workouts. May still carry organisation from an empty
    /// library manifest (`manifestPresent`) so tags/collections survive.
    case demos(
        errorMessage: String?,
        organization: WorkoutLibraryOrganizationSnapshot = .empty,
        manifestPresent: Bool = false
    )
    /// A valid library was loaded (possibly empty after recovery of missing files).
    case workouts(
        [RunWorkout],
        selectedWorkoutID: UUID?,
        favoriteWorkoutIDs: Set<UUID>,
        organization: WorkoutLibraryOrganizationSnapshot,
        warning: String?
    )
}
