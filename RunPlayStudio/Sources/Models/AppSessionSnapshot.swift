import Foundation
import RunPlayCore

/// The logical destination that can be restored after a relaunch.
enum AppSessionDestination: Equatable, Sendable {
    case workout
    case allRuns
    case smartCollection(UUID)
    case personalHeatmap
    case comparison
}

extension AppSessionDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum Kind: String, Codable {
        case workout
        case allRuns
        case smartCollection
        case personalHeatmap
        case comparison
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch Kind(rawValue: try container.decodeIfPresent(String.self, forKey: .kind) ?? "") {
        case .workout:
            self = .workout
        case .allRuns:
            self = .allRuns
        case .smartCollection:
            guard let id = try container.decodeIfPresent(UUID.self, forKey: .id) else {
                self = .workout
                return
            }
            self = .smartCollection(id)
        case .personalHeatmap:
            self = .personalHeatmap
        case .comparison:
            self = .comparison
        case .none:
            // Unknown destinations are semantically invalid but harmless.
            // Validation will choose the selected-workout fallback.
            self = .workout
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workout:
            try container.encode(Kind.workout.rawValue, forKey: .kind)
        case .allRuns:
            try container.encode(Kind.allRuns.rawValue, forKey: .kind)
        case .smartCollection(let id):
            try container.encode(Kind.smartCollection.rawValue, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .personalHeatmap:
            try container.encode(Kind.personalHeatmap.rawValue, forKey: .kind)
        case .comparison:
            try container.encode(Kind.comparison.rawValue, forKey: .kind)
        }
    }
}

/// Durable workout-detail presentation state. Raw values allow the validator
/// to repair enum additions without rejecting the entire session.
struct AppSessionWorkoutState: Codable, Equatable, Sendable {
    var tabRaw: String
    var mapDisplayModeRaw: String

    init(tabRaw: String = "Overview", mapDisplayModeRaw: String = "2D") {
        self.tabRaw = tabRaw
        self.mapDisplayModeRaw = mapDisplayModeRaw
    }
}

/// Durable All Runs state. Query results and table selection are intentionally
/// absent; they are recomputed from the library and query.
struct AppSessionLibraryState: Codable, Equatable, Sendable {
    var manualQuery: WorkoutLibrarySavedQuery
    var activeSmartCollectionID: UUID?
    var activeSmartCollectionModified: Bool
    var modifiedWorkingQuery: WorkoutLibrarySavedQuery?

    init(
        manualQuery: WorkoutLibrarySavedQuery = WorkoutLibrarySavedQuery(),
        activeSmartCollectionID: UUID? = nil,
        activeSmartCollectionModified: Bool = false,
        modifiedWorkingQuery: WorkoutLibrarySavedQuery? = nil
    ) {
        self.manualQuery = manualQuery
        self.activeSmartCollectionID = activeSmartCollectionID
        self.activeSmartCollectionModified = activeSmartCollectionModified
        self.modifiedWorkingQuery = modifiedWorkingQuery
    }
}

/// Durable Personal Heatmap filter state. Generated map data is not part of a
/// session snapshot.
struct AppSessionHeatmapState: Codable, Equatable, Sendable {
    var datePresetRaw: String
    var customStartDate: Date?
    var customEndDate: Date?
    var resolutionRaw: String
    var minimumWorkoutCount: Int

    init(
        datePresetRaw: String = "allTime",
        customStartDate: Date? = nil,
        customEndDate: Date? = nil,
        resolutionRaw: String = "standard",
        minimumWorkoutCount: Int = 1
    ) {
        self.datePresetRaw = datePresetRaw
        self.customStartDate = customStartDate
        self.customEndDate = customEndDate
        self.resolutionRaw = resolutionRaw
        self.minimumWorkoutCount = minimumWorkoutCount
    }
}

/// Durable comparison context. The peer is validated against the current
/// library before it is applied.
struct AppSessionComparisonState: Codable, Equatable, Sendable {
    var peerWorkoutID: UUID
    var distanceMeters: Double

    init(peerWorkoutID: UUID, distanceMeters: Double = 0) {
        self.peerWorkoutID = peerWorkoutID
        self.distanceMeters = distanceMeters
    }
}

/// Durable replay context. It is deliberately smaller than ReplayState.
struct AppSessionReplayState: Codable, Equatable, Sendable {
    var workoutID: UUID
    var elapsedSeconds: Double
    var playbackSpeed: Double

