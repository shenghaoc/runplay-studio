import Foundation

/// Central policy for deciding whether consecutive TCX tracks remain continuous.
///
/// A `<Lap>` boundary alone never creates a route discontinuity. Multiple
/// `<Track>` elements may represent pause/resume chunks and require deliberate
/// continuity handling. Existing route-quality processing still infers
/// geographic gaps after import.
public struct TCXRouteContinuityPolicy: Hashable, Sendable {
    /// Maximum wall-clock gap that may still be treated as continuous when the
    /// geographic step is also small.
    public var maximumSeamlessTimeGapSeconds: Double
    /// Maximum geographic step that may still be treated as continuous when the
    /// time gap is also small.
    public var maximumSeamlessDistanceMeters: Double
    /// A larger time gap forces a new route segment regardless of distance.
    public var forcedGapTimeSeconds: Double
    /// A larger relocation forces a new route segment regardless of time.
    public var forcedGapDistanceMeters: Double

    public static let runningDefault = TCXRouteContinuityPolicy()

    public init(
        maximumSeamlessTimeGapSeconds: Double = 8,
        maximumSeamlessDistanceMeters: Double = 40,
        forcedGapTimeSeconds: Double = 30,
        forcedGapDistanceMeters: Double = 150
    ) {
        let clampedTimeGap = max(0, maximumSeamlessTimeGapSeconds)
        let clampedDistance = max(0, maximumSeamlessDistanceMeters)
        self.maximumSeamlessTimeGapSeconds = clampedTimeGap
        self.maximumSeamlessDistanceMeters = clampedDistance
        self.forcedGapTimeSeconds = max(clampedTimeGap, forcedGapTimeSeconds)
        self.forcedGapDistanceMeters = max(clampedDistance, forcedGapDistanceMeters)
    }
}

/// Deterministic continuity decisions for TCX track boundaries.
public enum TCXRouteContinuityResolver: Sendable {

    public enum Decision: Equatable, Sendable {
        /// Keep points in the same `routeSegmentIndex`.
        case continuous
        /// Start a new `routeSegmentIndex` (recording pause or relocation).
        case discontinuous
    }

    /// Decide continuity between the last point of one track chunk and the
    /// first point of the next. Lap boundaries are ignored; only track
    /// adjacency and temporal/geographic evidence matter.
    public static func decide(
        previous: ContinuityPoint?,
        next: ContinuityPoint,
        policy: TCXRouteContinuityPolicy = .runningDefault
    ) -> Decision {
        guard let previous else { return .continuous }

        let distance = GeoDistance.distanceMeters(
            fromLat: previous.latitude,
            lon: previous.longitude,
            toLat: next.latitude,
            lon: next.longitude
        )

        let timeGap: Double?
        if let previousTime = previous.timestamp, let nextTime = next.timestamp {
            let delta = nextTime.timeIntervalSince(previousTime)
            timeGap = delta.isFinite ? max(0, delta) : nil
        } else {
            timeGap = nil
        }

        if let timeGap, timeGap >= policy.forcedGapTimeSeconds {
            return .discontinuous
        }
        if distance.isFinite, distance >= policy.forcedGapDistanceMeters {
            return .discontinuous
        }

        // A small geographic step below the forced time threshold is ordinary
        // sparse sampling, including devices that open a new Track per lap.
        if distance.isFinite,
           distance <= policy.maximumSeamlessDistanceMeters {
            return .continuous
        }

        // A larger but sub-forced relocation can still be plausible when the
        // samples are close in time. This preserves the intended middle ground
        // between the seamless and forced-distance thresholds.
        if let timeGap,
           timeGap <= policy.maximumSeamlessTimeGapSeconds,
           distance.isFinite,
           distance < policy.forcedGapDistanceMeters {
            return .continuous
        }

        // Ambiguous middle ground: prefer a new segment so we never invent a
        // continuous map line across a likely pause/resume.
        if distance.isFinite, distance > policy.maximumSeamlessDistanceMeters {
            return .discontinuous
        }

        return .discontinuous
    }

    public struct ContinuityPoint: Sendable {
        public var latitude: Double
        public var longitude: Double
        public var timestamp: Date?

        public init(latitude: Double, longitude: Double, timestamp: Date?) {
            self.latitude = latitude
            self.longitude = longitude
            self.timestamp = timestamp
        }
    }
}
