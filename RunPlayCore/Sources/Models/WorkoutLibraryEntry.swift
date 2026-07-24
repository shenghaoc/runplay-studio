import Foundation

/// Lightweight library row used for search, filter, sort, and table display.
///
/// Built once per library revision from `RunWorkout` summaries and metadata.
/// Does **not** retain route-point arrays, so ordinary queries never iterate GPS.
public struct WorkoutLibraryEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Position in the library manifest (`workoutIDs` order).
    public let manifestIndex: Int
    public let isFavorite: Bool

    public let displayName: String
    public let metadataName: String?
    public let notes: String?
    public let activityType: String
    public let deviceName: String?
    public let source: WorkoutSource
    public let importProvider: WorkoutImportProvider?
    /// Safe basename / archive-relative name only (never absolute paths).
    public let originalFilename: String?

    /// Canonical start date used for Recent, date filters, and date sorting.
    public let startDate: Date?
    public let totalDistanceMeters: Double
    /// Active pace (seconds per kilometre). Non-finite or non-positive is invalid.
    public let activePaceSecondsPerKilometer: Double
    public let totalElapsedSeconds: Double

    public let hasHeartRate: Bool
    public let hasCorrectedElevation: Bool
    public let hasRecordedLaps: Bool

    /// Cheap revision token for cache invalidation after metadata edits.
    public let nameNotesRevision: String

    /// Assigned tag IDs (empty when untagged).
    public let tagIDs: Set<UUID>
    /// Deterministically ordered display names for assigned tags.
    public let tagNames: [String]
    /// Revision of tag IDs + names for search-document invalidation.
    public let tagRevision: String

    /// Maximum chips shown in compact table cells before `+N`.
    public static let visibleTagChipLimit = 3

    public init(
        id: UUID,
        manifestIndex: Int,
        isFavorite: Bool,
        displayName: String,
        metadataName: String?,
        notes: String?,
        activityType: String,
        deviceName: String?,
        source: WorkoutSource,
        importProvider: WorkoutImportProvider?,
        originalFilename: String?,
        startDate: Date?,
        totalDistanceMeters: Double,
        activePaceSecondsPerKilometer: Double,
        totalElapsedSeconds: Double,
        hasHeartRate: Bool,
        hasCorrectedElevation: Bool,
        hasRecordedLaps: Bool,
        nameNotesRevision: String,
        tagIDs: Set<UUID> = [],
        tagNames: [String] = [],
        tagRevision: String = ""
    ) {
        self.id = id
        self.manifestIndex = manifestIndex
        self.isFavorite = isFavorite
        self.displayName = displayName
        self.metadataName = metadataName
        self.notes = notes
        self.activityType = activityType
        self.deviceName = deviceName
        self.source = source
        self.importProvider = importProvider
        self.originalFilename = originalFilename
        self.startDate = startDate
        self.totalDistanceMeters = totalDistanceMeters
        self.activePaceSecondsPerKilometer = activePaceSecondsPerKilometer
        self.totalElapsedSeconds = totalElapsedSeconds
        self.hasHeartRate = hasHeartRate
        self.hasCorrectedElevation = hasCorrectedElevation
        self.hasRecordedLaps = hasRecordedLaps
        self.nameNotesRevision = nameNotesRevision
        self.tagIDs = tagIDs
        self.tagNames = tagNames
        self.tagRevision = tagRevision.isEmpty
            ? Self.makeTagRevision(tagIDs: tagIDs, tagNames: tagNames)
            : tagRevision
    }

    /// Build a search/filter entry without copying route-point storage.
    public static func make(
        from workout: RunWorkout,
        manifestIndex: Int,
        isFavorite: Bool,
        tagIDs: Set<UUID> = [],
        tagsByID: [UUID: WorkoutTag] = [:]
    ) -> WorkoutLibraryEntry {
        let startDate = Self.canonicalStartDate(for: workout)
        let hasHeartRate =
            (workout.summary.averageHeartRateBPM.map { $0.isFinite && $0 > 0 } ?? false)
            || (workout.summary.maxHeartRateBPM.map { $0.isFinite && $0 > 0 } ?? false)
        // Corrected elevation availability uses summary elevation metrics so
        // entry construction does not walk route points for large libraries.
        let hasCorrectedElevation =
            workout.summary.elevationGainMeters > 0
            || workout.summary.elevationLossMeters > 0
        let name = workout.metadata.name
        let notes = workout.metadata.notes
        let orderedTagNames = Self.orderedTagNames(tagIDs: tagIDs, tagsByID: tagsByID)
        return WorkoutLibraryEntry(
            id: workout.id,
            manifestIndex: manifestIndex,
            isFavorite: isFavorite,
            displayName: workout.displayName,
            metadataName: name,
            notes: notes,
            activityType: workout.metadata.activityType,
            deviceName: workout.metadata.deviceName,
            source: workout.source,
            importProvider: workout.importProvenance?.provider,
            originalFilename: workout.importProvenance?.originalFilename,
            startDate: startDate,
            totalDistanceMeters: workout.summary.totalDistanceMeters,
            activePaceSecondsPerKilometer: workout.summary.averagePaceSecondsPerKilometer,
            totalElapsedSeconds: workout.summary.totalElapsedSeconds,
            hasHeartRate: hasHeartRate,
            hasCorrectedElevation: hasCorrectedElevation,
            hasRecordedLaps: !workout.recordedLaps.isEmpty,
            nameNotesRevision: "\(name ?? "")|\(notes ?? "")",
            tagIDs: tagIDs,
            tagNames: orderedTagNames
        )
    }

    /// Canonical workout date: metadata start, else first route-point timestamp.
    public static func canonicalStartDate(for workout: RunWorkout) -> Date? {
        if let start = workout.metadata.startDate {
            return start
        }
        return workout.routePoints.first?.timestamp
    }

    public static func orderedTagNames(
        tagIDs: Set<UUID>,
        tagsByID: [UUID: WorkoutTag]
    ) -> [String] {
        tagIDs
            .compactMap { tagsByID[$0]?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func makeTagRevision(tagIDs: Set<UUID>, tagNames: [String]) -> String {
        let ids = tagIDs.map(\.uuidString).sorted().joined(separator: ",")
        let names = tagNames.joined(separator: "|")
        return "\(ids)#\(names)"
    }

    /// Copy with updated favourite flag.
    public func withFavorite(_ isFavorite: Bool) -> WorkoutLibraryEntry {
        WorkoutLibraryEntry(
            id: id,
            manifestIndex: manifestIndex,
            isFavorite: isFavorite,
            displayName: displayName,
            metadataName: metadataName,
            notes: notes,
            activityType: activityType,
            deviceName: deviceName,
            source: source,
            importProvider: importProvider,
            originalFilename: originalFilename,
            startDate: startDate,
            totalDistanceMeters: totalDistanceMeters,
            activePaceSecondsPerKilometer: activePaceSecondsPerKilometer,
            totalElapsedSeconds: totalElapsedSeconds,
            hasHeartRate: hasHeartRate,
            hasCorrectedElevation: hasCorrectedElevation,
            hasRecordedLaps: hasRecordedLaps,
            nameNotesRevision: nameNotesRevision,
            tagIDs: tagIDs,
            tagNames: tagNames,
            tagRevision: tagRevision
        )
    }

    /// Copy with updated tag assignment / names.
    public func withTags(tagIDs: Set<UUID>, tagNames: [String]) -> WorkoutLibraryEntry {
        WorkoutLibraryEntry(
            id: id,
            manifestIndex: manifestIndex,
            isFavorite: isFavorite,
            displayName: displayName,
            metadataName: metadataName,
            notes: notes,
            activityType: activityType,
            deviceName: deviceName,
            source: source,
            importProvider: importProvider,
            originalFilename: originalFilename,
            startDate: startDate,
            totalDistanceMeters: totalDistanceMeters,
            activePaceSecondsPerKilometer: activePaceSecondsPerKilometer,
            totalElapsedSeconds: totalElapsedSeconds,
            hasHeartRate: hasHeartRate,
            hasCorrectedElevation: hasCorrectedElevation,
            hasRecordedLaps: hasRecordedLaps,
            nameNotesRevision: nameNotesRevision,
            tagIDs: tagIDs,
            tagNames: tagNames
        )
    }

    /// Copy with updated manifest index.
    public func withManifestIndex(_ index: Int) -> WorkoutLibraryEntry {
        WorkoutLibraryEntry(
            id: id,
            manifestIndex: index,
            isFavorite: isFavorite,
            displayName: displayName,
            metadataName: metadataName,
            notes: notes,
            activityType: activityType,
            deviceName: deviceName,
            source: source,
            importProvider: importProvider,
            originalFilename: originalFilename,
            startDate: startDate,
            totalDistanceMeters: totalDistanceMeters,
            activePaceSecondsPerKilometer: activePaceSecondsPerKilometer,
            totalElapsedSeconds: totalElapsedSeconds,
            hasHeartRate: hasHeartRate,
            hasCorrectedElevation: hasCorrectedElevation,
            hasRecordedLaps: hasRecordedLaps,
            nameNotesRevision: nameNotesRevision,
            tagIDs: tagIDs,
            tagNames: tagNames,
            tagRevision: tagRevision
        )
    }
}
