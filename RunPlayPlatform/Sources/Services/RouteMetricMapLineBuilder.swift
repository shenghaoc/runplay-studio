import Foundation
import RunPlayCore

/// Diagnostics from metric map-line coalescing.
public struct RouteMetricMapLineDiagnostics: Hashable, Sendable {
    public let lineCount: Int
    public let naturalLineCount: Int
    public let effectiveMinimumRunDistanceMeters: Double
    public let usedAdaptiveChunking: Bool
    public let retainedSegmentCount: Int
    public let policyVersion: Int

    public init(
        lineCount: Int,
        naturalLineCount: Int,
        effectiveMinimumRunDistanceMeters: Double,
        usedAdaptiveChunking: Bool,
        retainedSegmentCount: Int,
        policyVersion: Int
    ) {
        self.lineCount = lineCount
        self.naturalLineCount = naturalLineCount
        self.effectiveMinimumRunDistanceMeters = effectiveMinimumRunDistanceMeters
        self.usedAdaptiveChunking = usedAdaptiveChunking
        self.retainedSegmentCount = retainedSegmentCount
        self.policyVersion = policyVersion
    }
}

/// Result of building native metric map lines.
public struct RouteMetricMapLineBuildResult: Hashable, Sendable {
    public let lines: [RouteMapLine]
    public let diagnostics: RouteMetricMapLineDiagnostics

    public init(lines: [RouteMapLine], diagnostics: RouteMetricMapLineDiagnostics) {
        self.lines = lines
        self.diagnostics = diagnostics
    }
}

/// Builds bounded `RouteMapLine` sequences from a `RouteMetricProfile`.
///
/// Coalesces adjacent same-bucket intervals, applies short-run hysteresis, and
/// adaptively increases chunk distance when over the line budget.
public struct RouteMetricMapLineBuilder: Sendable {
    public init() {}

