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
        // Central preflight. Importers reject oversized routes at their own
        // boundaries, but programmatic callers reach this directly — fail here
        // before building the 152-byte-per-point native buffer rather than at
        // the engine's higher internal ceiling.
        try WorkoutImportResourceLimits.validateRoutePointCount(sourcePoints.count)

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

        // Stages 2–4 run through one bulk C++ geometry call. Stage 1 ordering
        // is converted once; production does not call the transitional
        // step-distance bridge and does not fall back to the old Swift stages.
        let geometry = try RunPlayRouteQualityBridge.process(
            ordered,
            policy: policy,
            distancePolicy: distancePolicy,
            cancellationCheckStride: policy.cancellationCheckStride,
            isCancelled: isCancelled
        )
        diagnostics.discardedCoordinatePointCount = geometry.discardedCoordinatePointCount
        diagnostics.inferredRouteGapCount = geometry.inferredRouteGapCount

        var retained = geometry.routePoints
        try checkCancellation(index: 0, isCancelled: isCancelled)
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
            distanceSource: geometry.distanceSource,
            distanceProvenance: geometry.distanceProvenance,
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

    // MARK: - Legacy helpers retained in Swift

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

    // MARK: - Post-geometry Swift stages

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

    private func checkCancellation(
        index: Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        if index.isMultiple(of: policy.cancellationCheckStride), isCancelled() {
            throw CancellationError()
        }
    }
}
