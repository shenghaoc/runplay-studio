import Foundation

/// Versioned manifest for the workout library.
///
/// Schema version 1 tracked ordered workout IDs and selection.
/// Schema version 2 adds a local favourite set without rewriting workout
/// snapshots or changing analysis / normalization versions.
/// Schema version 3 adds user-defined tags, tag assignments, and smart
/// collections (saved dynamic queries). Workout snapshots remain unchanged.
/// Schema version 4 adds automatic route groups, their assignment records,
/// and each group's cached representative summary. Membership lives in the
/// assignment records; a workout with no record has not been assigned yet.
public struct WorkoutLibraryManifest: Codable, Equatable, Sendable {
    /// Current schema version. Bump when the on-disk format changes.
    public static let currentVersion = 4

    /// Oldest schema version this binary can decode and migrate.
    public static let minimumSupportedVersion = 1

    /// Resource limits for decoding and mutation (unbounded allocation guard).
    public enum ResourceLimits {
        public static let maxTags = WorkoutTagPolicy.default.maxTags
        public static let maxAssignments = 50_000
        public static let maxTagIDsPerAssignment = WorkoutTagPolicy.default.maxTagsPerWorkout
        public static let maxSmartCollections = WorkoutSmartCollectionPolicy.default.maxCollections
        public static let maxSearchTextScalars = WorkoutLibrarySavedQuery.maxSearchTextScalars
        public static let maxRouteGroups = 50_000
        public static let maxRouteGroupAssignments = 50_000
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

    /// Automatic route groups. Membership is derived from
    /// `routeGroupAssignments`, so a group never stores a member list.
    public var routeGroups: [WorkoutRouteGroup]

    /// Route-group assignment records (one per evaluated workout; empty
    /// omitted). The absence of a record means assignment has not run for
    /// that workout yet — the nil marker a later pass picks up.
    public var routeGroupAssignments: [WorkoutRouteGroupAssignment]