    public func build(
        routePoints: [RoutePoint],
        profile: RouteMetricProfile,
        idPrefix: String,
        policy: RouteMetricColorPolicy = .runningDefault,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteMetricMapLineBuildResult {
        if isCancelled() { throw CancellationError() }

        switch profile.mode {
        case .solid:
            let lines = RouteMapContent.segmentedRoutes(
                idPrefix: idPrefix,
                points: routePoints,
                style: .primary
            )
            return RouteMetricMapLineBuildResult(
                lines: lines,
                diagnostics: RouteMetricMapLineDiagnostics(
                    lineCount: lines.count,
                    naturalLineCount: lines.count,
                    effectiveMinimumRunDistanceMeters: 0,
                    usedAdaptiveChunking: false,
                    retainedSegmentCount: Set(lines.map { extractSegmentID($0.id) }).count,
                    policyVersion: policy.policyVersion
                )
            )
        case .pace, .heartRate, .correctedElevation:
            break
        }

        guard !profile.intervals.isEmpty, routePoints.count >= 2 else {
            let lines = RouteMapContent.segmentedRoutes(
                idPrefix: idPrefix,
                points: routePoints,
                style: .primary
            )
            return RouteMetricMapLineBuildResult(
                lines: lines,
                diagnostics: RouteMetricMapLineDiagnostics(
                    lineCount: lines.count,
                    naturalLineCount: lines.count,
                    effectiveMinimumRunDistanceMeters: 0,
                    usedAdaptiveChunking: false,
                    retainedSegmentCount: Set(routePoints.map(\.routeSegmentIndex)).count,
                    policyVersion: policy.policyVersion
                )
            )
        }

        var buckets = try applyHysteresis(
            intervals: profile.intervals,
            enabled: policy.enableBucketHysteresis,
            isCancelled: isCancelled
        )

        let naturalRuns = try coalesceRuns(
            routePoints: routePoints,
            intervals: profile.intervals,
            buckets: buckets,
            mode: profile.mode,
            idPrefix: idPrefix,
            minimumRunDistance: 0,
            isCancelled: isCancelled
        )
        let naturalCount = naturalRuns.count

        var minRun = policy.preferredMinimumColorRunDistanceMeters
        var lines = naturalRuns
        var usedAdaptive = false
        var attempt = 0
        let maxAttempts = 24

        while lines.count > policy.maximumStyledLineCount, attempt < maxAttempts {
            if isCancelled() { throw CancellationError() }
            usedAdaptive = true
            attempt += 1
            // Grow minimum run distance geometrically until under budget.
            minRun = max(minRun * 1.6, minRun + 5, policy.preferredMinimumColorRunDistanceMeters)
            buckets = try applyHysteresis(
                intervals: profile.intervals,
                enabled: policy.enableBucketHysteresis,
                isCancelled: isCancelled
            )
            let chunkedBuckets = try chunkBuckets(
                intervals: profile.intervals,
                buckets: buckets,
                minimumChunkDistance: minRun,
                isCancelled: isCancelled
            )
            lines = try coalesceRuns(
                routePoints: routePoints,
                intervals: profile.intervals,
                buckets: chunkedBuckets,
                mode: profile.mode,
                idPrefix: idPrefix,
                minimumRunDistance: 0,
                isCancelled: isCancelled
            )
        }

        // Last-resort: if still over budget, force large chunks per segment.
        if lines.count > policy.maximumStyledLineCount {
            usedAdaptive = true
            let forced = totalDistance(routePoints) / Double(max(1, policy.maximumStyledLineCount / 2))
            minRun = max(minRun, forced)
            let chunkedBuckets = try chunkBuckets(
                intervals: profile.intervals,
                buckets: buckets,
                minimumChunkDistance: minRun,
                isCancelled: isCancelled
            )
            lines = try coalesceRuns(
                routePoints: routePoints,
                intervals: profile.intervals,
                buckets: chunkedBuckets,
                mode: profile.mode,
                idPrefix: idPrefix,
                minimumRunDistance: 0,
                isCancelled: isCancelled
            )
        }

        let segmentCount = Set(profile.intervals.map(\.routeSegmentIndex)).count
        return RouteMetricMapLineBuildResult(
            lines: lines,
            diagnostics: RouteMetricMapLineDiagnostics(
                lineCount: lines.count,
                naturalLineCount: naturalCount,
                effectiveMinimumRunDistanceMeters: minRun,
                usedAdaptiveChunking: usedAdaptive,
                retainedSegmentCount: segmentCount,
                policyVersion: policy.policyVersion
            )
        )
    }

    // MARK: - Hysteresis

    /// Merge isolated one-interval bucket flicker when both neighbours share a bucket.
    private func applyHysteresis(
        intervals: [RouteMetricInterval],
        enabled: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RouteMetricColorBucket] {
        var buckets = intervals.map(\.bucket)
        guard enabled, buckets.count >= 3 else { return buckets }

        for i in 1..<(buckets.count - 1) {
            if i % 1024 == 0, isCancelled() { throw CancellationError() }

            let prev = buckets[i - 1]
            let current = buckets[i]
            let next = buckets[i + 1]

            // Never rewrite no-data from valid data or vice versa.
            guard case .level(let c) = current,
                  case .level(let p) = prev,
                  case .level(let n) = next,
                  p == n,
                  c != p
            else { continue }

            // Same continuous segment only.
            let prevInterval = intervals[i - 1]
            let currentInterval = intervals[i]
            let nextInterval = intervals[i + 1]
            guard prevInterval.routeSegmentIndex == currentInterval.routeSegmentIndex,
                  nextInterval.routeSegmentIndex == currentInterval.routeSegmentIndex,
                  prevInterval.endPointIndex == currentInterval.startPointIndex,
                  currentInterval.endPointIndex == nextInterval.startPointIndex
            else { continue }

            buckets[i] = .level(p)
        }
        return buckets
    }

    // MARK: - Adaptive chunking

    private func chunkBuckets(
        intervals: [RouteMetricInterval],
        buckets: [RouteMetricColorBucket],
        minimumChunkDistance: Double,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RouteMetricColorBucket] {
        guard minimumChunkDistance > 0 else { return buckets }
        var result = buckets
        var index = 0

        while index < intervals.count {
            if index % 256 == 0, isCancelled() { throw CancellationError() }

            let segment = intervals[index].routeSegmentIndex
            let chunkStart = index
            var chunkDistance = 0.0
            var end = index

            while end < intervals.count,
                  intervals[end].routeSegmentIndex == segment,
                  (end == chunkStart || intervals[end].startPointIndex == intervals[end - 1].endPointIndex) {
                chunkDistance += max(0, intervals[end].distanceMeters)
                end += 1
                if chunkDistance >= minimumChunkDistance { break }
            }

            // Extend to at least one interval.
            if end == chunkStart { end = min(intervals.count, chunkStart + 1) }

            // Representative bucket: distance-weighted median of valid levels;
            // if the whole chunk is no-data, keep no-data.
            var weighted: [(bucket: Int, weight: Double)] = []
            var noDataWeight = 0.0
            for j in chunkStart..<end {
                let weight = max(0, intervals[j].distanceMeters)
                switch buckets[j] {
                case .noData:
                    noDataWeight += weight
                case .level(let level):
                    weighted.append((bucket: level, weight: weight))
                }
            }

            let representative: RouteMetricColorBucket
            if weighted.isEmpty {
                representative = .noData
            } else if noDataWeight > weighted.reduce(0, { $0 + $1.weight }) {
                // Substantial no-data span: do not absorb into coloured run.
                representative = .noData
            } else if let median = DistanceWeightedStatistics.weightedMedianBucket(values: weighted) {
                representative = .level(median)
            } else {
                representative = buckets[chunkStart]
            }

            for j in chunkStart..<end {
                // Preserve genuine no-data intervals inside a mostly-valid chunk
                // when they form the majority of that interval's distance weight
                // individually — keep per-interval no-data as no-data if original
                // was no-data and weight is non-trivial relative to neighbours.
                if case .noData = buckets[j], case .level = representative {
                    // Short no-data flicker inside a coloured chunk stays no-data
                    // only when adjacent intervals are also no-data-heavy; safer
                    // default: keep no-data.
                    result[j] = .noData
                } else {
                    result[j] = representative
                }
            }

            index = end
        }
        return result
    }

    // MARK: - Coalesce

    private func coalesceRuns(
        routePoints: [RoutePoint],
        intervals: [RouteMetricInterval],
        buckets: [RouteMetricColorBucket],
        mode: WorkoutRouteColorMode,
        idPrefix: String,
        minimumRunDistance: Double,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RouteMapLine] {
        guard !intervals.isEmpty else { return [] }

        var lines: [RouteMapLine] = []
        var runStart = 0

        while runStart < intervals.count {
            if runStart % 256 == 0, isCancelled() { throw CancellationError() }

            let bucket = buckets[runStart]
            let segment = intervals[runStart].routeSegmentIndex
            var runEnd = runStart + 1
            var runDistance = max(0, intervals[runStart].distanceMeters)

            while runEnd < intervals.count {
                let next = intervals[runEnd]
                guard next.routeSegmentIndex == segment,
                      buckets[runEnd] == bucket,
                      next.startPointIndex == intervals[runEnd - 1].endPointIndex
                else { break }

                // Optional minimum-distance merge of micro-runs with same bucket
                // is already handled by equal-bucket adjacency.
                runDistance += max(0, next.distanceMeters)
                _ = minimumRunDistance
                runEnd += 1
            }

            if let line = makeLine(
                routePoints: routePoints,
                intervals: intervals,
                from: runStart,
                to: runEnd,
                style: .metric(mode: mode, bucket: bucket),
                id: "\(idPrefix)-m-\(segment)-\(runStart)-\(runEnd - 1)"
            ) {
                lines.append(line)
            }

            runStart = runEnd
        }

        return lines
    }

    private func makeLine(
        routePoints: [RoutePoint],
        intervals: [RouteMetricInterval],
        from runStart: Int,
        to runEnd: Int,
        style: RouteMapLineStyle,
        id: String
    ) -> RouteMapLine? {
        guard runStart < runEnd, runStart < intervals.count else { return nil }

        let firstIndex = intervals[runStart].startPointIndex
        let lastIndex = intervals[runEnd - 1].endPointIndex
        guard firstIndex >= 0,
              lastIndex < routePoints.count,
              lastIndex > firstIndex
        else { return nil }

        var coordinates: [RouteMapCoordinate] = []
        coordinates.reserveCapacity(lastIndex - firstIndex + 1)

        for pointIndex in firstIndex...lastIndex {
            let point = routePoints[pointIndex]
            // Stay inside the run's segment.
            guard point.routeSegmentIndex == intervals[runStart].routeSegmentIndex else {
                continue
            }
            if let coordinate = RouteMapCoordinate(point) {
                coordinates.append(coordinate)
            }
        }

        guard coordinates.count >= 2 else { return nil }
        return RouteMapLine(id: id, coordinates: coordinates, style: style)
    }

    private func totalDistance(_ points: [RoutePoint]) -> Double {
        max(0, points.last?.distanceFromStartMeters ?? 0)
    }

    private func extractSegmentID(_ id: String) -> String {
        id
    }
}
