import Foundation

/// Pure model for the PNG summary card.
///
/// Contains everything needed to render the summary card without
/// depending on live workout state or UI frameworks.
struct ExportSummaryCardModel {
    let appBranding: String
    let workoutTitle: String
    let dateText: String
    let sourceText: String

    // Main metrics
    let distanceText: String
    let durationText: String
    let paceText: String
    let elevationGainText: String
    let elevationLossText: String
    let heartRateText: String?
    let maxHeartRateText: String?
    let pointCountText: String

    // Segments
    let segments: [SegmentCardItem]

    // Splits summary
    let splits: [SplitCardItem]

    // Footer
    let privacyNote: String

    struct SegmentCardItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let value: String
        let color: String
    }

    struct SplitCardItem: Identifiable {
        let id = UUID()
        let index: Int
        let distance: String
        let pace: String
        let duration: String
    }

    /// Build from workout and detected segments.
    init(workout: RunWorkout, segments: [SegmentHighlight]) {
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
