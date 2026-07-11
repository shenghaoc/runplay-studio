import Foundation

/// A complete running workout with route data, analysis, and metadata.
public struct RunWorkout: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var metadata: WorkoutMetadata
    public var source: WorkoutSource
    public var routePoints: [RoutePoint]
    public var splits: [RunSplit]
    public var summary: RunSummary
    public var segments: [SegmentHighlight]

    public init(
        id: UUID = UUID(),
        metadata: WorkoutMetadata = WorkoutMetadata(),
        source: WorkoutSource = .unknown,
        routePoints: [RoutePoint] = [],
        splits: [RunSplit] = [],
        summary: RunSummary = RunSummary(),
        segments: [SegmentHighlight] = []
    ) {
        self.id = id
        self.metadata = metadata
        self.source = source
        self.routePoints = routePoints
        self.splits = splits
        self.summary = summary
        self.segments = segments
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

    /// Total number of route points.
    public var pointCount: Int {
        routePoints.count
    }

    /// Whether the workout has altitude data.
    public var hasAltitudeData: Bool {
        routePoints.contains { $0.altitudeMeters != nil }
    }

    /// Whether the workout has heart rate data.
    public var hasHeartRateData: Bool {
        routePoints.contains { $0.heartRateBPM != nil }
    }

    /// Whether the workout has cadence data.
    public var hasCadenceData: Bool {
        routePoints.contains { $0.cadence != nil }
    }
}
