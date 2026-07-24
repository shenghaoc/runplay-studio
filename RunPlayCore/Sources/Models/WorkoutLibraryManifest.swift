import Foundation

/// Versioned manifest for the workout library.
///
/// Schema version 1 tracked ordered workout IDs and selection.
/// Schema version 2 adds a local favourite set without rewriting workout
/// snapshots or changing analysis / normalization versions.
/// Schema version 3 adds user-defined tags, tag assignments, and smart
/// collections (saved dynamic queries). Workout snapshots remain unchanged.
public struct WorkoutLibraryManifest: Codable, Equatable, Sendable {
    /// Current schema version. Bump when the on-disk format changes.
    public static let currentVersion = 3

    /// Oldest schema version this binary can decode and migrate.
    public static let minimumSupportedVersion = 1

    /// Resource limits for decoding and mutation (unbounded allocation guard).
    public enum ResourceLimits {
        public static let maxTags = WorkoutTagPolicy.default.maxTags
        public static let maxAssignments = 50_000
        public static let maxTagIDsPerAssignment = WorkoutTagPolicy.default.maxTagsPerWorkout
        public static let maxSmartCollections = WorkoutSmartCollectionPolicy.default.maxCollections
        public static let maxSearchTextScalars = WorkoutLibrarySavedQuery.maxSearchTextScalars
    }

    /// Schema version of this manifest.
    public var version: Int

    /// Ordered workout IDs (defines library / sidebar display order).
    public var workoutIDs: [UUID]

    /// Last-selected workout ID, if any.
    public var selectedWorkoutID: UUID?

    /// Local favourite markers. Only IDs present in `workoutIDs` are meaningful.
    public var favoriteWorkoutIDs: Set<UUID>

    /// Ordered user-defined tag definitions.
    public var tags: [WorkoutTag]

    /// Tag assignments (one record per tagged workout; empty omitted).
    public var tagAssignments: [WorkoutTagAssignment]

    /// Ordered smart collections (saved dynamic queries).
    public var smartCollections: [WorkoutSmartCollection]

    public init(
        version: Int = WorkoutLibraryManifest.currentVersion,
        workoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil,
        favoriteWorkoutIDs: Set<UUID> = [],
        tags: [WorkoutTag] = [],
        tagAssignments: [WorkoutTagAssignment] = [],
        smartCollections: [WorkoutSmartCollection] = []
    ) {
        self.version = version
        self.workoutIDs = workoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.favoriteWorkoutIDs = favoriteWorkoutIDs
        self.tags = tags
        self.tagAssignments = tagAssignments
        self.smartCollections = smartCollections
    }

