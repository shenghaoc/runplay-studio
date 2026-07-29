import Foundation
@testable import RunPlayCore

/// Test-only exact Swift reference for pre-migration route-quality stages 2–4.
///
/// Operates on ordered/sanitized stage-1 output. Uses Swift `GeoDistance` and
/// never calls the production C++ bridge or step-distance bridge.
enum SwiftRouteQualityGeometryOracle {
    struct Result: Equatable {
        var retainedSourceIndexes: [Int]
        var routePoints: [RoutePoint]
        var discardedCoordinatePointCount: Int
        var inferredRouteGapCount: Int
        var distanceSource: RouteDistanceSource
        var distanceProvenance: RouteDistanceProvenance
    }

    static func process(
        _ orderedPoints: [RoutePoint],
        policy: RouteQualityPolicy = .runningDefault,
        distancePolicy: RouteDistancePolicy = .computeFromCoordinates
    ) throws -> Result {
        let engine = Engine(policy: policy)
        return try engine.process(orderedPoints, distancePolicy: distancePolicy)
    }

    private struct Engine {
        let policy: RouteQualityPolicy

        func process(
            _ ordered: [RoutePoint],
            distancePolicy: RouteDistancePolicy
        ) throws -> Result {
            let isCancelled: @Sendable () -> Bool = { false }
            guard !ordered.isEmpty else {
                return Result(
                    retainedSourceIndexes: [],
                    routePoints: [],
                    discardedCoordinatePointCount: 0,
                    inferredRouteGapCount: 0,
                    distanceSource: .coordinateDerived,
                    distanceProvenance: RouteDistanceProvenance()
                )
            }

            let coordinateOutliers = try isolatedCoordinateOutliers(
                in: ordered,
                isCancelled: isCancelled
            )
            var retainedIndexes: [Int] = []
            var retained: [RoutePoint] = []
            retained.reserveCapacity(ordered.count - coordinateOutliers.count)
            for index in ordered.indices where !coordinateOutliers.contains(index) {
                retainedIndexes.append(index)
                retained.append(ordered[index])
            }

            let inferredBoundaries = try implicitGapBoundaries(
                in: retained,
                isCancelled: isCancelled
            )
            let inferredCount = inferredBoundaries.filter { $0 }.count
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

            return Result(
                retainedSourceIndexes: retainedIndexes,
                routePoints: distanceResult.points,
                discardedCoordinatePointCount: coordinateOutliers.count,
                inferredRouteGapCount: inferredCount,
                distanceSource: distanceResult.source,
                distanceProvenance: distanceResult.provenance
            )
        }

            // MARK: - Stage 2: isolated coordinate outliers

            func isolatedCoordinateOutliers(
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

            func poorAccuracySupportsRejection(
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

            func implicitGapBoundaries(
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

            func confirmsTimeDiscontinuity(
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

            func confirmsRelocatedCluster(startingAt start: Int, in points: [RoutePoint]) -> Bool {
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

            func compactSegments(
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

            func normalizeDistances(
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

            func contiguousSegmentRanges(
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

            func suppliedDistanceSeriesIsValid(
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

            func impliedSpeed(from first: RoutePoint, to second: RoutePoint) -> Double? {
                let interval = second.timestamp.timeIntervalSince(first.timestamp)
                guard interval.isFinite, interval > 0 else { return nil }
                let metres = distance(from: first, to: second)
                guard metres.isFinite, metres >= 0 else { return nil }
                return metres / interval
            }

            func distance(from first: RoutePoint, to second: RoutePoint) -> Double {
                GeoDistance.distanceMeters(
                    fromLat: first.latitude,
                    lon: first.longitude,
                    toLat: second.latitude,
                    lon: second.longitude
                )
            }

            func checkCancellation(
                index: Int,
                isCancelled: @Sendable () -> Bool
            ) throws {
                if index.isMultiple(of: policy.cancellationCheckStride), isCancelled() {
                    throw CancellationError()
                }
            }
    }
}
