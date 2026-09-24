import Foundation

/// Where a workout's heart rate comes from.
///
/// Exactly one case ever applies to a given workout. `RunWorkout` enforces
/// this at construction: heart rate lives either on the GPS route points or in
/// the standalone series, never in both. Consumers must not branch on
/// `routePoints.isEmpty` to find heart rate — they read
/// `RunWorkout.heartRateSamples`, which resolves the source once.
public enum HeartRateSampleSource: String, Codable, Hashable, Sendable {
    /// Heart rate rides on the GPS route points, as every route-bearing
    /// importer produces it (FIT, TCX, GPX, JSON).
    case routePoints
    /// Heart rate arrives as a standalone time-indexed series. This is the
    /// Apple Health export shape: its route GPX files carry position,
    /// elevation, speed, course and accuracy but no heart rate, so heart rate
    /// is joined from the export's own sample records by time. A routed
    /// Health-export run therefore uses this source even though it has
    /// coordinates — which is exactly why the source cannot be inferred from
    /// whether the route is empty.
    case standaloneSeries
    /// The workout carries no heart rate in either representation.
    case none
}

/// One heart-rate reading in a workout's elapsed-time domain.
///
/// This is the normalized shape both heart-rate representations reduce to, so
/// consumers such as training load and the summary aggregation read one type
/// regardless of where the reading originated. It deliberately carries no
/// coordinates: a sample is a point in time, not a point on a map.
public struct HeartRateSample: Codable, Hashable, Sendable {
    /// Seconds elapsed since the workout started.
    ///
    /// Stored verbatim. Normalizing it here would change the interval weights
    /// of route-derived heart rate, which must stay byte-identical to reading
    /// `RoutePoint.elapsedSeconds` directly; `accumulateIntervals` already
    /// rejects non-finite and non-positive deltas. The standalone-series path
    /// normalizes in `RunWorkout.sanitizedHeartRateSeries` instead, where it is
    /// the producer's own data rather than a re-reading of someone else's.
    public var elapsedSeconds: Double
    /// Beats per minute. `nil` when the underlying source position carried no
    /// usable reading — route points legitimately interleave heart-rate gaps,
    /// and preserving them keeps interval weighting honest rather than
    /// inventing a reading across the gap.
    public var heartRateBPM: Double?
    /// Index of the continuous segment this sample belongs to.
    ///
    /// Adjacent samples in *different* segments are never connected by an
    /// interval weight, so a recording gap or pause contributes no heart-rate
    /// time. For route-derived samples this is the source
    /// `RoutePoint.routeSegmentIndex`, passed through unchanged so existing
    /// behaviour is preserved exactly. For a standalone series it defaults to
    /// `0` — one continuous segment — and the producer that builds the series
    /// is responsible for incrementing it at any recording gap it infers,
    /// because a standalone series has no geometry from which a gap could be
    /// detected later.
    public var segmentIndex: Int

    public init(
        elapsedSeconds: Double,
        heartRateBPM: Double?,
        segmentIndex: Int = 0
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.heartRateBPM = heartRateBPM
        self.segmentIndex = segmentIndex
    }
}
