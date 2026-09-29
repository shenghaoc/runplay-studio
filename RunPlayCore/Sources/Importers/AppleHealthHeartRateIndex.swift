import Foundation

/// One heart-rate reading held in the import-time index.
///
/// Deliberately **not** `HeartRateSample`: that type is a reading in one
/// workout's elapsed-time domain, whereas a reading here is still an absolute
/// instant in the export's own timeline and has not been attributed to any
/// workout. The join that converts one into the other is a later layer's work.
///
/// The layout is 24 bytes, and that size is what makes the single-pass ceiling
/// meaningful: at `AppleHealthHeartRateIndex.maximumSampleCount` the entire
/// index is 48 MB.
public struct AppleHealthHeartRateReading: Equatable, Hashable, Sendable {

    /// Whole seconds since the Unix epoch, in UTC.
    ///
    /// Storing whole seconds loses nothing here: every one of the 871,413
    /// heart-rate timestamps in the measured export matched the strict 25-byte
    /// `yyyy-MM-dd HH:mm:ss ±hhmm` form with zero parse failures, so the source
    /// carries no sub-second precision to drop.
    public var startSeconds: Int64

    /// Length of the reading in seconds; zero when it is instantaneous.
    ///
    /// Kept rather than assumed away because 0.273% of readings in the measured
    /// export carry a real duration, up to 3,061 seconds. A window query can
    /// then test span overlap explicitly instead of silently treating a
    /// 51-minute reading as a point and dropping its contribution.
    public var durationSeconds: UInt32

    /// Beats per minute exactly as written.
    ///
    /// A `Double` rather than a scaled integer because 1.3% of readings carry up
    /// to four decimal places. Scaling would fit today's range (maximum observed
    /// 210.0) but would silently round a future fifth decimal, and 8 bytes per
    /// sample is not a price worth paying for that risk.
    public var beatsPerMinute: Double

    public init(startSeconds: Int64, durationSeconds: UInt32, beatsPerMinute: Double) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.beatsPerMinute = beatsPerMinute
    }

    /// Last second this reading covers.
    ///
    /// Saturates rather than wrapping, so a hostile duration cannot turn the end
    /// of a span into a value before its start and make it unqueryable.
    public var endSeconds: Int64 {
        let span = Int64(durationSeconds)
        guard startSeconds <= Int64.max - span else { return Int64.max }
        return startSeconds + span
    }
}

/// A workout's time window exactly as the export reports it.
///
/// Carried alongside the heart-rate index because the two are joined by time
/// range only — the export provides no identifier linking a heart-rate record
/// to a workout, so the window *is* the link.
public struct AppleHealthWorkoutWindow: Equatable, Hashable, Sendable {

    /// Whole seconds since the Unix epoch, in UTC.
    public var startSeconds: Int64
    /// Whole seconds since the Unix epoch, in UTC.
    public var endSeconds: Int64

    /// `workoutActivityType` verbatim, for example
    /// `HKWorkoutActivityTypeRunning`.
    ///
    /// Stored untranslated on purpose: deciding which activity types this
    /// product imports is a policy question that belongs to a later layer, not
    /// to the scan.
    public var activityType: String

    /// UTC offset of `startDate`, in seconds east of Greenwich.
    ///
    /// Trends buckets a workout by its recorded local date, and one instant
    /// seen from two zones is two different local days, so the offset is kept
    /// rather than folded into `startSeconds`. It is the offset written on the
    /// start, which is the instant `WorkoutMetadata.recordedUTCOffsetSeconds`
    /// records; the end's offset is not a second value.
    public var utcOffsetSeconds: Int

