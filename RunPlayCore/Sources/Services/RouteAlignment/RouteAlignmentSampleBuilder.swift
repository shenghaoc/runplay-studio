import Foundation

/// One bounded, segment-aware spatial sample used by route-aware DTW.
public struct RouteAlignmentSample: Hashable, Sendable {
    public let xMeters: Double
    public let zMeters: Double
    public let distanceFromStartMeters: Double
    public let routeSegmentIndex: Int
    public let elapsedSeconds: Double?
    public let headingRadians: Double?
    public let normalizedProgress: Double

    public init(
        xMeters: Double,
        zMeters: Double,
        distanceFromStartMeters: Double,
        routeSegmentIndex: Int,
        elapsedSeconds: Double?,
        headingRadians: Double?,
        normalizedProgress: Double
    ) {
        self.xMeters = xMeters.isFinite ? xMeters : 0
        self.zMeters = zMeters.isFinite ? zMeters : 0
        self.distanceFromStartMeters = distanceFromStartMeters.isFinite ? max(0, distanceFromStartMeters) : 0
        self.routeSegmentIndex = max(0, routeSegmentIndex)
        self.elapsedSeconds = elapsedSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.headingRadians = headingRadians.flatMap { $0.isFinite ? $0 : nil }
        self.normalizedProgress = normalizedProgress.isFinite ? min(1, max(0, normalizedProgress)) : 0
    }
}

/// Segment-aware sample sequences for both routes, sharing one local origin.
public struct RouteAlignmentSamplePair: Hashable, Sendable {
    public let primary: [RouteAlignmentSample]
    public let comparison: [RouteAlignmentSample]
    public let primaryRouteDistanceMeters: Double
    public let comparisonRouteDistanceMeters: Double
    public let effectiveSampleIntervalMeters: Double
    public let centerLatitude: Double
    public let centerLongitude: Double

    public init(
        primary: [RouteAlignmentSample],
        comparison: [RouteAlignmentSample],
        primaryRouteDistanceMeters: Double,
        comparisonRouteDistanceMeters: Double,
        effectiveSampleIntervalMeters: Double,
        centerLatitude: Double,
        centerLongitude: Double
    ) {
        self.primary = primary
        self.comparison = comparison
        self.primaryRouteDistanceMeters = primaryRouteDistanceMeters
        self.comparisonRouteDistanceMeters = comparisonRouteDistanceMeters
        self.effectiveSampleIntervalMeters = effectiveSampleIntervalMeters
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
    }
}

/// Errors raised while constructing alignment samples.
public enum RouteAlignmentSampleError: Error, Equatable, Sendable {
    case cancelled
    case insufficientRouteData
    case unsupportedGeographicExtent
    case resourceLimit
}

/// Builds distance-space alignment samples without bridging source gaps.
public struct RouteAlignmentSampleBuilder: Sendable {
    public init() {}

