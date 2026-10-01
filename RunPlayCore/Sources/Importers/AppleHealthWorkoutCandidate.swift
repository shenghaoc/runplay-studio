import Foundation

/// Why an Apple Health workout candidate is or is not offered for import.
///
/// Free-form strings are never the only representation: `statusDetail` adds
/// context, but selection, reporting, and tests key off this enum.
public enum AppleHealthCandidateStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// No overlapping window, within the export or in the library.
    case ready
    /// The window matches another workout's exactly: same start and same end.
    case duplicate
    /// The window overlaps another workout's without matching it.
    case possibleDuplicate

    /// Only an unflagged candidate is ever selected by default.
    ///
    /// Both duplicate states start unchecked: a workout the user already has, or
    /// one that overlaps something, is not something to import behind their back.
    public var isSelectedByDefault: Bool { self == .ready }

    public var userFacingSummary: String {
        switch self {
        case .ready: return "Ready"
        case .duplicate: return "Duplicate"
        case .possibleDuplicate: return "Possible duplicate"
        }
    }
}

/// Where a duplicate flag came from.
///
/// The flag is the same either way, but the reason differs and the user needs to
/// hear it: a match inside the export is two workouts in one file, while a match
/// against the library is a run they have already imported.
public enum AppleHealthDuplicateOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    case withinExport
    case existingLibrary

    public var userFacingDetail: String {
        switch self {
        case .withinExport: return "Overlaps another workout in this export"
        case .existingLibrary: return "Overlaps a run already in your library"
        }
    }
}

/// The time window of a run already in the library.
///
/// Only the window is carried: a stored run and an incoming workout are compared
/// by when they happened, so the two instants are the whole test. Holding a full
/// `RunWorkout` here would pin the library in memory for as long as a review
/// sheet is open, which this type exists to avoid.
public struct AppleHealthLibraryRunWindow: Hashable, Sendable {

    /// Whole seconds since the Unix epoch, in UTC.
    public var startSeconds: Int64
    /// Whole seconds since the Unix epoch, in UTC.
    public var endSeconds: Int64

    public init(startSeconds: Int64, endSeconds: Int64) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// The window of a run already in the library.
    ///
    /// Returns `nil` when the snapshot carries no usable start, or an end that
    /// does not follow it. Inventing a window for such a run would flag
    /// unrelated workouts as duplicates, so a run that cannot state when it
    /// happened is compared against nothing rather than against a guess.
    ///
    /// A missing end falls back to the start plus the summary's elapsed time,
    /// which is the same span every other consumer derives from those two
    /// fields. The result is rounded to whole seconds because that is the
    /// resolution both sides of the comparison are recorded at.
    public init?(workout: RunWorkout) {
        guard let start = workout.metadata.startDate else { return nil }
        let startSeconds = Int64(start.timeIntervalSince1970.rounded())

        let end: Date
        if let endDate = workout.metadata.endDate {
            end = endDate
        } else {
            let elapsed = workout.summary.totalElapsedSeconds
            guard elapsed.isFinite, elapsed >= 0 else { return nil }
            end = start.addingTimeInterval(elapsed)
        }
        let endSeconds = Int64(end.timeIntervalSince1970.rounded())
        guard endSeconds >= startSeconds else { return nil }

        self.init(startSeconds: startSeconds, endSeconds: endSeconds)
    }

    /// The windows of every library run that can state one, for a duplicate scan.
    ///
    /// Order follows the input and runs that cannot state a window are dropped,
    /// so the caller can compare counts without matching up indices.
    public static func windows(for workouts: [RunWorkout]) -> [AppleHealthLibraryRunWindow] {
        workouts.compactMap(AppleHealthLibraryRunWindow.init(workout:))
    }
}

/// One workout the export offers for import, with everything the review needs.
///
/// Deliberately not a `RunWorkout`: a candidate has no route points and no
/// analysis. It carries the workout's window, its source-reported statistics,
/// the archive path of its route if it has one, and the heart rate the scan
/// already joined to that window.
public struct AppleHealthWorkoutCandidate: Identifiable, Hashable, Sendable {

    /// Stable identity within one export.
    ///
    /// Content-derived plus the workout's ordinal, never the ordinal alone and
    /// never the route path. Two workouts in one export can share a window and
    /// an activity type, and only the ordinal separates them; conversely one
    /// route path is shared by two workouts in the measured export, so a path is
    /// not an identity and must not be used as one.
    public let id: String

    /// Zero-based ordinal in document order. Display order follows this.
    public let sourceIndex: Int

