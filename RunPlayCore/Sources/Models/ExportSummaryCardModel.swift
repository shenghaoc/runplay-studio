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

    /// Cached long-date/short-time formatter for the export card's date line
    /// in the app's locale and time zone.
    ///
    /// Kept as a cached `DateFormatter` for the same reason as
    /// `RunWorkout.displayFormatter`: `Date.formatted(date:time:)` measures slower and
    /// buys nothing here. See the 2026-07-30 entry in `.jules/bolt.md`. The
    /// `.short` time style follows the locale's and the user's 12/24-hour
    /// convention ("14:30" in zh_CN, "2:30 PM" in en_US).
    private static let dateFormatter: DateFormatter = makeDateFormatter(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    private static func makeDateFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }

    /// Footer note for a metrics-only card, in the app's language.
    public static var metricsOnlyPrivacyNote: String {
        metricsOnlyPrivacyNote(locale: nil)
    }

    /// Footer note for a card that embeds Apple Maps imagery, in the app's language.
    public static var mapInclusivePrivacyNote: String {
        mapInclusivePrivacyNote(locale: nil)
    }

    static func metricsOnlyPrivacyNote(locale: Locale?) -> String {
        coreLocalized("Generated locally by RunPlay Studio • No cloud upload • No account required", locale: locale)
    }

    static func mapInclusivePrivacyNote(locale: Locale?) -> String {
        coreLocalized("Generated locally by RunPlay Studio • Map imagery via Apple Maps • No account required", locale: locale)
    }

    /// Builds the card's text.
    ///
    /// - Parameters:
    ///   - locale: Language and formatting for every string on the card; `nil`
    ///     uses the app's language and current locale. Exports pass `nil`;
    ///     tests pin a locale so the output is deterministic.
    ///   - timeZone: Zone for the start date line; `nil` uses the current zone.
    public init(
        workout: RunWorkout,
        segments: [SegmentHighlight],
        layout: PNGSummaryCardLayout = .metricsOnly,
        includesMapImagery: Bool = false,
        locale: Locale? = nil,
        timeZone: TimeZone? = nil
    ) {
        appBranding = "RunPlay Studio"
        workoutTitle = workout.displayName
        sourceText = workout.source.displayName
        let dateFormatter = (locale == nil && timeZone == nil)
            ? Self.dateFormatter
            : Self.makeDateFormatter(
                locale: locale ?? .autoupdatingCurrent,
                timeZone: timeZone ?? .autoupdatingCurrent
            )
        dateText = workout.metadata.startDate.map(dateFormatter.string)
            ?? coreLocalized("Unknown date", locale: locale)
        self.layout = layout
        self.includesMapImagery = includesMapImagery

        if workout.recordedLaps.isEmpty {
            recordedLapCountText = nil
        } else {
            let lapCount = workout.recordedLaps.count
            recordedLapCountText = coreLocalized("Recorded laps: \(lapCount)", locale: locale)
        }

        let summary = workout.summary
        distanceText = DisplayFormatter.formatDistanceKm(summary.totalDistanceMeters, locale: locale)
        elapsedTimeText = summary.formattedElapsed
        activeTimeText = summary.formattedActive
        movingTimeText = summary.formattedMoving
        pausedTimeText = summary.formattedPaused
        activePaceText = DisplayFormatter.formatPace(summary.averagePaceSecondsPerKilometer, locale: locale)
        movingPaceText = DisplayFormatter.formatPace(summary.movingPaceSecondsPerKilometer, locale: locale)
        elapsedPaceText = DisplayFormatter.formatPace(summary.elapsedPaceSecondsPerKilometer, locale: locale)
        let elevationAvailable = ElevationProfile(
            routePoints: workout.routePoints
        ).hasMeaningfulElevation
        let notAvailable = coreLocalized("N/A", locale: locale)
        elevationGainText = elevationAvailable
            ? DisplayFormatter.formatElevationDelta(summary.elevationGainMeters, locale: locale)
            : notAvailable
        elevationLossText = elevationAvailable
            ? DisplayFormatter.formatElevationDelta(-summary.elevationLossMeters, locale: locale)
            : notAvailable
        heartRateText = summary.averageHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value, locale: locale) : nil
        }
        maxHeartRateText = summary.maxHeartRateBPM.flatMap { value in
            value.isFinite ? DisplayFormatter.formatHeartRate(value, locale: locale) : nil
        }
        let pointCount = workout.routePoints.count
        pointCountText = coreLocalized("\(pointCount) points", locale: locale)

        let maxSegments = layout.maxSegments
        let maxSplits = layout.maxSplits
        let totalSegments = segments.count
        let totalSplits = workout.splits.count

        self.segments = segments.prefix(maxSegments).map { segment in
            SegmentCardItem(
                icon: segment.type.icon,
                title: segment.displayTitle(locale: locale),
                value: segment.displaySubtitle(locale: locale),
                color: segment.type.color
            )
        }
        if totalSegments > maxSegments {
            segmentsTruncationText = coreLocalized(
                "First \(maxSegments) of \(totalSegments) segments",
                locale: locale
            )
        } else {
            segmentsTruncationText = nil
        }

        splits = workout.splits.prefix(maxSplits).map { split in
            SplitCardItem(
                index: split.splitIndex,
                distance: DisplayFormatter.formatDistanceKm(split.distanceMeters, locale: locale),
                elapsed: split.formattedElapsed,
                active: split.formattedActive,
                activePace: split.formattedPace,
                elapsedPace: split.formattedElapsedPace
            )
        }
        if totalSplits > maxSplits {
            splitsTruncationText = coreLocalized(
                "First \(maxSplits) of \(totalSplits) splits",
                locale: locale
            )
        } else {
            splitsTruncationText = nil
        }

        if includesMapImagery {
            privacyNote = Self.mapInclusivePrivacyNote(locale: locale)
        } else {
            privacyNote = Self.metricsOnlyPrivacyNote(locale: locale)
        }
    }
}
