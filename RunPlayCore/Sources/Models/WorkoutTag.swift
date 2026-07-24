import Foundation

// MARK: - Tag color

/// Finite palette token for tag presentation.
///
/// Tokens are platform-neutral; light/dark colors are resolved in the UI layer.
/// Unknown stored values decode as `.gray` for backward compatibility.
public enum WorkoutTagColor: String, CaseIterable, Codable, Hashable, Sendable {
    case blue
    case cyan
    case green
    case yellow
    case orange
    case red
    case purple
    case gray

    public static let `default`: WorkoutTagColor = .blue

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = WorkoutTagColor(rawValue: raw) ?? .gray
    }
}

// MARK: - Tag

/// User-created reusable label assigned to zero or more workouts.
///
/// Tag definitions live in the library manifest. Assignments are stored
/// separately so renaming or recoloring does not rewrite workout snapshots.
public struct WorkoutTag: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: WorkoutTagColor

    public init(id: UUID = UUID(), name: String, color: WorkoutTagColor = .default) {
        self.id = id
        self.name = name
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decodeIfPresent(WorkoutTagColor.self, forKey: .color) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
    }
}

// MARK: - Assignment

/// Tag IDs assigned to one workout. Empty assignments are omitted from persistence.
public struct WorkoutTagAssignment: Codable, Hashable, Sendable {
    public let workoutID: UUID
    /// Ordered unique tag IDs (deterministic encode order: UUID string ascending).
    public var tagIDs: [UUID]

    public init(workoutID: UUID, tagIDs: [UUID]) {
        self.workoutID = workoutID
        self.tagIDs = Self.normalizedTagIDs(tagIDs)
    }

    public init(workoutID: UUID, tagIDs: Set<UUID>) {
        self.workoutID = workoutID
        self.tagIDs = Self.normalizedTagIDs(Array(tagIDs))
    }

    public var tagIDSet: Set<UUID> { Set(tagIDs) }

    public var isEmpty: Bool { tagIDs.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case workoutID
        case tagIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workoutID = try container.decode(UUID.self, forKey: .workoutID)
        let raw = try Self.decodeCappedTagIDs(from: container)
        tagIDs = Self.normalizedTagIDs(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workoutID, forKey: .workoutID)
        try container.encode(Self.normalizedTagIDs(tagIDs), forKey: .tagIDs)
    }

    /// Collapse duplicates and sort for stable encoding.
    public static func normalizedTagIDs(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted {
            $0.uuidString.localizedStandardCompare($1.uuidString) == .orderedAscending
        }
    }

    private static func decodeCappedTagIDs(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [UUID] {
        guard container.contains(.tagIDs), try !container.decodeNil(forKey: .tagIDs) else {
            return []
        }

        var ids: [UUID] = []
        ids.reserveCapacity(WorkoutTagPolicy.default.maxTagsPerWorkout)
        var unkeyed = try container.nestedUnkeyedContainer(forKey: .tagIDs)
        while !unkeyed.isAtEnd, ids.count < WorkoutTagPolicy.default.maxTagsPerWorkout {
            ids.append(try unkeyed.decode(UUID.self))
        }
        return ids
    }
}

// MARK: - Folding

/// Shared case/diacritic/width folding used for tag and collection name uniqueness.
public enum WorkoutOrganizationNameFolding: Sendable {
    public static func fold(_ string: String) -> String {
        string
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}

// MARK: - Policy

/// Central limits and validation for user-defined tags.
public struct WorkoutTagPolicy: Hashable, Sendable {
    public static let `default` = WorkoutTagPolicy()

    /// Maximum tag definitions per library.
    public let maxTags: Int
    /// Maximum Unicode scalar values per tag name.
    public let maxNameScalars: Int
    /// Maximum tags assigned to one workout.
    public let maxTagsPerWorkout: Int
    public let defaultColor: WorkoutTagColor

    public init(
        maxTags: Int = 200,
        maxNameScalars: Int = 50,
        maxTagsPerWorkout: Int = 20,
        defaultColor: WorkoutTagColor = .default
    ) {
        self.maxTags = maxTags
        self.maxNameScalars = maxNameScalars
        self.maxTagsPerWorkout = maxTagsPerWorkout
        self.defaultColor = defaultColor
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptyName
        case containsNUL
        case containsLineBreak
        case nameTooLong(limit: Int)
        case duplicateName(String)
        case tagLimitReached(limit: Int)
        case tagsPerWorkoutLimit(limit: Int)
        case unknownTag(UUID)
        case unknownWorkout(UUID)
        case duplicateTagID(UUID)

        public var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Tag name cannot be empty."
            case .containsNUL:
                return "Tag name contains an invalid character."
            case .containsLineBreak:
                return "Tag name must be a single line."
            case .nameTooLong(let limit):
                return "Tag name must be at most \(limit) characters."
            case .duplicateName(let name):
                return "A tag named “\(name)” already exists."
            case .tagLimitReached(let limit):
                return "A library can have at most \(limit) tags."
            case .tagsPerWorkoutLimit(let limit):
                return "A workout can have at most \(limit) tags."
            case .unknownTag(let id):
                return "Unknown tag \(id.uuidString)."
            case .unknownWorkout(let id):
                return "Unknown workout \(id.uuidString)."
            case .duplicateTagID(let id):
                return "Duplicate tag ID \(id.uuidString)."
            }
        }
    }

    public struct NormalizedName: Hashable, Sendable {
        /// Display casing preserved after trimming.
        public let display: String
        /// Folded form used for uniqueness comparison.
        public let folded: String

        public init(display: String, folded: String) {
            self.display = display
            self.folded = folded
        }
    }

    /// Validate and normalize a tag name without uniqueness checks.
    public func normalizeName(_ raw: String) throws -> NormalizedName {
        if raw.unicodeScalars.contains(UnicodeScalar(0)) {
            throw ValidationError.containsNUL
        }
        if raw.contains(where: { $0.isNewline }) {
            throw ValidationError.containsLineBreak
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.emptyName
        }
        if trimmed.unicodeScalars.count > maxNameScalars {
            throw ValidationError.nameTooLong(limit: maxNameScalars)
        }
        return NormalizedName(
            display: trimmed,
            folded: WorkoutOrganizationNameFolding.fold(trimmed)
        )
    }

    /// Validate name uniqueness against existing tags (excluding `excludingID`).
    public func validateUniqueName(
        _ normalized: NormalizedName,
        existing: [WorkoutTag],
        excludingID: UUID? = nil
    ) throws {
        for tag in existing {
            if tag.id == excludingID { continue }
            if WorkoutOrganizationNameFolding.fold(tag.name) == normalized.folded {
                throw ValidationError.duplicateName(tag.name)
            }
        }
    }

    public func validateCanCreate(existingCount: Int) throws {
        if existingCount >= maxTags {
            throw ValidationError.tagLimitReached(limit: maxTags)
        }
    }

    public func validateAssignmentCount(_ count: Int) throws {
        if count > maxTagsPerWorkout {
            throw ValidationError.tagsPerWorkoutLimit(limit: maxTagsPerWorkout)
        }
    }
}