    /// The workout's own reported window.
    public var window: AppleHealthWorkoutWindow

    /// `WorkoutStatistics` rows, carried verbatim.
    public var statistics: [AppleHealthWorkoutStatistic]

    /// Archive-relative path of this workout's route file, when it names one.
    public var routeArchivePath: String?

    /// Heart rate the scan joined to this window, and nothing else.
    public var heartRate: [AppleHealthHeartRateReading]

    /// Distance the export itself reports for this workout, in meters.
    ///
    /// Nil when the workout carries no distance statistic, or one whose unit is
    /// not recognized. A route-less workout's only distance is this value.
    public var sourceDistanceMeters: Double?

    public var status: AppleHealthCandidateStatus

    /// Set whenever `status` is not `.ready`.
    public var duplicateOrigin: AppleHealthDuplicateOrigin?

    public init(
        id: String,
        sourceIndex: Int,
        window: AppleHealthWorkoutWindow,
        statistics: [AppleHealthWorkoutStatistic] = [],
        routeArchivePath: String? = nil,
        heartRate: [AppleHealthHeartRateReading] = [],
        sourceDistanceMeters: Double? = nil,
        status: AppleHealthCandidateStatus = .ready,
        duplicateOrigin: AppleHealthDuplicateOrigin? = nil
    ) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.window = window
        self.statistics = statistics
        self.routeArchivePath = routeArchivePath
        self.heartRate = heartRate
        self.sourceDistanceMeters = sourceDistanceMeters
        self.status = status
        self.duplicateOrigin = duplicateOrigin
    }

    /// Whether this candidate names a route file.
    ///
    /// This is the route-presence decision for a candidate, named for the same
    /// predicate the rest of the app uses. A candidate knows the archive path of
    /// its route, if it has one, and that reference is what decides whether its
    /// distance is derived from a route or taken from the export's own totals.
    public var hasRoute: Bool { routeArchivePath != nil }

    /// Where this candidate's distance and duration come from.
    ///
    /// A route-less candidate has no coordinates to measure, so its only
    /// distance is the one the export reported; a routed one is measured from
    /// its route like every other routed workout.
    public var distanceProvenance: SummaryDistanceProvenance {
        hasRoute ? .gpsDerived : .sourceReported
    }

    public var isSelectedByDefault: Bool { status.isSelectedByDefault }

    /// Context for `status`, or nil when the candidate is unflagged.
    public var statusDetail: String? {
        guard status != .ready else { return nil }
        return duplicateOrigin?.userFacingDetail
    }

    /// Record a duplicate match, keeping the strongest signal seen so far.
    ///
    /// An exact match outranks an overlap, and among exact matches a library
    /// match outranks an in-export one because it is the one the user can act on.
    /// A weaker match never downgrades a stronger one.
    mutating func apply(
        _ match: AppleHealthCandidateStatus,
        origin: AppleHealthDuplicateOrigin
    ) {
        switch match {
        case .duplicate:
            if status != .duplicate || origin == .existingLibrary {
                status = .duplicate
                duplicateOrigin = origin
            }
        case .possibleDuplicate:
            if status == .ready {
                status = .possibleDuplicate
                duplicateOrigin = origin
            }
        case .ready:
            break
        }
    }
}

/// Running candidates and the activity types intentionally excluded from review.
public struct AppleHealthCandidateBuildResult: Sendable {
    public let candidates: [AppleHealthWorkoutCandidate]
    public let excludedWorkoutsByActivityType: [String: Int]

    public var excludedWorkoutCount: Int {
        excludedWorkoutsByActivityType.values.reduce(0, +)
    }
}

/// Turns a streaming scan into the candidate list a review can act on.
///
/// The heart-rate join is not repeated here: the scan already attached to each
/// workout the readings that overlap its window, using its own bounded index, so
/// a candidate carries that result and this builder adds no second path to
/// heart rate.
public enum AppleHealthWorkoutCandidateBuilder {

    /// Statistic types that carry a workout's own distance.
    private static let distanceStatisticTypes: Set<String> = [
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierDistanceSwimming",
    ]

    /// Build running candidates, flagging duplicates after activity filtering.
    ///
    /// - Parameter existingLibraryRuns: windows of runs already stored. Overlap
    ///   with one of these flags the candidate exactly as an in-export overlap
    ///   does; passing none simply means nothing to compare against.
    public static func candidates(
        from scan: AppleHealthExportScan,
        existingLibraryRuns: [AppleHealthLibraryRunWindow] = []
    ) -> [AppleHealthWorkoutCandidate] {
        build(from: scan, existingLibraryRuns: existingLibraryRuns).candidates
    }

