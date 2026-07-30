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
    public let movingTimeText: String
    public let pausedTimeText: String
    public let activePaceText: String
    public let movingPaceText: String
    public let elapsedPaceText: String
    public let elevationGainText: String
    public let elevationLossText: String
    public let heartRateText: String?
    public let maxHeartRateText: String?
    public let pointCountText: String
    /// Compact secondary line such as "Recorded laps: 5" when present.
    public let recordedLapCountText: String?
    public let segments: [SegmentCardItem]
    public let splits: [SplitCardItem]
    /// Optional truncation caption such as "First 5 of 12 splits".
    public let segmentsTruncationText: String?
    public let splitsTruncationText: String?
    public let privacyNote: String
    public let layout: PNGSummaryCardLayout
    public let includesMapImagery: Bool

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

    public static let metricsOnlyPrivacyNote =
        "Generated locally by RunPlay Studio • No cloud upload • No account required"

    public static let mapInclusivePrivacyNote =
        "Generated locally by RunPlay Studio • Map imagery via Apple Maps • No account required"

    public init(
        workout: RunWorkout,
        segments: [SegmentHighlight],
        layout: PNGSummaryCardLayout = .metricsOnly,
        includesMapImagery: Bool = false
    ) {
        appBranding = "RunPlay Studio"
        workoutTitle = workout.displayName
        sourceText = workout.source.displayName
        dateText = workout.metadata.startDate?.formatted(date: .long, time: .shortened) ?? "Unknown date"
        self.layout = layout
        self.includesMapImagery = includesMapImagery

        if workout.recordedLaps.isEmpty {
            recordedLapCountText = nil
        } else {
            recordedLapCountText = "Recorded laps: \(workout.recordedLaps.count)"
        }

        let summary = workout.summary
        distanceText = DisplayFormatter.formatDistanceKm(summary.totalDistanceMeters)
        elapsedTimeText = summary.formattedElapsed
        activeTimeText = summary.formattedActive
        movingTimeText = summary.formattedMoving
        pausedTimeText = summary.formattedPaused
        activePaceText = summary.formattedPace
        movingPaceText = summary.formattedMovingPace
        elapsedPaceText = summary.formattedElapsedPace
        let elevationAvailable = ElevationProfile(
            routePoints: workout.routePoints
        ).hasMeaningfulElevation
        elevationGainText = elevationAvailable
            ? DisplayFormatter.formatElevationDelta(summary.elevationGainMeters)
            : "N/A"
        elevationLossText = elevationAvailable
            ? DisplayFormatter.formatElevationDelta(-summary.elevationLossMeters)
            : "N/A"
        heartRateText = summary.averageHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value) : nil
        }
        maxHeartRateText = summary.maxHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value) : nil
        }
        pointCountText = "\(workout.routePoints.count) points"

        let maxSegments = layout.maxSegments
        let maxSplits = layout.maxSplits
        let totalSegments = segments.count
        let totalSplits = workout.splits.count

        self.segments = segments.prefix(maxSegments).map { segment in
            SegmentCardItem(
                icon: segment.type.icon,
                title: segment.title,
                value: segment.subtitle,
                color: segment.type.color
            )
        }
        if totalSegments > maxSegments {
            segmentsTruncationText = "First \(maxSegments) of \(totalSegments) segments"
        } else {
            segmentsTruncationText = nil
        }

        splits = workout.splits.prefix(maxSplits).map { split in
            SplitCardItem(
                index: split.splitIndex,
                distance: DisplayFormatter.formatDistanceKm(split.distanceMeters),
                elapsed: split.formattedElapsed,
                active: split.formattedActive,
                activePace: split.formattedPace,
                elapsedPace: split.formattedElapsedPace
            )
        }
        if totalSplits > maxSplits {
            splitsTruncationText = "First \(maxSplits) of \(totalSplits) splits"
        } else {
            splitsTruncationText = nil
        }

        if includesMapImagery {
            privacyNote = Self.mapInclusivePrivacyNote
        } else {
            privacyNote = Self.metricsOnlyPrivacyNote
        }
    }
}
