import Foundation

/// Pure model for the PNG summary card.
///
/// Contains everything needed to render the summary card without
/// depending on live workout state or UI frameworks.
public struct ExportSummaryCardModel {
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

    public struct SegmentCardItem: Identifiable {
        public let id = UUID()
        public let icon: String
        public let title: String
        public let value: String
        public let color: String
    }

    public struct SplitCardItem: Identifiable {
        public let id = UUID()
        public let index: Int
        public let distance: String
        public let pace: String
        public let duration: String
    }

    /// Build from workout and detected segments.
    public init(workout: RunWorkout, segments: [SegmentHighlight]) {
        self.appBranding = "RunPlay Studio"
        self.workoutTitle = workout.displayName
        self.sourceText = workout.source.displayName

        // Date
        if let date = workout.metadata.startDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .short
            self.dateText = formatter.string(from: date)
        } else {
            self.dateText = "Unknown date"
        }

        // Main metrics
        self.distanceText = String(format: "%.2f km", workout.summary.totalDistanceMeters / 1000)
        self.durationText = workout.summary.formattedDuration
        self.paceText = workout.summary.formattedPace
        self.elevationGainText = String(format: "+%.0f m", workout.summary.elevationGainMeters)
        self.elevationLossText = String(format: "-%.0f m", workout.summary.elevationLossMeters)

        if let avgHR = workout.summary.averageHeartRateBPM {
            self.heartRateText = String(format: "%.0f bpm", avgHR)
        } else {
            self.heartRateText = nil
        }

        if let maxHR = workout.summary.maxHeartRateBPM {
            self.maxHeartRateText = String(format: "%.0f bpm", maxHR)
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
                distance: String(format: "%.2f km", split.distanceMeters / 1000),
                pace: split.formattedPace,
                duration: split.formattedElapsed
            )
        }

        self.privacyNote = "Generated locally by RunPlay Studio • No cloud upload • No account required"
    }
}
