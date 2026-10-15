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

    /// The statistic type that carries a run's own distance. Only running
    /// workouts become candidates, so a cycling or swimming distance row a run
    /// happens to carry is not its distance.
    private static let distanceStatisticType = "HKQuantityTypeIdentifierDistanceWalkingRunning"

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

        flagDuplicates(in: &candidates, existingLibraryRuns: existingLibraryRuns)

        return AppleHealthCandidateBuildResult(
            candidates: candidates,
            excludedWorkoutsByActivityType: excluded
        )
    }

    /// Flag each candidate whose window matches another candidate's or a stored
    /// run's, and return how many stored windows the lookups read.
    ///
    /// Comparing every pair would cost billions of comparisons for tens of
    /// thousands of workouts, and an export is untrusted: nothing caps how many
    /// workouts it holds or how many of them overlap. So the windows are indexed
    /// instead. An identical window is a dictionary lookup, and an overlapping
    /// one is a binary search in an `OverlapIndex`, so the work grows with the
    /// number of windows, not with the number of pairs or overlaps. The count is
    /// returned so a test can show that.
    @discardableResult
    static func flagDuplicates(
        in candidates: inout [AppleHealthWorkoutCandidate],
        existingLibraryRuns: [AppleHealthLibraryRunWindow]
    ) -> Int {
        var reads = 0
        let windows = candidates.map { Span(start: $0.window.startSeconds, end: $0.window.endSeconds) }
        let stored = existingLibraryRuns.map { Span(start: $0.startSeconds, end: $0.endSeconds) }
        var copies: [Span: Int] = [:]
        for window in windows {
            copies[window, default: 0] += 1
        }
        let storedWindows = Set(stored)
        let exportIndex = OverlapIndex(windows)
        let storedIndex = OverlapIndex(stored)

        // Matches are applied export first, then library, which is the order
        // `apply` ranks them in; a candidate's flags depend on nothing else.
        for index in candidates.indices {
            let window = windows[index]
            // Within the export. Both sides of a match are flagged: with two
            // identical windows neither is knowably the original, so choosing one
            // to keep would be a guess, and the user is the one who can tell them
            // apart.
            if copies[window, default: 0] > 1 {
                candidates[index].apply(.duplicate, origin: .withinExport)
            }
            if exportIndex.overlaps(window, excluding: index, reads: &reads) {
                candidates[index].apply(.possibleDuplicate, origin: .withinExport)
            }
            // Against runs already stored.
            if storedWindows.contains(window) {
                candidates[index].apply(.duplicate, origin: .existingLibrary)
            }
            if storedIndex.overlaps(window, excluding: nil, reads: &reads) {
                candidates[index].apply(.possibleDuplicate, origin: .existingLibrary)
            }
        }
        return reads
    }

    /// A window's two instants, in whole seconds.
    private struct Span: Hashable {
        var start: Int64
        var end: Int64
    }

    /// Windows sorted by start, with the latest end among each prefix of them.
    ///
    /// Two windows overlap when each starts before the other ends. Overlap is
    /// strict: a window that merely touches another's edge is adjacent, not
    /// overlapping. The export records back-to-back workouts that share a
    /// boundary second, and counting that as a duplicate would flag ordinary
    /// consecutive runs. An identical window overlaps too when it has any
    /// length, but it is a duplicate, which outranks an overlap.
    private struct OverlapIndex {
        /// Starts, ascending.
        private let starts: [Int64]
        /// For the first `k` windows in start order: the latest end, the window
        /// that has it, and the latest end among the rest, so a window can ask
        /// about every window but itself.
        private let latest: [(end: Int64, owner: Int, runnerUp: Int64)]

        init(_ spans: [Span]) {
            let order = spans.indices.sorted { (spans[$0].start, $0) < (spans[$1].start, $1) }
            starts = order.map { spans[$0].start }
            var latest = [(end: Int64.min, owner: -1, runnerUp: Int64.min)]
            latest.reserveCapacity(spans.count + 1)
            for index in order {
                let previous = latest[latest.count - 1]
                let end = spans[index].end
                if end > previous.end {
                    latest.append((end: end, owner: index, runnerUp: previous.end))
                } else {
                    latest.append((
                        end: previous.end,
                        owner: previous.owner,
                        runnerUp: max(previous.runnerUp, end)
                    ))
                }
            }
            self.latest = latest
        }

        /// Whether a window other than the one at `excluded` overlaps `span`.
        func overlaps(_ span: Span, excluding excluded: Int?, reads: inout Int) -> Bool {
            // The windows that start before `span` ends are a prefix of start
            // order, and one of them overlaps `span` exactly when the latest end
            // among them comes after `span` starts.
            var low = 0
            var high = starts.count
            while low < high {
                let mid = low + (high - low) / 2
                reads += 1
                if starts[mid] < span.end {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            reads += 1
            let prefix = latest[low]
            let latestEnd = prefix.owner == excluded ? prefix.runnerUp : prefix.end
            return latestEnd > span.start
        }
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

    /// The first distance statistic the export reports for the workout.
    ///
    /// First rather than summed: if an export ever carried two distance rows for
    /// one workout they would describe the same distance, and adding them would
    /// double it.
    private static func distance(
        from statistics: [AppleHealthWorkoutStatistic]
    ) -> Double? {
        for statistic in statistics where statistic.type == distanceStatisticType {
            guard let sum = statistic.sum, sum.isFinite else { continue }
            // A negative sum is no distance, and a huge finite one can overflow to
            // infinity in the conversion, so the converted value is checked too.
            guard let meters = meters(from: sum, unit: statistic.unit),
                  meters.isFinite, meters >= 0 else { continue }
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