    /// Keep the running activity identifier regardless of route presence or
    /// indoor metadata. Unknown and non-running identifiers are counted rather
    /// than treated as runs. The parser continues to expose every activity type.
    public static func build(
        from scan: AppleHealthExportScan,
        existingLibraryRuns: [AppleHealthLibraryRunWindow] = []
    ) -> AppleHealthCandidateBuildResult {
        var candidates: [AppleHealthWorkoutCandidate] = []
        var excluded: [String: Int] = [:]
        for (index, workout) in scan.workouts.enumerated() {
            guard workout.window.activityType == "HKWorkoutActivityTypeRunning" else {
                excluded[workout.window.activityType, default: 0] += 1
                continue
            }
            // Keep the document ordinal, so filtering cannot change identity.
            candidates.append(makeCandidate(workout, index: index))
        }

        // Within the export. Each pair is visited once and both sides flagged:
        // with two identical windows neither is knowably the original, so
        // choosing one to keep would be a guess, and the user is the one who can
        // tell them apart.
        for first in candidates.indices {
            for second in candidates.indices where second > first {
                guard let match = classify(
                    start: candidates[first].window.startSeconds,
                    end: candidates[first].window.endSeconds,
                    otherStart: candidates[second].window.startSeconds,
                    otherEnd: candidates[second].window.endSeconds
                ) else { continue }
                candidates[first].apply(match, origin: .withinExport)
                candidates[second].apply(match, origin: .withinExport)
            }
        }

        // Against runs already stored.
        for index in candidates.indices {
            for run in existingLibraryRuns {
                guard let match = classify(
                    start: candidates[index].window.startSeconds,
                    end: candidates[index].window.endSeconds,
                    otherStart: run.startSeconds,
                    otherEnd: run.endSeconds
                ) else { continue }
                candidates[index].apply(match, origin: .existingLibrary)
            }
        }

        return AppleHealthCandidateBuildResult(
            candidates: candidates,
            excludedWorkoutsByActivityType: excluded
        )
    }

    private static func makeCandidate(
        _ workout: AppleHealthExportScan.WorkoutEntry,
        index: Int
    ) -> AppleHealthWorkoutCandidate {
        AppleHealthWorkoutCandidate(
            id: identity(window: workout.window, index: index),
            sourceIndex: index,
            window: workout.window,
            statistics: workout.statistics,
            routeArchivePath: workout.routeArchivePath,
            heartRate: workout.heartRate,
            sourceDistanceMeters: distance(from: workout.statistics)
        )
    }

    private static func identity(window: AppleHealthWorkoutWindow, index: Int) -> String {
        "\(window.startSeconds)-\(window.endSeconds)-\(window.activityType)-\(index)"
    }

    /// Classify two windows, or nil when they do not overlap at all.
    ///
    /// Overlap is strict: a window that merely touches another's edge is
    /// adjacent, not overlapping. The export records back-to-back workouts that
    /// share a boundary second, and counting that as a duplicate would flag
    /// ordinary consecutive runs.
    private static func classify(
        start: Int64,
        end: Int64,
        otherStart: Int64,
        otherEnd: Int64
    ) -> AppleHealthCandidateStatus? {
        if start == otherStart, end == otherEnd {
            return .duplicate
        }
        if start < otherEnd, otherStart < end {
            return .possibleDuplicate
        }
        return nil
    }

    /// The first distance statistic the export reports for the workout.
    ///
    /// First rather than summed: if an export ever carried two distance rows for
    /// one workout they would describe the same distance, and adding them would
    /// double it.
    private static func distance(
        from statistics: [AppleHealthWorkoutStatistic]
    ) -> Double? {
        for statistic in statistics where distanceStatisticTypes.contains(statistic.type) {
            guard let sum = statistic.sum, sum.isFinite else { continue }
            guard let meters = meters(from: sum, unit: statistic.unit) else { continue }
            return meters
        }
        return nil
    }

    /// Convert a reported distance to meters, or nil for a unit this does not know.
    ///
    /// An unrecognized unit is refused rather than assumed: reading a mile as a
    /// kilometer would understate the distance by a third, and a wrong number is
    /// worse than no number.
    private static func meters(from value: Double, unit: String?) -> Double? {
        switch unit?.lowercased() {
        case "km": return value * 1_000
        case "m": return value
        case "mi": return value * 1_609.344
        default: return nil
        }
    }
}
