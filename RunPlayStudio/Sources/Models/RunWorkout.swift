import Foundation

/// A complete running workout with route data, analysis, and metadata.
struct RunWorkout: Identifiable, Codable, Hashable {
    let id: UUID
    var metadata: WorkoutMetadata
    var source: WorkoutSource
    var routePoints: [RoutePoint]
    var splits: [RunSplit]
    var summary: RunSummary
    var segments: [SegmentHighlight]

    init(
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

    /// Display name for the workout.
    var displayName: String {
        if let name = metadata.name, !name.isEmpty {
            return name
        }
        if let date = metadata.startDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return "Untitled Run"
    }

    /// Total number of route points.
    var pointCount: Int {
        routePoints.count
    }

    /// Whether the workout has altitude data.
    var hasAltitudeData: Bool {
        routePoints.contains { $0.altitudeMeters != nil }
    }

    /// Whether the workout has heart rate data.
    var hasHeartRateData: Bool {
        routePoints.contains { $0.heartRateBPM != nil }
    }

    /// Whether the workout has cadence data.
    var hasCadenceData: Bool {
        routePoints.contains { $0.cadence != nil }
    }
}
