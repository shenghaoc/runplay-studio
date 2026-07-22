import Foundation

/// Complete output of route normalization and elevation analysis.
public struct RouteQualityResult: Sendable {
    public let routePoints: [RoutePoint]
    public let elevationProfile: ElevationProfile
    public let diagnostics: RouteQualityDiagnostics
    public let distanceSource: RouteDistanceSource
    public let distanceProvenance: RouteDistanceProvenance
    public let analysisWarnings: [WorkoutAnalysisWarning]

    public init(
        routePoints: [RoutePoint],
        elevationProfile: ElevationProfile,
        diagnostics: RouteQualityDiagnostics,
        distanceSource: RouteDistanceSource,
        distanceProvenance: RouteDistanceProvenance,
        analysisWarnings: [WorkoutAnalysisWarning]
    ) {
        self.routePoints = routePoints
        self.elevationProfile = elevationProfile
        self.diagnostics = diagnostics
        self.distanceSource = distanceSource
        self.distanceProvenance = distanceProvenance
        self.analysisWarnings = analysisWarnings
    }
}

/// Deterministic, platform-neutral GPS and elevation quality pipeline.
public struct RouteQualityProcessor: Sendable {
    public let policy: RouteQualityPolicy

    public init(policy: RouteQualityPolicy = .runningDefault) {
        self.policy = policy
    }

    /// Process locally and cooperatively propagate `CancellationError`.
    public func process(
        _ sourcePoints: [RoutePoint],
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates,
        sortByTimestamp: Bool = true,
        sourceInvalidCoordinatePointCount: Int = 0,
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws -> RouteQualityResult {
        var diagnostics = RouteQualityDiagnostics(
            invalidCoordinatePointCount: sourceInvalidCoordinatePointCount
        )
        let ordered = try basicFieldValidation(
            sourcePoints,
            sortByTimestamp: sortByTimestamp,
            diagnostics: &diagnostics,
            isCancelled: isCancelled
        )
        guard !ordered.isEmpty else {
            return RouteQualityResult(
                routePoints: [],
                elevationProfile: ElevationProfile(routePoints: [], policy: policy),
                diagnostics: diagnostics,
                distanceSource: .coordinateDerived,
                distanceProvenance: RouteDistanceProvenance(),
                analysisWarnings: []
            )
        }

        let coordinateOutliers = try isolatedCoordinateOutliers(
            in: ordered,
            isCancelled: isCancelled
        )
        diagnostics.discardedCoordinatePointCount = coordinateOutliers.count

        var retained: [RoutePoint] = []
        retained.reserveCapacity(ordered.count - coordinateOutliers.count)
        for index in ordered.indices where !coordinateOutliers.contains(index) {
            try checkCancellation(index: index, isCancelled: isCancelled)
            retained.append(ordered[index])
        }

        let inferredBoundaries = try implicitGapBoundaries(
            in: retained,
            isCancelled: isCancelled
        )
        diagnostics.inferredRouteGapCount = inferredBoundaries.count(where: { $0 })
        let sourceSegmentByNormalizedSegment = try compactSegments(
            in: &retained,
            inferredBoundaries: inferredBoundaries,
            isCancelled: isCancelled
        )

        let distanceResult = try normalizeDistances(
            in: retained,
            policy: distancePolicy,
            sourceSegmentByNormalizedSegment: sourceSegmentByNormalizedSegment,
            isCancelled: isCancelled
        )
        retained = distanceResult.points
        try validateSourceSpeeds(
            in: &retained,
            diagnostics: &diagnostics,
            isCancelled: isCancelled
        )

        let elevation = try ElevationProfile.build(
            routePoints: retained,
            policy: policy,
            isCancelled: isCancelled
        )
        diagnostics.discardedAltitudeSampleCount += elevation.rejectedAltitudeCount

        var warnings: [WorkoutAnalysisWarning] = []
        if diagnostics.discardedCoordinatePointCount > 0 {
            warnings.append(.coordinateOutliersRemoved)
        }
        if diagnostics.inferredRouteGapCount > 0 {
            warnings.append(.implicitRouteGapIntroduced)
        }
        if diagnostics.discardedAltitudeSampleCount > 0 {
            warnings.append(.altitudeOutliersIgnored)
        }
        if !retained.isEmpty, !elevation.profile.hasMeaningfulElevation {
            warnings.append(.insufficientReliableElevation)
        }

        return RouteQualityResult(
            routePoints: retained,
            elevationProfile: elevation.profile,
            diagnostics: diagnostics,
            distanceSource: distanceResult.source,
            distanceProvenance: distanceResult.provenance,
            analysisWarnings: warnings
        )
    }

    /// Compatibility path for synchronous callers that do not own an async task.
    public func processUncancellable(
        _ sourcePoints: [RoutePoint],
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates,
        sortByTimestamp: Bool = true,
        sourceInvalidCoordinatePointCount: Int = 0
    ) -> RouteQualityResult {
        if let result = try? process(
            sourcePoints,
            distancePolicy: distancePolicy,
            sortByTimestamp: sortByTimestamp,
            sourceInvalidCoordinatePointCount: sourceInvalidCoordinatePointCount,
            isCancelled: { false }
        ) {
            return result
        }
        let fallback = sourcePoints.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
        }
        return RouteQualityResult(
            routePoints: fallback,
            elevationProfile: ElevationProfile(routePoints: fallback, policy: policy),
            diagnostics: RouteQualityDiagnostics(
                invalidCoordinatePointCount: sourceInvalidCoordinatePointCount
                    + sourcePoints.count - fallback.count
            ),
            distanceSource: .legacyUnknown,
            distanceProvenance: .legacyUnknown,
            analysisWarnings: []
        )
    }

