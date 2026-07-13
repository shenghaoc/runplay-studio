import Foundation

/// A complete running workout with route data, analysis, and metadata.
public struct RunWorkout: Identifiable, Codable, Hashable, Sendable {
    /// Snapshots without a version predate pause-aware analysis.
    public static let legacyAnalysisVersion = 0
    public static let currentAnalysisVersion = 1

    public let id: UUID
    public var metadata: WorkoutMetadata
    public var source: WorkoutSource
    public var routePoints: [RoutePoint]
    public var splits: [RunSplit]
    public var summary: RunSummary
    public var segments: [SegmentHighlight]
    public var analysisVersion: Int
    public var analysisWarnings: [WorkoutAnalysisWarning]

    public init(
        id: UUID = UUID(),
        metadata: WorkoutMetadata = WorkoutMetadata(),
        source: WorkoutSource = .unknown,
        routePoints: [RoutePoint] = [],
        splits: [RunSplit] = [],
        summary: RunSummary = RunSummary(),
        segments: [SegmentHighlight] = []
    ) {
        self.init(
            id: id,
            metadata: metadata,
            source: source,
            routePoints: routePoints,
            splits: splits,
            summary: summary,
            segments: segments,
            analysisVersion: RunWorkout.currentAnalysisVersion,
            analysisWarnings: []
        )
    }

    public init(
        id: UUID = UUID(),
        metadata: WorkoutMetadata = WorkoutMetadata(),
        source: WorkoutSource = .unknown,
        routePoints: [RoutePoint] = [],
        splits: [RunSplit] = [],
        summary: RunSummary = RunSummary(),
        segments: [SegmentHighlight] = [],
        analysisVersion: Int,
        analysisWarnings: [WorkoutAnalysisWarning] = []
    ) {
        self.id = id
        self.metadata = metadata
        self.source = source
        self.routePoints = routePoints
        self.splits = splits
        self.summary = summary
        self.segments = segments
        self.analysisVersion = max(RunWorkout.legacyAnalysisVersion, analysisVersion)
        self.analysisWarnings = analysisWarnings
    }

    // ⚡ Bolt: Cache date formatter to avoid expensive initialization on property access
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Display name for the workout.
    public var displayName: String {
        if let name = metadata.name, !name.isEmpty {
            return name
        }
        if let date = metadata.startDate {
            return RunWorkout.displayFormatter.string(from: date)
        }
        return "Untitled Run"
    }

    public var pointCount: Int { routePoints.count }
    public var hasAltitudeData: Bool { routePoints.contains { $0.altitudeMeters != nil } }
    public var hasHeartRateData: Bool { routePoints.contains { $0.heartRateBPM != nil } }
    public var hasCadenceData: Bool { routePoints.contains { $0.cadence != nil } }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, metadata, source, routePoints, splits, summary, segments
        case analysisVersion, analysisWarnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        metadata = try container.decode(WorkoutMetadata.self, forKey: .metadata)
        source = try container.decode(WorkoutSource.self, forKey: .source)
        routePoints = try container.decode([RoutePoint].self, forKey: .routePoints)
        splits = try container.decode([RunSplit].self, forKey: .splits)
        summary = try container.decode(RunSummary.self, forKey: .summary)
        segments = try container.decode([SegmentHighlight].self, forKey: .segments)
        analysisVersion = try container.decodeIfPresent(Int.self, forKey: .analysisVersion)
            ?? RunWorkout.legacyAnalysisVersion
        analysisWarnings = try container.decodeIfPresent([WorkoutAnalysisWarning].self, forKey: .analysisWarnings) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(source, forKey: .source)
        try container.encode(routePoints, forKey: .routePoints)
        try container.encode(splits, forKey: .splits)
        try container.encode(summary, forKey: .summary)
        try container.encode(segments, forKey: .segments)
        try container.encode(analysisVersion, forKey: .analysisVersion)
        try container.encode(analysisWarnings, forKey: .analysisWarnings)
    }
}