    public func build(
        primary: RunWorkout,
        comparison: RunWorkout,
        policy: RouteAlignmentPolicy = .default,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteAlignmentSamplePair {
        if isCancelled() { throw RouteAlignmentSampleError.cancelled }

        let primaryValid = Self.validPoints(primary.routePoints)
        let comparisonValid = Self.validPoints(comparison.routePoints)
        guard primaryValid.count >= 2, comparisonValid.count >= 2 else {
            throw RouteAlignmentSampleError.insufficientRouteData
        }

        let origin = try Self.sharedOrigin(primaryValid: primaryValid, policy: policy)
        if isCancelled() { throw RouteAlignmentSampleError.cancelled }

        let primaryDistance = primaryValid.last?.distanceFromStartMeters ?? 0
        let comparisonDistance = comparisonValid.last?.distanceFromStartMeters ?? 0
        guard primaryDistance.isFinite, comparisonDistance.isFinite,
              primaryDistance > 0, comparisonDistance > 0 else {
            throw RouteAlignmentSampleError.insufficientRouteData
        }

        let effectiveInterval = Self.adaptiveInterval(
            preferred: policy.preferredSampleIntervalMeters,
            primaryDistance: primaryDistance,
            comparisonDistance: comparisonDistance,
            maximumSamples: policy.maximumSamplesPerRoute
        )

        // Estimate cell budget before allocating large sample arrays.
        let estimatedPrimary = Int(primaryDistance / max(effectiveInterval, 1)) + 8
        let estimatedComparison = Int(comparisonDistance / max(effectiveInterval, 1)) + 8
        let bandWidth = max(1, Int(ceil(Double(max(estimatedPrimary, estimatedComparison)) * policy.bandWidthFraction)))
        let estimatedCells = estimatedPrimary * (2 * bandWidth + 1)
        if estimatedCells > policy.maximumBandCells {
            throw RouteAlignmentSampleError.resourceLimit
        }

        let primarySamples = try Self.resample(
            points: primaryValid,
            interval: effectiveInterval,
            centerLat: origin.lat,
            centerLon: origin.lon,
            totalDistance: primaryDistance,
            policy: policy,
            isCancelled: isCancelled
        )
        let comparisonSamples = try Self.resample(
            points: comparisonValid,
            interval: effectiveInterval,
            centerLat: origin.lat,
            centerLon: origin.lon,
            totalDistance: comparisonDistance,
            policy: policy,
            isCancelled: isCancelled
        )

        if primarySamples.count > policy.maximumSamplesPerRoute
            || comparisonSamples.count > policy.maximumSamplesPerRoute {
            throw RouteAlignmentSampleError.resourceLimit
        }
        guard primarySamples.count >= policy.minimumSamplesPerRoute,
              comparisonSamples.count >= policy.minimumSamplesPerRoute else {
            throw RouteAlignmentSampleError.insufficientRouteData
        }

        // Fail conservatively on unsupported projected extent.
        for sample in primarySamples + comparisonSamples {
            if abs(sample.xMeters) > policy.maximumProjectedExtentMeters
                || abs(sample.zMeters) > policy.maximumProjectedExtentMeters {
                throw RouteAlignmentSampleError.unsupportedGeographicExtent
            }
        }

        return RouteAlignmentSamplePair(
            primary: primarySamples,
            comparison: comparisonSamples,
            primaryRouteDistanceMeters: primaryDistance,
            comparisonRouteDistanceMeters: comparisonDistance,
            effectiveSampleIntervalMeters: effectiveInterval,
            centerLatitude: origin.lat,
            centerLongitude: origin.lon
        )
    }

    // MARK: - Internals

    static func validPoints(_ points: [RoutePoint]) -> [RoutePoint] {
        points.filter {
            GeoDistance.isValidCoordinate(lat: $0.latitude, lon: $0.longitude)
                && $0.distanceFromStartMeters.isFinite
                && $0.distanceFromStartMeters >= 0
        }
    }

    static func sharedOrigin(
        primaryValid: [RoutePoint],
        policy: RouteAlignmentPolicy
    ) throws -> (lat: Double, lon: Double) {
        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity
        for point in primaryValid {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        guard minLat.isFinite, maxLat.isFinite, minLon.isFinite, maxLon.isFinite else {
            throw RouteAlignmentSampleError.insufficientRouteData
        }
        // Antimeridian-safe centre for short routes; fail if span is extreme.
        let lonSpan = maxLon - minLon
        if lonSpan > 180 {
            // Shift longitudes that wrap; if still huge, reject.
            throw RouteAlignmentSampleError.unsupportedGeographicExtent
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let approxWidth = abs(lonSpan) * 111_000 * cos(centerLat * .pi / 180)
        let approxHeight = abs(maxLat - minLat) * 111_000
        if approxWidth > policy.maximumProjectedExtentMeters * 2
            || approxHeight > policy.maximumProjectedExtentMeters * 2 {
            throw RouteAlignmentSampleError.unsupportedGeographicExtent
        }
        return (centerLat, centerLon)
    }

    static func adaptiveInterval(
        preferred: Double,
        primaryDistance: Double,
        comparisonDistance: Double,
        maximumSamples: Int
    ) -> Double {
        let safePreferred = preferred.isFinite && preferred > 0 ? preferred : 20
        let maxRoute = max(primaryDistance, comparisonDistance)
        guard maxRoute.isFinite, maxRoute > 0, maximumSamples > 1 else {
            return safePreferred
        }
        // Ensure both routes stay within the sample cap (endpoints included).
        let covering = maxRoute / Double(maximumSamples - 1)
        return max(safePreferred, covering)
    }

    static func resample(
        points: [RoutePoint],
        interval: Double,
        centerLat: Double,
        centerLon: Double,
        totalDistance: Double,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> [RouteAlignmentSample] {
        guard !points.isEmpty else { return [] }

        // Split into continuous source segments (by routeSegmentIndex and
        // non-decreasing finite distance).
        var segments: [[RoutePoint]] = []
        var current: [RoutePoint] = []
        var lastSegment = points[0].routeSegmentIndex
        var lastDistance = -Double.infinity

        for point in points {
            if isCancelled() { throw RouteAlignmentSampleError.cancelled }
            let segmentChanged = point.routeSegmentIndex != lastSegment
            let distanceRegression = point.distanceFromStartMeters + 1e-9 < lastDistance
            if segmentChanged || distanceRegression {
                if current.count >= 1 {
                    segments.append(current)
                }
                current = [point]
            } else {
                current.append(point)
            }
            lastSegment = point.routeSegmentIndex
            lastDistance = point.distanceFromStartMeters
        }
        if !current.isEmpty {
            segments.append(current)
        }

        var samples: [RouteAlignmentSample] = []
        samples.reserveCapacity(min(policy.maximumSamplesPerRoute, Int(totalDistance / max(interval, 1)) + segments.count * 2))

        for segment in segments {
            if isCancelled() { throw RouteAlignmentSampleError.cancelled }
            guard let first = segment.first, let last = segment.last else { continue }
            let startDistance = first.distanceFromStartMeters
            let endDistance = last.distanceFromStartMeters
            guard endDistance.isFinite, startDistance.isFinite else { continue }

            if segment.count == 1 || endDistance <= startDistance {
                samples.append(
                    makeSample(
                        at: startDistance,
                        in: segment,
                        centerLat: centerLat,
                        centerLon: centerLon,
                        totalDistance: totalDistance
                    )
                )
                continue
            }

            var distance = startDistance
            var emitted = 0
            while distance < endDistance - 1e-6 {
                if isCancelled() { throw RouteAlignmentSampleError.cancelled }
                samples.append(
                    makeSample(
                        at: distance,
                        in: segment,
                        centerLat: centerLat,
                        centerLon: centerLon,
                        totalDistance: totalDistance
                    )
                )
                emitted += 1
                if samples.count > policy.maximumSamplesPerRoute {
                    throw RouteAlignmentSampleError.resourceLimit
                }
                distance += interval
                // Safety: prevent infinite loops on tiny intervals.
                if emitted > policy.maximumSamplesPerRoute + 2 { break }
            }
            // Always include the segment endpoint.
            samples.append(
                makeSample(
                    at: endDistance,
                    in: segment,
                    centerLat: centerLat,
                    centerLon: centerLon,
                    totalDistance: totalDistance
                )
            )
        }

        // Attach headings from local projected tangents.
        return attachHeadings(samples)
    }

    private static func makeSample(
        at distance: Double,
        in segment: [RoutePoint],
        centerLat: Double,
        centerLon: Double,
        totalDistance: Double
    ) -> RouteAlignmentSample {
        let point = RoutePointInterpolator.point(at: distance, in: segment)
            ?? segment[0]
        let projected = GeoDistance.latLonToMeters(
            lat: point.latitude,
            lon: point.longitude,
            centerLat: centerLat,
            centerLon: centerLon
        )
        let progress = totalDistance > 0 ? point.distanceFromStartMeters / totalDistance : 0
        return RouteAlignmentSample(
            xMeters: projected.x,
            zMeters: projected.z,
            distanceFromStartMeters: point.distanceFromStartMeters,
            routeSegmentIndex: point.routeSegmentIndex,
            elapsedSeconds: point.elapsedSeconds,
            headingRadians: nil,
            normalizedProgress: progress
        )
    }

    private static func attachHeadings(_ samples: [RouteAlignmentSample]) -> [RouteAlignmentSample] {
        guard samples.count >= 2 else { return samples }
        var result: [RouteAlignmentSample] = []
        result.reserveCapacity(samples.count)
        for index in samples.indices {
            let computedHeading: Double?
            if index == 0 {
                computedHeading = tangentHeading(from: samples[0], to: samples[1])
            } else if index == samples.count - 1 {
                computedHeading = tangentHeading(from: samples[index - 1], to: samples[index])
            } else {
                // Prefer same-segment neighbours.
                let prev = samples[index - 1]
                let next = samples[index + 1]
                let current = samples[index]
                if prev.routeSegmentIndex == current.routeSegmentIndex
                    && next.routeSegmentIndex == current.routeSegmentIndex {
                    computedHeading = tangentHeading(from: prev, to: next)
                } else if prev.routeSegmentIndex == current.routeSegmentIndex {
                    computedHeading = tangentHeading(from: prev, to: current)
                } else if next.routeSegmentIndex == current.routeSegmentIndex {
                    computedHeading = tangentHeading(from: current, to: next)
                } else {
                    computedHeading = nil
                }
            }
            let sample = samples[index]
            result.append(
                RouteAlignmentSample(
                    xMeters: sample.xMeters,
                    zMeters: sample.zMeters,
                    distanceFromStartMeters: sample.distanceFromStartMeters,
                    routeSegmentIndex: sample.routeSegmentIndex,
                    elapsedSeconds: sample.elapsedSeconds,
                    headingRadians: computedHeading,
                    normalizedProgress: sample.normalizedProgress
                )
            )
        }
        return result
    }

    private static func tangentHeading(from a: RouteAlignmentSample, to b: RouteAlignmentSample) -> Double? {
        let dx = b.xMeters - a.xMeters
        let dz = b.zMeters - a.zMeters
        guard dx.isFinite, dz.isFinite else { return nil }
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.5 else { return nil }
        return atan2(dx, dz)
    }
}