    public init(
        version: Int = WorkoutLibraryManifest.currentVersion,
        workoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil,
        favoriteWorkoutIDs: Set<UUID> = [],
        tags: [WorkoutTag] = [],
        tagAssignments: [WorkoutTagAssignment] = [],
        smartCollections: [WorkoutSmartCollection] = [],
        routeGroups: [WorkoutRouteGroup] = [],
        routeGroupAssignments: [WorkoutRouteGroupAssignment] = []
    ) {
        self.version = version
        self.workoutIDs = workoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.favoriteWorkoutIDs = favoriteWorkoutIDs
        self.tags = tags
        self.tagAssignments = tagAssignments
        self.smartCollections = smartCollections
        self.routeGroups = routeGroups
        self.routeGroupAssignments = routeGroupAssignments
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

    // MARK: - Route group helpers

    public func routeGroup(id: UUID) -> WorkoutRouteGroup? {
        routeGroups.first { $0.id == id }
    }

    /// Assignment record for one workout, if assignment has run.
    public func routeGroupAssignment(forWorkoutID workoutID: UUID) -> WorkoutRouteGroupAssignment? {
        routeGroupAssignments.first { $0.workoutID == workoutID }
    }

    /// The group a workout belongs to, if any. A present record with a
    /// `nil` group ID deliberately belongs to no group.
    public func routeGroupID(forWorkoutID workoutID: UUID) -> UUID? {
        routeGroupAssignment(forWorkoutID: workoutID)?.groupID
    }

    /// Member workout IDs of one group, in library order.
    public func routeGroupMemberIDs(groupID: UUID) -> [UUID] {
        let memberSet = Set(
            routeGroupAssignments.compactMap { $0.groupID == groupID ? $0.workoutID : nil }
        )
        guard !memberSet.isEmpty else { return [] }
        return workoutIDs.filter { memberSet.contains($0) }
    }

    /// Replace or add one workout's assignment record (no group mutation).
    /// A record with a `nil` group ID is meaningful — evaluated and
    /// deliberately ungrouped — and is stored like any other.
    public mutating func setRouteGroupAssignment(_ assignment: WorkoutRouteGroupAssignment) {
        routeGroupAssignments.removeAll { $0.workoutID == assignment.workoutID }
        routeGroupAssignments.append(assignment)
        sortRouteGroupAssignmentsDeterministically()
    }

    public mutating func sortRouteGroupAssignmentsDeterministically() {
        routeGroupAssignments.sort {
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

        // Repair route groups and their assignment records. Only assignments
        // whose workout is still in the library count towards membership —
        // a group left only by deleted workouts is empty and unreachable.
        var groupIDByAssignedWorkout: [UUID: UUID] = [:]
        groupIDByAssignedWorkout.reserveCapacity(routeGroupAssignments.count)
        for assignment in routeGroupAssignments {
            if let groupID = assignment.groupID, workoutIDSet.contains(assignment.workoutID) {
                groupIDByAssignedWorkout[assignment.workoutID] = groupID
            }
        }

        // Deduplicate group IDs (keep first occurrence) and cap the count.
        var seenGroupIDs = Set<UUID>()
        var uniqueRouteGroups: [WorkoutRouteGroup] = []
        uniqueRouteGroups.reserveCapacity(routeGroups.count)
        for group in routeGroups {
            if seenGroupIDs.insert(group.id).inserted {
                uniqueRouteGroups.append(group)
            } else {
                report.warnings.append(
                    "Removed duplicate route group \(group.id.uuidString.prefix(8))…"
                )
            }
        }
        if uniqueRouteGroups.count > ResourceLimits.maxRouteGroups {
            uniqueRouteGroups = Array(uniqueRouteGroups.prefix(ResourceLimits.maxRouteGroups))
            report.warnings.append("Truncated route groups to \(ResourceLimits.maxRouteGroups).")
        }

        // A pin or cached summary survives only while the referenced workout
        // is still a member of this group.
        for index in uniqueRouteGroups.indices {
            let groupID = uniqueRouteGroups[index].id
            if let pinned = uniqueRouteGroups[index].pinnedRepresentativeWorkoutID,
               !workoutIDSet.contains(pinned)
               || groupIDByAssignedWorkout[pinned] != groupID {
                uniqueRouteGroups[index].pinnedRepresentativeWorkoutID = nil
            }
            if let summary = uniqueRouteGroups[index].representativeSummary,
               !workoutIDSet.contains(summary.workoutID)
               || groupIDByAssignedWorkout[summary.workoutID] != groupID {
                uniqueRouteGroups[index].representativeSummary = nil
            }
        }

        // Groups with no surviving members are unreachable; remove them.
        let memberGroupIDs = Set(groupIDByAssignedWorkout.values)
        let keptGroups = uniqueRouteGroups.filter { memberGroupIDs.contains($0.id) }
        if keptGroups.count != uniqueRouteGroups.count {
            report.warnings.append("Removed empty route groups.")
        }
        let keptGroupIDs = Set(keptGroups.map(\.id))
        routeGroups = keptGroups

        // Every persisted group carries a materialized derived name. Groups
        // created since the last save are the only pending ones, so this is
        // where a group's automatic name is decided — once, against every
        // name already stored. A manifest that predates the field gets the
        // whole set at once on its first repair (the load-time migration).
        WorkoutRouteGroup.materializeDerivedNames(in: &routeGroups)

        // Repair assignment records: drop workouts that left the library,
        // drop references to groups that no longer exist, deduplicate by
        // workout, and cap the count.
        var repairedRouteGroupAssignments: [WorkoutRouteGroupAssignment] = []
        repairedRouteGroupAssignments.reserveCapacity(
            min(routeGroupAssignments.count, ResourceLimits.maxRouteGroupAssignments)
        )
        var seenAssignmentWorkoutIDs = Set<UUID>()
        for assignment in routeGroupAssignments {
            if repairedRouteGroupAssignments.count >= ResourceLimits.maxRouteGroupAssignments {
                report.warnings.append(
                    "Truncated route group assignments to \(ResourceLimits.maxRouteGroupAssignments)."
                )
                break
            }
            guard workoutIDSet.contains(assignment.workoutID) else { continue }
            guard seenAssignmentWorkoutIDs.insert(assignment.workoutID).inserted else { continue }
            if let groupID = assignment.groupID, !keptGroupIDs.contains(groupID) {
                continue
            }
            repairedRouteGroupAssignments.append(assignment)
        }
        routeGroupAssignments = repairedRouteGroupAssignments
        sortRouteGroupAssignmentsDeterministically()

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
        case routeGroups
        case routeGroupAssignments
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

        // Version 1–3 manifests omit route groups. Decode only up to the
        // resource caps so a malformed local manifest cannot allocate an
        // unbounded route-group array before repair truncates it.
        routeGroups = try Self.decodeCappedArray(
            WorkoutRouteGroup.self,
            from: container,
            forKey: .routeGroups,
            maxCount: ResourceLimits.maxRouteGroups
        )
        routeGroupAssignments = try Self.decodeCappedArray(
            WorkoutRouteGroupAssignment.self,
            from: container,
            forKey: .routeGroupAssignments,
            maxCount: ResourceLimits.maxRouteGroupAssignments
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
        let orderedRouteGroups = routeGroups.sorted {
            $0.id.uuidString.localizedStandardCompare($1.id.uuidString) == .orderedAscending
        }
        try container.encode(orderedRouteGroups, forKey: .routeGroups)
        // Route-group assignments are expected pre-sorted; re-sort for safety.
        let orderedRouteGroupAssignments = routeGroupAssignments.sorted {
            $0.workoutID.uuidString.localizedStandardCompare($1.workoutID.uuidString) == .orderedAscending
        }
        try container.encode(orderedRouteGroupAssignments, forKey: .routeGroupAssignments)
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
