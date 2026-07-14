import Foundation

/// A complete running workout with route data, analysis, and metadata.
public struct RunWorkout: Identifiable, Codable, Hashable, Sendable {
    /// Snapshots without a version predate pause-aware analysis.
    public static let legacyAnalysisVersion = 0
    public static let currentAnalysisVersion = 3
    /// Snapshots without this version predate route-quality normalization.
    public static let legacyNormalizationVersion = 0
    public static let currentNormalizationVersion = 1

    public let id: UUID
    public var metadata: WorkoutMetadata
    public var source: WorkoutSource
    public var routePoints: [RoutePoint]
    public var splits: [RunSplit]
    public var summary: RunSummary
    public var segments: [SegmentHighlight]
    public var analysisVersion: Int
    public var normalizationVersion: Int
    public var analysisWarnings: [WorkoutAnalysisWarning]
    public var qualityDiagnostics: RouteQualityDiagnostics
    public var routeDistanceSource: RouteDistanceSource
    public var routeDistanceProvenance: RouteDistanceProvenance

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
            normalizationVersion: RunWorkout.currentNormalizationVersion,
            analysisWarnings: [],
            qualityDiagnostics: .empty,
            routeDistanceSource: .coordinateDerived,
            routeDistanceProvenance: .legacyUnknown
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
        normalizationVersion: Int = RunWorkout.currentNormalizationVersion,
        analysisWarnings: [WorkoutAnalysisWarning] = [],
        qualityDiagnostics: RouteQualityDiagnostics = .empty,
        routeDistanceSource: RouteDistanceSource = .coordinateDerived,
        routeDistanceProvenance: RouteDistanceProvenance = .legacyUnknown
    ) {
        self.id = id
        self.metadata = metadata
        self.source = source
        self.routePoints = routePoints
        self.splits = splits
        self.summary = summary
        self.segments = segments
        self.analysisVersion = max(RunWorkout.legacyAnalysisVersion, analysisVersion)
        self.normalizationVersion = max(RunWorkout.legacyNormalizationVersion, normalizationVersion)
        self.analysisWarnings = analysisWarnings
        self.qualityDiagnostics = qualityDiagnostics
        self.routeDistanceSource = routeDistanceSource
        self.routeDistanceProvenance = routeDistanceProvenance
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
    public var hasHeartRateData: Bool {
        routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
    }
    public var hasCadenceData: Bool {
        routePoints.contains { point in
            point.cadence.map { $0.isFinite && $0 >= 0 } ?? false
        }
    }

    // MARK: - Backward-compatible Codable

    private enum CodingKeys: String, CodingKey {
        case id, metadata, source, routePoints, splits, summary, segments
        case analysisVersion, normalizationVersion, analysisWarnings
        case qualityDiagnostics, routeDistanceSource, routeDistanceProvenance
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
        normalizationVersion = try container.decodeIfPresent(Int.self, forKey: .normalizationVersion)
            ?? RunWorkout.legacyNormalizationVersion
        analysisWarnings = try container.decodeIfPresent([WorkoutAnalysisWarning].self, forKey: .analysisWarnings) ?? []
        qualityDiagnostics = try container.decodeIfPresent(
            RouteQualityDiagnostics.self,
            forKey: .qualityDiagnostics
        ) ?? .empty
        routeDistanceSource = try container.decodeIfPresent(
            RouteDistanceSource.self,
            forKey: .routeDistanceSource
        ) ?? .legacyUnknown
        routeDistanceProvenance = try container.decodeIfPresent(
            RouteDistanceProvenance.self,
            forKey: .routeDistanceProvenance
        ) ?? .legacyUnknown
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
        try container.encode(normalizationVersion, forKey: .normalizationVersion)
        try container.encode(analysisWarnings, forKey: .analysisWarnings)
        try container.encode(qualityDiagnostics, forKey: .qualityDiagnostics)
        try container.encode(routeDistanceSource, forKey: .routeDistanceSource)
        try container.encode(routeDistanceProvenance, forKey: .routeDistanceProvenance)
    }
}
