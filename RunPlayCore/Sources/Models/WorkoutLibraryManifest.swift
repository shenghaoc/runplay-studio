import Foundation

/// Versioned manifest for the workout library.
///
/// Schema version 1 tracked ordered workout IDs and selection.
/// Schema version 2 adds a local favourite set without rewriting workout
/// snapshots or changing analysis / normalization versions.
public struct WorkoutLibraryManifest: Codable, Equatable, Sendable {
    /// Current schema version. Bump when the on-disk format changes.
    public static let currentVersion = 2

    /// Oldest schema version this binary can decode and migrate.
    public static let minimumSupportedVersion = 1

    /// Schema version of this manifest.
    public var version: Int

    /// Ordered workout IDs (defines library / sidebar display order).
    public var workoutIDs: [UUID]

    /// Last-selected workout ID, if any.
    public var selectedWorkoutID: UUID?

    /// Local favourite markers. Only IDs present in `workoutIDs` are meaningful.
    public var favoriteWorkoutIDs: Set<UUID>

    public init(
        version: Int = WorkoutLibraryManifest.currentVersion,
        workoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil,
        favoriteWorkoutIDs: Set<UUID> = []
    ) {
        self.version = version
        self.workoutIDs = workoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.favoriteWorkoutIDs = favoriteWorkoutIDs
    }

    /// Whether a on-disk schema version is accepted for load + migration.
    public static func isSupportedSchemaVersion(_ version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    /// Drop favourite IDs that are not present in the library order.
    public mutating func sanitizeFavorites() {
        favoriteWorkoutIDs = favoriteWorkoutIDs.intersection(Set(workoutIDs))
    }

    /// Promote a supported legacy schema to the current version after decode.
    /// Unsupported versions are left unchanged so load validation can reject them.
    public mutating func migrateToCurrentVersionIfNeeded() {
        if Self.isSupportedSchemaVersion(version), version < Self.currentVersion {
            version = Self.currentVersion
        }
        if version == Self.currentVersion {
            sanitizeFavorites()
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case version
        case workoutIDs
        case selectedWorkoutID
        case favoriteWorkoutIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        workoutIDs = try container.decode([UUID].self, forKey: .workoutIDs)
        selectedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkoutID)

        // Version-1 manifests omit favourites. Decode an empty set when absent.
        // Accept either a JSON array or a set-shaped array of UUIDs.
        if let favorites = try container.decodeIfPresent([UUID].self, forKey: .favoriteWorkoutIDs) {
            favoriteWorkoutIDs = Set(favorites)
        } else {
            favoriteWorkoutIDs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(workoutIDs, forKey: .workoutIDs)
        try container.encodeIfPresent(selectedWorkoutID, forKey: .selectedWorkoutID)
        // Stable ordering keeps manifests diff-friendly and deterministic.
        let orderedFavorites = favoriteWorkoutIDs.sorted {
            $0.uuidString.localizedStandardCompare($1.uuidString) == .orderedAscending
        }
        try container.encode(orderedFavorites, forKey: .favoriteWorkoutIDs)
    }
}