    public init(
        startSeconds: Int64,
        endSeconds: Int64,
        activityType: String,
        utcOffsetSeconds: Int
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.activityType = activityType
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

/// The compact single-pass heart-rate buffer, with a fixed ceiling.
///
/// ## Why a buffer at all
///
/// Heart-rate records cannot be attributed to a workout while they are being
/// read. Every one of the 871,413 heart-rate records in the measured export
/// appears **before** the first `Workout` element (tag index 1 versus
/// 4,043,638), so the windows that would define attribution do not exist yet
/// when the readings arrive. They must be held.
///
/// A streaming merge join — the usual way to avoid holding anything — is
/// impossible here, and not for lack of trying: the readings are **not**
/// chronological in document order. Measured over the real export, 736,464 of
/// 871,413 samples (84.5%) are not in their final sorted position, the longest
/// non-decreasing prefix is 25 samples, and backward steps reach 3.4 years. So
/// the readings are accumulated and sorted, then queried by range.
///
/// ## Why a ceiling
///
/// Unbounded accumulation is the one property this type refuses to have. The
/// buffer holds the *whole-life* heart-rate history, not one workout's, so its
/// size is a function of how long the user has worn a device — not of anything
/// this app controls. Above `maximumSampleCount` the index stops growing and
/// reports that it did, and the caller re-scans in filtered mode, which keeps
/// only readings inside a workout window (measured: 65,828 of 871,413, or 7.6%,
/// about 1.6 MB) at the cost of one extra read of the document.
///
/// The ceiling is sized from measurement, not guesswork: 871,413 readings over a
/// 799-day span, so 2,000,000 is 2.3× the observed count and 48 MB — modest
/// beside what this product already allocates, since
/// `WorkoutImportResourceLimits.maxRoutePointCount` permits 1,000,000
/// `RoutePoint` values and a `RoutePoint` carries a `UUID`, a `Date` and some
/// eighteen numeric fields. It lives here rather than in
/// `WorkoutImportResourceLimits` because those are product limits shared by
/// every importer, while this one is a property of this format's index.
///
/// ## Why internal
///
/// Nothing here is product API. The whole-life readings this type holds are
/// exactly what the import must *not* keep once a workout window has been
/// joined, so the type is reachable only from this module and never appears in
/// a public signature. The scan publishes per-workout readings only; see
/// `AppleHealthExportScan.WorkoutEntry.heartRate`.
struct AppleHealthHeartRateIndex: Sendable {

    /// Readings held before the index refuses to grow further.
    ///
    /// The production ceiling. Sized from measurement: the real export holds
    /// 871,413 heart-rate readings across a 799-day span, so this is 2.3× the
    /// observed count and 48 MB at 24 bytes per reading.
    static let maximumSampleCount = 2_000_000

    /// The ceiling this instance enforces.
    ///
    /// Injectable because the two-pass fallback is the whole point of having a
    /// ceiling, and a test that cannot reach 2,000,000 readings would leave that
    /// fallback asserted rather than executed. Every test of the fallback runs
    /// this real code path at a small ceiling, so the behaviour under test is the
    /// shipped behaviour and not a parallel implementation.
    let sampleCountCeiling: Int

    private var readings: [AppleHealthHeartRateReading] = []
    private var windowFilter: [AppleHealthWorkoutWindow]?

    /// Set when the ceiling was reached and the buffer was released.
    ///
    /// The caller must then re-scan in filtered mode. This is a signal, not an
    /// error: the scan is still valid, it just has to run again.
    private(set) var releasedByCeiling = false

    /// Readings offered to the index, including ones a window filter rejected.
    private(set) var offeredCount = 0

    /// Readings the index actually retained.
    var retainedCount: Int { readings.count }

    /// The longest retained duration, used to bound a range query's lookback.
    private(set) var maximumDurationSeconds: UInt32 = 0

    /// - Parameter sampleCountCeiling: readings held before the index refuses to
    ///   grow. Defaults to `maximumSampleCount`; tests lower it to reach the
    ///   fallback without generating millions of readings.
    init(sampleCountCeiling: Int = AppleHealthHeartRateIndex.maximumSampleCount) {
        self.sampleCountCeiling = max(0, sampleCountCeiling)
    }

    /// Restrict subsequent appends to readings overlapping one of `windows`.
    ///
    /// Called when starting the second pass, and it releases whatever the first
    /// pass accumulated: the whole point of the fallback is that the first
    /// pass's buffer was too large to keep.
    mutating func beginFilteredPass(windows: [AppleHealthWorkoutWindow]) {
        readings.removeAll(keepingCapacity: false)
        windowFilter = windows.isEmpty ? [] : windows
        releasedByCeiling = false
        offeredCount = 0
        maximumDurationSeconds = 0
    }

    /// Add a reading, subject to the window filter and the ceiling.
    ///
    /// Once the ceiling is reached the buffer is released and further readings
    /// are counted but not retained, so a document larger than the ceiling
    /// cannot grow this index without bound.
    mutating func append(_ reading: AppleHealthHeartRateReading) {
        offeredCount += 1

        if let windows = windowFilter, !overlapsAnyWindow(reading, windows: windows) {
            return
        }

        guard readings.count < sampleCountCeiling else {
            releasedByCeiling = true
            readings.removeAll(keepingCapacity: false)
            maximumDurationSeconds = 0
            return
        }

        readings.append(reading)
        if reading.durationSeconds > maximumDurationSeconds {
            maximumDurationSeconds = reading.durationSeconds
        }
    }

    /// Sort the retained readings and hand back the queryable form.
    ///
    /// Sorting is what makes the range query a binary search rather than a
    /// scan, and it is required because the source order is not chronological
    /// (see the type comment). Ties break on duration so the result is
    /// deterministic for a given input regardless of Swift's sort stability.
    mutating func finalize() -> AppleHealthHeartRateLookup {
        readings.sort { lhs, rhs in
            if lhs.startSeconds != rhs.startSeconds {
                return lhs.startSeconds < rhs.startSeconds
            }
            return lhs.durationSeconds < rhs.durationSeconds
        }
        return AppleHealthHeartRateLookup(
            readings: readings,
            maximumDurationSeconds: maximumDurationSeconds
        )
    }

    private func overlapsAnyWindow(
        _ reading: AppleHealthHeartRateReading,
        windows: [AppleHealthWorkoutWindow]
    ) -> Bool {
        let readingEnd = reading.endSeconds
        for window in windows {
            // Closed-interval span overlap. A reading that starts exactly when a
            // workout ends still counts, which is what makes a boundary sample
            // attributable rather than silently dropped.
            if reading.startSeconds <= window.endSeconds,
               readingEnd >= window.startSeconds {
                return true
            }
        }
        return false
    }
}

/// A finalized heart-rate index: sorted, and queryable by time range.
///
/// A separate type from `AppleHealthHeartRateIndex` so that querying an
/// unsorted buffer is not representable. The mutable index accumulates in
/// document order, which is *not* chronological; a range query over that order
/// would silently miss readings, and nothing at the call site would show it.
///
/// Internal for the same reason as the index: it is whole-life history, and the
/// scan publishes only the per-workout subset it joined.
struct AppleHealthHeartRateLookup: Sendable {

    private let readings: [AppleHealthHeartRateReading]
    private let maximumDurationSeconds: UInt32

    init(readings: [AppleHealthHeartRateReading], maximumDurationSeconds: UInt32) {
        self.readings = readings
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    /// Readings retained, sorted by start time.
    var allReadings: [AppleHealthHeartRateReading] { readings }

    var count: Int { readings.count }

    var isEmpty: Bool { readings.isEmpty }

    /// Readings whose span overlaps the closed interval
    /// `startSeconds...endSeconds`, in start-time order.
    ///
    /// The search starts `maximumDurationSeconds` before `startSeconds` rather
    /// than at it: a long reading that began before the window still overlaps
    /// it, and starting at the window would drop exactly those. With the
    /// measured maximum duration of 3,061 seconds against a 799-day span, the
    /// lookback costs a handful of extra comparisons.
    func readings(
        inWindowStart startSeconds: Int64,
        end endSeconds: Int64
    ) -> [AppleHealthHeartRateReading] {
        guard !readings.isEmpty, startSeconds <= endSeconds else { return [] }

        let lookback = Int64(maximumDurationSeconds)
        let floor = startSeconds > Int64.min + lookback
            ? startSeconds - lookback
            : Int64.min
        var index = Self.lowerBound(in: readings, atOrAfter: floor)

        var result: [AppleHealthHeartRateReading] = []
        while index < readings.count {
            let reading = readings[index]
            if reading.startSeconds > endSeconds { break }
            if reading.endSeconds >= startSeconds {
                result.append(reading)
            }
            index += 1
        }
        return result
    }

    /// Readings overlapping a workout window.
    func readings(in window: AppleHealthWorkoutWindow) -> [AppleHealthHeartRateReading] {
        readings(inWindowStart: window.startSeconds, end: window.endSeconds)
    }

    /// First index whose `startSeconds` is at or after `value`.
    private static func lowerBound(
        in readings: [AppleHealthHeartRateReading],
        atOrAfter value: Int64
    ) -> Int {
        var low = 0
        var high = readings.count
        while low < high {
            let mid = low + (high - low) / 2
            if readings[mid].startSeconds < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