    /// Legacy snapshots did not persist distance provenance. GPX distance was
    /// always coordinate-derived. Other formats preserve a valid supplied
    /// series only when it materially differs from raw coordinate geometry;
    /// otherwise recomputation repairs old coordinate-spike inflation.
    public static func legacyDistancePolicy(
        for points: [RoutePoint],
        source: WorkoutSource,
        policy: RouteQualityPolicy = .runningDefault
    ) -> RouteDistancePolicy {
        if source == .gpx {
            return .computeFromCoordinates
        }
        guard suppliedDistanceSeriesIsValid(points) else {
            return .computeFromCoordinates
        }

        var geometryDistance = 0.0
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard previous.routeSegmentIndex == current.routeSegmentIndex else { continue }
            geometryDistance += GeoDistance.distanceMeters(
                fromLat: previous.latitude,
                lon: previous.longitude,
                toLat: current.latitude,
                lon: current.longitude
            )
        }
        let suppliedDistance = max(0, (points.last?.distanceFromStartMeters ?? 0)
            - (points.first?.distanceFromStartMeters ?? 0))
        let tolerance = max(
            policy.legacyDistanceInferenceAbsoluteToleranceMeters,
            geometryDistance * policy.legacyDistanceInferenceRelativeTolerance
        )
        return abs(suppliedDistance - geometryDistance) > tolerance
            ? .useSuppliedDistancesPerSegment
            : .computeFromCoordinates
    }

    // MARK: - Stage 1: basic validation

    private func basicFieldValidation(
        _ sourcePoints: [RoutePoint],
        sortByTimestamp: Bool,
        diagnostics: inout RouteQualityDiagnostics,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RoutePoint] {
        var valid: [(offset: Int, point: RoutePoint)] = []
        valid.reserveCapacity(sourcePoints.count)

        for (index, source) in sourcePoints.enumerated() {
            try checkCancellation(index: index, isCancelled: isCancelled)
            guard GeoDistance.isValidCoordinate(lat: source.latitude, lon: source.longitude) else {
                diagnostics.invalidCoordinatePointCount += 1
                continue
            }
            var point = source
            if let altitude = point.altitudeMeters, !altitude.isFinite {
                point.altitudeMeters = nil
                diagnostics.discardedAltitudeSampleCount += 1
            }

            let sourceSpeedIsValid = point.speedMetersPerSecond.map {
                $0.isFinite && $0 >= 0 && $0 <= policy.maximumSourceSpeedMetersPerSecond
            } ?? true
            if !sourceSpeedIsValid {
                point.speedMetersPerSecond = nil
                point.paceSecondsPerKilometer = nil
                diagnostics.invalidSourceSpeedSampleCount += 1
            } else if let pace = point.paceSecondsPerKilometer {
                let impliedSpeed = pace > 0 ? 1_000 / pace : .infinity
                if !pace.isFinite || pace <= 0
                    || impliedSpeed > policy.maximumSourceSpeedMetersPerSecond {
                    point.paceSecondsPerKilometer = nil
                }
            }
            if let accuracy = point.horizontalAccuracy, !accuracy.isFinite || accuracy < 0 {
                point.horizontalAccuracy = nil
            }
            valid.append((index, point))
        }

        let grouped = Dictionary(grouping: valid, by: { $0.point.routeSegmentIndex })
        var ordered: [RoutePoint] = []
        ordered.reserveCapacity(valid.count)
        for segmentIndex in grouped.keys.sorted() {
            guard var entries = grouped[segmentIndex] else { continue }
            if sortByTimestamp {
                entries.sort {
                    if $0.point.timestamp == $1.point.timestamp {
                        if $0.point.elapsedSeconds == $1.point.elapsedSeconds {
                            return $0.offset < $1.offset
                        }
                        return $0.point.elapsedSeconds < $1.point.elapsedSeconds
                    }
                    return $0.point.timestamp < $1.point.timestamp
                }
            } else {
                entries.sort { $0.offset < $1.offset }
            }
            ordered.append(contentsOf: entries.map(\.point))
        }

        var compactIndex = -1
        var previousSourceSegment: Int?
        for index in ordered.indices {
            if ordered[index].routeSegmentIndex != previousSourceSegment {
                compactIndex += 1
                previousSourceSegment = ordered[index].routeSegmentIndex
            }
            ordered[index].routeSegmentIndex = compactIndex
        }

        if let first = ordered.first {
            let timestampSpan = ordered.last?.timestamp.timeIntervalSince(first.timestamp) ?? 0
            let useTimestampElapsed = timestampSpan.isFinite && timestampSpan > 0
            let suppliedElapsedIsValid = Self.elapsedSeriesIsValid(ordered)
            let suppliedBase = suppliedElapsedIsValid ? first.elapsedSeconds : 0
            var previousElapsed = 0.0
            for index in ordered.indices {
                let candidate: Double
                if useTimestampElapsed {
                    candidate = ordered[index].timestamp.timeIntervalSince(first.timestamp)
                } else if suppliedElapsedIsValid {
                    candidate = ordered[index].elapsedSeconds - suppliedBase
                } else {
                    candidate = Double(index)
                }
                let finiteCandidate = candidate.isFinite ? max(0, candidate) : previousElapsed
                previousElapsed = max(previousElapsed, finiteCandidate)
                ordered[index].elapsedSeconds = previousElapsed
            }
        }
        return ordered
    }

    // MARK: - Stage 2: isolated coordinate outliers

    private func isolatedCoordinateOutliers(
        in points: [RoutePoint],
        isCancelled: @Sendable () -> Bool
    ) throws -> Set<Int> {
        guard points.count >= 3 else { return [] }
        var candidates = Array(repeating: false, count: points.count)

        for index in 1..<(points.count - 1) {
            try checkCancellation(index: index, isCancelled: isCancelled)
            let previous = points[index - 1]
            let candidate = points[index]
            let next = points[index + 1]
            guard previous.routeSegmentIndex == candidate.routeSegmentIndex,
                  candidate.routeSegmentIndex == next.routeSegmentIndex,
                  let inboundSpeed = impliedSpeed(from: previous, to: candidate),
                  let outboundSpeed = impliedSpeed(from: candidate, to: next),
                  let bridgeSpeed = impliedSpeed(from: previous, to: next),
                  inboundSpeed > policy.maximumPlausibleRunningSpeedMetersPerSecond,
                  outboundSpeed > policy.maximumPlausibleRunningSpeedMetersPerSecond,
                  bridgeSpeed <= policy.maximumPlausibleRunningSpeedMetersPerSecond
            else {
                continue
            }

            let inboundDistance = distance(from: previous, to: candidate)
            let outboundDistance = distance(from: candidate, to: next)
            let bridgeDistance = distance(from: previous, to: next)
            let pathDistance = inboundDistance + outboundDistance
            let distortionRatio = pathDistance / max(1, bridgeDistance)
            let accuracySupportsRejection = poorAccuracySupportsRejection(
                previous: previous,
                candidate: candidate,
                next: next
            )
            let requiredExcess = policy.coordinateSpikeMinimumExcessDistanceMeters
                * (accuracySupportsRejection ? policy.poorAccuracyEvidenceMultiplier : 1)

            if pathDistance - bridgeDistance >= requiredExcess,
               distortionRatio >= policy.coordinateSpikeMinimumDistortionRatio {
                candidates[index] = true
            }
        }

        // Adjacent candidates are ambiguous rather than isolated; retain them.
        var result: Set<Int> = []
        for index in 1..<(points.count - 1) where candidates[index] {
            guard !candidates[index - 1], !candidates[index + 1] else { continue }
            result.insert(index)
        }
        return result
    }

    private func poorAccuracySupportsRejection(
        previous: RoutePoint,
        candidate: RoutePoint,
        next: RoutePoint
    ) -> Bool {
        guard let candidateAccuracy = candidate.horizontalAccuracy,
              candidateAccuracy > policy.maximumUsefulHorizontalAccuracyMeters
        else {
            return false
        }
        let neighbourAccuracies = [previous.horizontalAccuracy, next.horizontalAccuracy].compactMap { $0 }
        guard !neighbourAccuracies.isEmpty else { return false }
        return neighbourAccuracies.allSatisfy {
            $0 <= policy.maximumUsefulHorizontalAccuracyMeters && $0 < candidateAccuracy
        }
    }

    // MARK: - Stage 3: implicit recording gaps

    private func implicitGapBoundaries(
        in points: [RoutePoint],
        isCancelled: @Sendable () -> Bool
    ) throws -> [Bool] {
        guard !points.isEmpty else { return [] }
        var boundaries = Array(repeating: false, count: points.count)
        guard points.count >= policy.relocatedClusterConfirmationPointCount + 1 else {
            return boundaries
        }

        for index in 1..<points.count {
            try checkCancellation(index: index, isCancelled: isCancelled)
            let previous = points[index - 1]
            let current = points[index]
            guard previous.routeSegmentIndex == current.routeSegmentIndex else { continue }
            let jump = distance(from: previous, to: current)
            guard jump >= policy.implicitGapMinimumDistanceMeters else { continue }

            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            let isImplausiblyFast = interval.isFinite && interval > 0
                && jump / interval > policy.maximumPlausibleRunningSpeedMetersPerSecond
            let hasLongRecordingDiscontinuity = interval.isFinite
                && interval >= policy.implicitGapMinimumTimeIntervalSeconds
                && confirmsTimeDiscontinuity(
                    interval: interval,
                    clusterStartingAt: index,
                    in: points
                )
            guard isImplausiblyFast || hasLongRecordingDiscontinuity,
                  confirmsRelocatedCluster(startingAt: index, in: points)
            else {
                continue
            }
            boundaries[index] = true
        }
        return boundaries
    }

    private func confirmsTimeDiscontinuity(
        interval: Double,
        clusterStartingAt start: Int,
        in points: [RoutePoint]
    ) -> Bool {
        let end = start + policy.relocatedClusterConfirmationPointCount
        guard interval.isFinite, interval > 0, end <= points.count else { return false }
        var longestConfirmationInterval = 0.0
        for index in (start + 1)..<end {
            let candidate = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp)
            guard candidate.isFinite, candidate > 0 else { return false }
            longestConfirmationInterval = max(longestConfirmationInterval, candidate)
        }
        guard longestConfirmationInterval > 0 else { return false }
        return interval / longestConfirmationInterval
            >= policy.implicitGapMinimumTimeDiscontinuityRatio
    }

    private func confirmsRelocatedCluster(startingAt start: Int, in points: [RoutePoint]) -> Bool {
        let end = start + policy.relocatedClusterConfirmationPointCount
        guard end <= points.count else { return false }
        let segment = points[start].routeSegmentIndex
        for index in start..<end where points[index].routeSegmentIndex != segment {
            return false
        }
        guard start + 1 < end else { return false }
        for index in (start + 1)..<end {
            let previous = points[index - 1]
            let current = points[index]
            let step = distance(from: previous, to: current)
            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            if interval.isFinite, interval > 0 {
                guard step / interval <= policy.maximumPlausibleRunningSpeedMetersPerSecond else {
                    return false
                }
            } else if step > policy.relocatedClusterMaximumStepMeters {
                return false
            }
        }
        return true
    }

    private func compactSegments(
        in points: inout [RoutePoint],
        inferredBoundaries: [Bool],
        isCancelled: @Sendable () -> Bool
    ) throws -> [Int] {
        guard !points.isEmpty else { return [] }
        var outputSegment = -1
        var sourceSegment: Int?
        var sourceSegmentByNormalizedSegment: [Int] = []
        for index in points.indices {
            try checkCancellation(index: index, isCancelled: isCancelled)
            if points[index].routeSegmentIndex != sourceSegment
                || (inferredBoundaries.indices.contains(index) && inferredBoundaries[index]) {
                outputSegment += 1
                sourceSegment = points[index].routeSegmentIndex
                sourceSegmentByNormalizedSegment.append(points[index].routeSegmentIndex)
            }
            points[index].routeSegmentIndex = outputSegment
        }
        return sourceSegmentByNormalizedSegment
    }

    // MARK: - Stage 4: distance normalization

    private func normalizeDistances(
        in points: [RoutePoint],
        policy distancePolicy: RouteDistancePolicy,
        sourceSegmentByNormalizedSegment: [Int],
        isCancelled: @Sendable () -> Bool
    ) throws -> (points: [RoutePoint], source: RouteDistanceSource, provenance: RouteDistanceProvenance) {
        guard !points.isEmpty else {
            return ([], .coordinateDerived, RouteDistanceProvenance())
        }
        let segmentRanges = try contiguousSegmentRanges(in: points, isCancelled: isCancelled)
        var validity: [Bool] = []
        validity.reserveCapacity(segmentRanges.count)
        for (index, range) in segmentRanges.enumerated() {
            try checkCancellation(index: index, isCancelled: isCancelled)
            validity.append(try suppliedDistanceSeriesIsValid(
                points[range],
                isCancelled: isCancelled
            ))
        }
        let useSupplied: [Bool]
        switch distancePolicy {
        case .computeFromCoordinates:
            useSupplied = Array(repeating: false, count: segmentRanges.count)
        case .useSuppliedDistancesWhenValid:
            let useAll = validity.allSatisfy { $0 }
            useSupplied = Array(repeating: useAll, count: segmentRanges.count)
        case .useSuppliedDistancesPerSegment:
            useSupplied = validity
        case .useSuppliedDistancesForSegments(let suppliedSegments):
            useSupplied = segmentRanges.enumerated().map { index, range in
                let normalizedSegment = points[range.lowerBound].routeSegmentIndex
                let sourceSegment = sourceSegmentByNormalizedSegment.indices.contains(normalizedSegment)
                    ? sourceSegmentByNormalizedSegment[normalizedSegment]
                    : normalizedSegment
                return suppliedSegments.contains(sourceSegment)
                    && validity[index]
            }
        }

        var normalized = points
        var cumulativeDistance = 0.0
        for (rangeIndex, range) in segmentRanges.enumerated() {
            try checkCancellation(index: rangeIndex, isCancelled: isCancelled)
            let supplied = useSupplied[rangeIndex]
            let suppliedBase = points[range.lowerBound].distanceFromStartMeters
            normalized[range.lowerBound].distanceFromStartMeters = cumulativeDistance
            if range.count >= 2 {
                for index in (range.lowerBound + 1)..<range.upperBound {
                    try checkCancellation(index: index, isCancelled: isCancelled)
                    if supplied {
                        let relative = max(0, points[index].distanceFromStartMeters - suppliedBase)
                        normalized[index].distanceFromStartMeters = max(
                            normalized[index - 1].distanceFromStartMeters,
                            cumulativeDistance + relative
                        )
                    } else {
                        let step = distance(from: points[index - 1], to: points[index])
                        normalized[index].distanceFromStartMeters = normalized[index - 1].distanceFromStartMeters
                            + (step.isFinite ? max(0, step) : 0)
                    }
                }
            }
            cumulativeDistance = normalized[range.upperBound - 1].distanceFromStartMeters
        }

        let suppliedCount = useSupplied.count(where: { $0 })
        let source: RouteDistanceSource
        if suppliedCount == 0 {
            source = .coordinateDerived
        } else if suppliedCount == useSupplied.count {
            source = .deviceSupplied
        } else {
            source = .mixed
        }
        let provenance = RouteDistanceProvenance(
            segmentSources: useSupplied.map { $0 ? .deviceSupplied : .coordinateDerived }
        )
        return (normalized, source, provenance)
    }

    private func contiguousSegmentRanges(
        in points: [RoutePoint],
        isCancelled: @Sendable () -> Bool
    ) throws -> [Range<Int>] {
        guard !points.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 1..<points.count {
            try checkCancellation(index: index, isCancelled: isCancelled)
            if points[index].routeSegmentIndex != points[index - 1].routeSegmentIndex {
                ranges.append(start..<index)
                start = index
            }
        }
        ranges.append(start..<points.count)
        return ranges
    }

    private func suppliedDistanceSeriesIsValid(
        _ points: ArraySlice<RoutePoint>,
        isCancelled: @Sendable () -> Bool
    ) throws -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        for (offset, point) in points.enumerated() {
            try checkCancellation(index: offset, isCancelled: isCancelled)
            let distance = point.distanceFromStartMeters
            guard distance.isFinite, distance >= 0, distance >= previous else { return false }
            previous = distance
        }
        return true
    }

    private static func suppliedDistanceSeriesIsValid(_ points: [RoutePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        var previousSegment: Int?
        for point in points {
            if point.routeSegmentIndex != previousSegment {
                previous = -Double.infinity
                previousSegment = point.routeSegmentIndex
            }
            let distance = point.distanceFromStartMeters
            guard distance.isFinite, distance >= 0, distance >= previous else { return false }
            previous = distance
        }
        return true
    }

    private static func elapsedSeriesIsValid(_ points: [RoutePoint]) -> Bool {
        guard !points.isEmpty else { return false }
        var previous = -Double.infinity
        for point in points {
            let elapsed = point.elapsedSeconds
            guard elapsed.isFinite, elapsed >= 0, elapsed >= previous else { return false }
            previous = elapsed
        }
        return true
    }

    // MARK: - Numeric helpers

    private func validateSourceSpeeds(
        in points: inout [RoutePoint],
        diagnostics: inout RouteQualityDiagnostics,
        isCancelled: @Sendable () -> Bool
    ) throws {
        guard points.count >= 2 else { return }
        for index in 1..<points.count {
            try checkCancellation(index: index, isCancelled: isCancelled)
            let previous = points[index - 1]
            let current = points[index]
            guard previous.routeSegmentIndex == current.routeSegmentIndex,
                  let sourceSpeed = current.speedMetersPerSecond
            else {
                continue
            }
            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            let distanceDelta = current.distanceFromStartMeters - previous.distanceFromStartMeters
            guard interval.isFinite, interval > 0,
                  distanceDelta.isFinite, distanceDelta >= 0
            else {
                continue
            }
            if distanceDelta == 0 {
                if sourceSpeed > policy.maximumStationarySourceSpeedMetersPerSecond {
                    points[index].speedMetersPerSecond = nil
                    points[index].paceSecondsPerKilometer = nil
                    diagnostics.invalidSourceSpeedSampleCount += 1
                }
                continue
            }
            let normalizedSpeed = distanceDelta / interval
            guard normalizedSpeed > 0 else { continue }
            if sourceSpeed == 0 {
                if normalizedSpeed >= policy.sourceZeroSpeedMovementThresholdMetersPerSecond {
                    points[index].speedMetersPerSecond = nil
                    points[index].paceSecondsPerKilometer = nil
                    diagnostics.invalidSourceSpeedSampleCount += 1
                }
                continue
            }
            let ratio = max(sourceSpeed, normalizedSpeed) / min(sourceSpeed, normalizedSpeed)
            if ratio > policy.maximumSourceSpeedGeometryDisagreementRatio {
                points[index].speedMetersPerSecond = nil
                points[index].paceSecondsPerKilometer = nil
                diagnostics.invalidSourceSpeedSampleCount += 1
            }
        }
    }

    private func impliedSpeed(from first: RoutePoint, to second: RoutePoint) -> Double? {
        let interval = second.timestamp.timeIntervalSince(first.timestamp)
        guard interval.isFinite, interval > 0 else { return nil }
        let metres = distance(from: first, to: second)
        guard metres.isFinite, metres >= 0 else { return nil }
        return metres / interval
    }

    private func distance(from first: RoutePoint, to second: RoutePoint) -> Double {
        GeoDistance.distanceMeters(
            fromLat: first.latitude,
            lon: first.longitude,
            toLat: second.latitude,
            lon: second.longitude
        )
    }

    private func checkCancellation(
        index: Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        if index.isMultiple(of: policy.cancellationCheckStride), isCancelled() {
            throw CancellationError()
        }
    }
}