    init(workoutID: UUID, elapsedSeconds: Double = 0, playbackSpeed: Double = 1) {
        self.workoutID = workoutID
        self.elapsedSeconds = elapsedSeconds
        self.playbackSpeed = playbackSpeed
    }
}

/// Versioned logical application session, separate from WorkoutLibraryManifest.
///
/// This type contains no SwiftUI, AppKit, MapKit, route-point, map-cache, or
/// generated-heatmap state. Raw presentation strings are validated at the
/// Studio boundary so future enum values cannot make the whole session
/// undecodable.
struct AppSessionSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var destination: AppSessionDestination
    var sidebarVisibilityRaw: String
    var workout: AppSessionWorkoutState
    var library: AppSessionLibraryState
    var heatmap: AppSessionHeatmapState
    var comparison: AppSessionComparisonState?
    var replay: AppSessionReplayState?

    init(
        version: Int = AppSessionSnapshot.currentVersion,
        destination: AppSessionDestination = .workout,
        sidebarVisibilityRaw: String = "automatic",
        workout: AppSessionWorkoutState = AppSessionWorkoutState(),
        library: AppSessionLibraryState = AppSessionLibraryState(),
        heatmap: AppSessionHeatmapState = AppSessionHeatmapState(),
        comparison: AppSessionComparisonState? = nil,
        replay: AppSessionReplayState? = nil
    ) {
        self.version = version
        self.destination = destination
        self.sidebarVisibilityRaw = sidebarVisibilityRaw
        self.workout = workout
        self.library = library
        self.heatmap = heatmap
        self.comparison = comparison
        self.replay = replay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard decodedVersion == Self.currentVersion else {
            throw AppSessionSnapshotError.unsupportedVersion(decodedVersion)
        }
        version = decodedVersion
        destination = try container.decodeIfPresent(AppSessionDestination.self, forKey: .destination) ?? .workout
        sidebarVisibilityRaw = try container.decodeIfPresent(String.self, forKey: .sidebarVisibilityRaw) ?? "automatic"
        workout = try container.decodeIfPresent(AppSessionWorkoutState.self, forKey: .workout) ?? AppSessionWorkoutState()
        library = try container.decodeIfPresent(AppSessionLibraryState.self, forKey: .library) ?? AppSessionLibraryState()
        heatmap = try container.decodeIfPresent(AppSessionHeatmapState.self, forKey: .heatmap) ?? AppSessionHeatmapState()
        comparison = try container.decodeIfPresent(AppSessionComparisonState.self, forKey: .comparison)
        replay = try container.decodeIfPresent(AppSessionReplayState.self, forKey: .replay)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case destination
        case sidebarVisibilityRaw
        case workout
        case library
        case heatmap
        case comparison
        case replay
    }

    static func safeDefault(selectedWorkoutID: UUID?) -> AppSessionSnapshot {
        AppSessionSnapshot(
            destination: .workout,
            replay: selectedWorkoutID.map {
                AppSessionReplayState(workoutID: $0, elapsedSeconds: 0, playbackSpeed: 1)
            }
        )
    }
}

enum AppSessionSnapshotError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

/// Bounds for the session file and values derived from user-controlled state.
enum AppSessionPolicy {
    static let maxFileBytes = 512 * 1024
    static let maxSearchTextScalars = WorkoutLibrarySavedQuery.maxSearchTextScalars
    static let maxCustomDateAge: TimeInterval = 100 * 365.25 * 24 * 60 * 60
    static let replaySpeedOptions = [0.25, 0.5, 1, 2, 4, 8]
    static let validHeatmapMinimumWorkoutCounts = Set([1, 2, 3, 5])
    static let validSidebarVisibility = Set(["automatic", "all", "detailOnly"])
    static let validWorkoutTabs = Set(["Overview", "Charts", "Splits", "Segments"])
    static let validMapDisplayModes = Set(["2D", "3D"])
    static let validHeatmapDatePresets = Set(["allTime", "last30Days", "last90Days", "currentYear", "custom"])

    static func boundedQuery(_ query: WorkoutLibrarySavedQuery) -> WorkoutLibrarySavedQuery {
        var bounded = query
        bounded.searchText = String(query.searchText.unicodeScalars.prefix(maxSearchTextScalars))
        return bounded
    }
}
