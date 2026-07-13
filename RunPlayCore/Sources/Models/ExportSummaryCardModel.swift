import Foundation

/// Pure model for the PNG summary card.
public struct ExportSummaryCardModel: Sendable {
    public let appBranding: String
    public let workoutTitle: String
    public let dateText: String
    public let sourceText: String
    public let distanceText: String
    public let elapsedTimeText: String
    public let activeTimeText: String
    public let pausedTimeText: String
    public let activePaceText: String
    public let elapsedPaceText: String
    public let elevationGainText: String
    public let elevationLossText: String
    public let heartRateText: String?
    public let maxHeartRateText: String?
    public let pointCountText: String
    public let segments: [SegmentCardItem]
    public let splits: [SplitCardItem]
    public let privacyNote: String

    /// Source-compatible display aliases.
    public var durationText: String { elapsedTimeText }
    public var paceText: String { activePaceText }

    public struct SegmentCardItem: Identifiable, Sendable {
        public let id = UUID()
        public let icon: String
        public let title: String
        public let value: String
        public let color: String
    }

    public struct SplitCardItem: Identifiable, Sendable {
        public let id = UUID()
        public let index: Int
        public let distance: String
        public let elapsed: String
        public let active: String
        public let activePace: String
        public let elapsedPace: String
        public var pace: String { activePace }
        public var duration: String { elapsed }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    public init(workout: RunWorkout, segments: [SegmentHighlight]) {
        appBranding = "RunPlay Studio"
        workoutTitle = workout.displayName
        sourceText = workout.source.displayName
        dateText = workout.metadata.startDate.map(Self.dateFormatter.string) ?? "Unknown date"

        let summary = workout.summary
        distanceText = DisplayFormatter.formatDistanceKm(summary.totalDistanceMeters)
        elapsedTimeText = summary.formattedElapsed
        activeTimeText = summary.formattedActive
        pausedTimeText = summary.formattedPaused
        activePaceText = summary.formattedPace
        elapsedPaceText = summary.formattedElapsedPace
        elevationGainText = DisplayFormatter.formatElevationDelta(summary.elevationGainMeters)
        elevationLossText = DisplayFormatter.formatElevationDelta(-summary.elevationLossMeters)
        heartRateText = summary.averageHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value) : nil
        }
        maxHeartRateText = summary.maxHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value) : nil
        }
        pointCountText = "\(workout.routePoints.count) points"

        self.segments = segments.prefix(5).map { segment in
            SegmentCardItem(
                icon: segment.type.icon,
                title: segment.title,
                value: segment.subtitle,
                color: segment.type.color
            )
        }
        splits = workout.splits.prefix(10).map { split in
            SplitCardItem(
                index: split.splitIndex,
                distance: DisplayFormatter.formatDistanceKm(split.distanceMeters),
                elapsed: split.formattedElapsed,
                active: split.formattedActive,
                activePace: split.formattedPace,
                elapsedPace: split.formattedElapsedPace
            )
        }
        privacyNote = "Generated locally by RunPlay Studio • No cloud upload • No account required"
    }
}