    /// Whether a on-disk schema version is accepted for load + migration.
    public static func isSupportedSchemaVersion(_ version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    /// Drop favourite IDs that are not present in the library order.
    public mutating func sanitizeFavorites() {
        favoriteWorkoutIDs = favoriteWorkoutIDs.intersection(Set(workoutIDs))
    }

    /// Promote a supported legacy schema to the current version without
    /// discarding references that actor-level recovery must persistently repair.
    /// Unsupported versions are left unchanged so load validation can reject them.
    mutating func upgradeSchemaVersionIfNeeded() {
        if Self.isSupportedSchemaVersion(version), version < Self.currentVersion {
            version = Self.currentVersion
        }
    }

    /// Promote a supported manifest to the current schema and normalize its
    /// organisation fields before persistence.
    public mutating func migrateToCurrentVersionIfNeeded() {
        upgradeSchemaVersionIfNeeded()
        if version == Self.currentVersion {
            sanitizeFavorites()
            _ = repairOrganization()
        }
    }

    // MARK: - Organisation helpers

    public func tag(id: UUID) -> WorkoutTag? {
        tags.first { $0.id == id }
    }

    public func smartCollection(id: UUID) -> WorkoutSmartCollection? {
        smartCollections.first { $0.id == id }
    }

    public var tagIDsByWorkout: [UUID: Set<UUID>] {
        var map: [UUID: Set<UUID>] = [:]
        map.reserveCapacity(tagAssignments.count)
        for assignment in tagAssignments {
            map[assignment.workoutID] = assignment.tagIDSet
        }
        return map
    }

    public func tagIDs(forWorkoutID workoutID: UUID) -> Set<UUID> {
        tagAssignments.first { $0.workoutID == workoutID }?.tagIDSet ?? []
    }

    public mutating func setTagIDs(_ tagIDs: Set<UUID>, forWorkoutID workoutID: UUID) {
        let normalized = WorkoutTagAssignment.normalizedTagIDs(Array(tagIDs))
        tagAssignments.removeAll { $0.workoutID == workoutID }
        if !normalized.isEmpty {
            tagAssignments.append(WorkoutTagAssignment(workoutID: workoutID, tagIDs: normalized))
            sortAssignmentsDeterministically()
        }
    }

    public mutating func removeTagAssignment(forWorkoutID workoutID: UUID) {
        tagAssignments.removeAll { $0.workoutID == workoutID }
    }

    public mutating func sortAssignmentsDeterministically() {
        tagAssignments.sort {
            $0.workoutID.uuidString.localizedStandardCompare($1.workoutID.uuidString) == .orderedAscending
        }
    }

    /// Nonfatal repair notes produced while normalizing organisation fields.
    public struct RepairReport: Equatable, Sendable {
        public var warnings: [String]

        public init(warnings: [String] = []) {
            self.warnings = warnings
        }

        public var isEmpty: Bool { warnings.isEmpty }
    }

    /// Repair dangling organisation references. Returns warnings for UI when needed.
    @discardableResult
    public mutating func repairOrganization() -> RepairReport {
        var report = RepairReport()
        let workoutIDSet = Set(workoutIDs)

        // Deduplicate tag IDs (keep first occurrence).
        var seenTagIDs = Set<UUID>()
        var uniqueTags: [WorkoutTag] = []
        uniqueTags.reserveCapacity(tags.count)
        for tag in tags {
            if seenTagIDs.insert(tag.id).inserted {
                uniqueTags.append(tag)
            } else {
                report.warnings.append(
                    "Removed duplicate tag definition \(tag.id.uuidString.prefix(8))…"
                )
            }
        }
        if uniqueTags.count > ResourceLimits.maxTags {
            uniqueTags = Array(uniqueTags.prefix(ResourceLimits.maxTags))
            report.warnings.append("Truncated tags to \(ResourceLimits.maxTags) definitions.")
        }
        tags = uniqueTags
        let validTagIDs = Set(tags.map(\.id))

        // Deduplicate collection IDs (keep first occurrence).
        var seenCollectionIDs = Set<UUID>()
        var uniqueCollections: [WorkoutSmartCollection] = []
        uniqueCollections.reserveCapacity(smartCollections.count)
        for collection in smartCollections {
            if seenCollectionIDs.insert(collection.id).inserted {
                uniqueCollections.append(collection)
            } else {
                report.warnings.append(
                    "Removed duplicate smart collection \(collection.id.uuidString.prefix(8))…"
                )
            }
        }
        if uniqueCollections.count > ResourceLimits.maxSmartCollections {
            uniqueCollections = Array(uniqueCollections.prefix(ResourceLimits.maxSmartCollections))
            report.warnings.append(
                "Truncated smart collections to \(ResourceLimits.maxSmartCollections)."
            )
        }

        // Repair collection tag references.
        for index in uniqueCollections.indices {
            var collection = uniqueCollections[index]
            let repairedFilter = Self.repairTagFilter(
                collection.query.filter.tags,
                validTagIDs: validTagIDs,
                collectionName: collection.name,
                report: &report
            )
            if repairedFilter != collection.query.filter.tags {
                collection.query.filter.tags = repairedFilter
            }
            if collection.query.searchText.unicodeScalars.count > ResourceLimits.maxSearchTextScalars {
                let truncated = String(collection.query.searchText.unicodeScalars.prefix(ResourceLimits.maxSearchTextScalars))
                collection.query.searchText = truncated
                report.warnings.append(
                    "Truncated search text in smart collection “\(collection.name)”."
                )
            }
            uniqueCollections[index] = collection
        }
        smartCollections = uniqueCollections

        // Repair assignments.
        var repairedAssignments: [WorkoutTagAssignment] = []
        repairedAssignments.reserveCapacity(min(tagAssignments.count, ResourceLimits.maxAssignments))
        var seenWorkoutIDs = Set<UUID>()
        for assignment in tagAssignments {
            if repairedAssignments.count >= ResourceLimits.maxAssignments {
                report.warnings.append(
                    "Truncated tag assignments to \(ResourceLimits.maxAssignments)."
                )
                break
            }
            guard workoutIDSet.contains(assignment.workoutID) else { continue }
            guard seenWorkoutIDs.insert(assignment.workoutID).inserted else { continue }
            let kept = assignment.tagIDs.filter { validTagIDs.contains($0) }
            let limited = Array(WorkoutTagAssignment.normalizedTagIDs(kept).prefix(ResourceLimits.maxTagIDsPerAssignment))
            if !limited.isEmpty {
                repairedAssignments.append(
                    WorkoutTagAssignment(workoutID: assignment.workoutID, tagIDs: limited)
                )
            }
        }
        tagAssignments = repairedAssignments
        sortAssignmentsDeterministically()

        return report
    }

    private static func repairTagFilter(
        _ filter: WorkoutLibraryTagFilter,
        validTagIDs: Set<UUID>,
        collectionName: String,
        report: inout RepairReport
    ) -> WorkoutLibraryTagFilter {
        switch filter {
        case .anyTags, .untaggedOnly:
            return filter
        case .selected(let tagIDs, let match):
            let kept = tagIDs.intersection(validTagIDs)
            if kept.count != tagIDs.count {
                report.warnings.append(
                    "Removed missing tag references from smart collection “\(collectionName)”."
                )
            }
            if kept.isEmpty {
                if !tagIDs.isEmpty {
                    report.warnings.append(
                        "Smart collection “\(collectionName)” no longer restricts by tags (all referenced tags were removed)."
                    )
                }
                return .anyTags
            }
            return .selected(tagIDs: kept, match: match)
        }
    }

    /// Remove a tag definition and every reference (assignments + collection filters).
    public mutating func deleteTag(id: UUID) {
        tags.removeAll { $0.id == id }
        for index in tagAssignments.indices {
            tagAssignments[index].tagIDs.removeAll { $0 == id }
        }
        tagAssignments.removeAll { $0.isEmpty }
        for index in smartCollections.indices {
            smartCollections[index].query.filter.tags = Self.stripTag(
                id,
                from: smartCollections[index].query.filter.tags
            )
        }
        sortAssignmentsDeterministically()
    }

    private static func stripTag(_ id: UUID, from filter: WorkoutLibraryTagFilter) -> WorkoutLibraryTagFilter {
        switch filter {
        case .anyTags, .untaggedOnly:
            return filter
        case .selected(let tagIDs, let match):
            var remaining = tagIDs
            remaining.remove(id)
            if remaining.isEmpty {
                return .anyTags
            }
            return .selected(tagIDs: remaining, match: match)
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case version
        case workoutIDs
        case selectedWorkoutID
        case favoriteWorkoutIDs
        case tags
        case tagAssignments
        case smartCollections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        workoutIDs = try container.decode([UUID].self, forKey: .workoutIDs)
        selectedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkoutID)

        // Version-1 manifests omit favourites. Decode an empty set when absent.
        if let favorites = try container.decodeIfPresent([UUID].self, forKey: .favoriteWorkoutIDs) {
            favoriteWorkoutIDs = Set(favorites)
        } else {
            favoriteWorkoutIDs = []
        }

        // Version 1–2 omit organisation fields. Decode only up to the resource
        // caps so a malformed local manifest cannot allocate an unbounded
        // organisation array before repair truncates it.
        tags = try Self.decodeCappedArray(
            WorkoutTag.self,
            from: container,
            forKey: .tags,
            maxCount: ResourceLimits.maxTags
        )
        tagAssignments = try Self.decodeCappedArray(
            WorkoutTagAssignment.self,
            from: container,
            forKey: .tagAssignments,
            maxCount: ResourceLimits.maxAssignments
        )
        smartCollections = try Self.decodeCappedArray(
            WorkoutSmartCollection.self,
            from: container,
            forKey: .smartCollections,
            maxCount: ResourceLimits.maxSmartCollections
        )
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
        try container.encode(tags, forKey: .tags)
        // Assignments are expected pre-sorted; re-sort for safety.
        let orderedAssignments = tagAssignments.sorted {
            $0.workoutID.uuidString.localizedStandardCompare($1.workoutID.uuidString) == .orderedAscending
        }
        try container.encode(orderedAssignments, forKey: .tagAssignments)
        try container.encode(smartCollections, forKey: .smartCollections)
    }

    private static func decodeCappedArray<Element: Decodable>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        maxCount: Int
    ) throws -> [Element] {
        guard container.contains(key), try !container.decodeNil(forKey: key) else {
            return []
        }

        var values: [Element] = []
        values.reserveCapacity(min(maxCount, 64))
        var unkeyed = try container.nestedUnkeyedContainer(forKey: key)
        while !unkeyed.isAtEnd, values.count < maxCount {
            values.append(try unkeyed.decode(type))
        }
        return values
    }
}
