import Foundation

/// Pure model for the PNG summary card.
///
/// Contains everything needed to render the summary card without
/// depending on live workout state or UI frameworks.
public struct ExportSummaryCardModel: Sendable {
    public let appBranding: String
    public let workoutTitle: String
    public let dateText: String
    public let sourceText: String

    // Main metrics
    public let distanceText: String
    public let durationText: String
    public let paceText: String
    public let elevationGainText: String
    public let elevationLossText: String
    public let heartRateText: String?
    public let maxHeartRateText: String?
    public let pointCountText: String

    // Segments
    public let segments: [SegmentCardItem]

    // Splits summary
    public let splits: [SplitCardItem]

    // Footer
    public let privacyNote: String

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
        public let pace: String
        public let duration: String
    }

    // ⚡ Bolt: Cache date formatter to avoid expensive initialization on struct init
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    /// Build from workout and detected segments.
    public init(workout: RunWorkout, segments: [SegmentHighlight]) {
        self.appBranding = "RunPlay Studio"
        self.workoutTitle = workout.displayName
        self.sourceText = workout.source.displayName

        // Date
        if let date = workout.metadata.startDate {
            self.dateText = ExportSummaryCardModel.dateFormatter.string(from: date)
        } else {
            self.dateText = "Unknown date"
        }

        // Main metrics
        self.distanceText = DisplayFormatter.formatDistanceKm(workout.summary.totalDistanceMeters)
        self.durationText = workout.summary.formattedDuration
        self.paceText = workout.summary.formattedPace
        self.elevationGainText = DisplayFormatter.formatElevationDelta(workout.summary.elevationGainMeters)
        self.elevationLossText = DisplayFormatter.formatElevationDelta(-workout.summary.elevationLossMeters)

        if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite {
            self.heartRateText = DisplayFormatter.formatHeartRate(avgHR)
        } else {
            self.heartRateText = nil
        }

        if let maxHR = workout.summary.maxHeartRateBPM, maxHR.isFinite {
            self.maxHeartRateText = DisplayFormatter.formatHeartRate(maxHR)
        } else {
            self.maxHeartRateText = nil
        }

        self.pointCountText = "\(workout.routePoints.count) points"

        // Segments
        self.segments = segments.prefix(5).map { seg in
            SegmentCardItem(
                icon: seg.type.icon,
                title: seg.title,
                value: seg.subtitle,
                color: seg.type.color
            )
        }

        // Splits
        self.splits = workout.splits.prefix(10).map { split in
            SplitCardItem(
                index: split.splitIndex,
                distance: DisplayFormatter.formatDistanceKm(split.distanceMeters),
                pace: split.formattedPace,
                duration: split.formattedElapsed
            )
        }

        self.privacyNote = "Generated locally by RunPlay Studio • No cloud upload • No account required"
    }
}
