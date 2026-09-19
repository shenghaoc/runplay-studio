import Foundation

/// Per-workout heart-rate training load stored on the workout snapshot.
///
/// The canonical load is Banister TRIMP in its exponential form:
/// `minutes × HRreserve × y · e^(k × HRreserve)` summed over same-segment
/// heart-rate intervals, computed by the native training-load kernel in one
/// bulk pass. Runs without usable heart-rate data carry an estimated load
/// derived from pace and duration instead — informative on its own, clearly
/// labelled, and excluded from the fitness/fatigue/form model by default.
public struct TrainingLoadSnapshot: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Computed from recorded heart-rate intervals through the native
        /// kernel.
        case measured
        /// No usable heart rate: derived from pace and duration by a
        /// deliberately conservative estimator.
        case estimated
    }

    public enum EstimateBasis: String, Codable, Sendable {
        /// Average pace mapped onto an assumed heart-rate reserve band.
        case paceDuration
        /// Duration only, when the run also lacks usable pace/distance.
        case durationOnly
    }

    public let kind: Kind

    /// Total Banister TRIMP for the workout.
    public let banisterTRIMP: Double

    /// Seconds per zone (five entries), measured loads only. `nil` for
    /// estimated loads — zone time without heart rate would be invented data.
    public let zoneSeconds: [Double]?

    /// Time-weighted mean heart rate over the valid intervals, measured loads
    /// only.
    public let meanHeartRateBPM: Double?

    /// Total interval weight that carried a valid heart rate.
    public let validHeartRateSeconds: Double

    /// Total interval weight (same-segment active time the pass covered).
    public let coveredActiveSeconds: Double

    /// What the estimate was derived from, estimated loads only.
    public let estimateBasis: EstimateBasis?

    /// The heart-rate reserve the estimator assumed, estimated loads only.
    /// Stored so the UI can disclose the assumption behind the number.
    public let assumedHeartRateReserve: Double?

    /// The semantic profile inputs this load was computed with. A mismatch
    /// against the current `AthleteProfile` is the staleness signal that
    /// drives recompute — the same rule that covers the never-computed case,
    /// because absence of this snapshot means the same thing.
    public let profile: AthleteProfile

    public init(
        kind: Kind,
        banisterTRIMP: Double,
        zoneSeconds: [Double]?,
        meanHeartRateBPM: Double?,
        validHeartRateSeconds: Double,
        coveredActiveSeconds: Double,
        estimateBasis: EstimateBasis? = nil,
        assumedHeartRateReserve: Double? = nil,
        profile: AthleteProfile
    ) {
        self.kind = kind
        self.banisterTRIMP = banisterTRIMP
        self.zoneSeconds = zoneSeconds
        self.meanHeartRateBPM = meanHeartRateBPM
        self.validHeartRateSeconds = validHeartRateSeconds
        self.coveredActiveSeconds = coveredActiveSeconds
        self.estimateBasis = estimateBasis
        self.assumedHeartRateReserve = assumedHeartRateReserve
        self.profile = profile
    }

    /// Whether this snapshot is current for `profile`. One rule covers both
    /// staleness cases: a load computed under different inputs, and a load
    /// never computed at all (which this method never sees — that is the
    /// `nil` marker on the workout).
    public func isCurrent(for profile: AthleteProfile) -> Bool {
        self.profile == profile
    }
}
