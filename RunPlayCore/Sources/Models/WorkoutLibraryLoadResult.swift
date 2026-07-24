import Foundation

/// Organisation snapshot returned with a successful library load.
public struct WorkoutLibraryOrganizationSnapshot: Sendable, Equatable {
    public var tags: [WorkoutTag]
    public var tagAssignments: [WorkoutTagAssignment]
    public var smartCollections: [WorkoutSmartCollection]

    public init(
        tags: [WorkoutTag] = [],
        tagAssignments: [WorkoutTagAssignment] = [],
        smartCollections: [WorkoutSmartCollection] = []
    ) {
        self.tags = tags
        self.tagAssignments = tagAssignments
        self.smartCollections = smartCollections
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

    public var isEmpty: Bool {
        tags.isEmpty && tagAssignments.isEmpty && smartCollections.isEmpty
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
