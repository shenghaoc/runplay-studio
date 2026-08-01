import Foundation
@testable import RunPlayCore

/// Independent Swift oracle of the pre-migration ElevationProfile.build
/// multi-pass algorithm. Used for parity testing against the C++23 kernel.
///
/// Must not call the C++ bridge, the production native build, or share
/// filtering helpers with the new C++ implementation.
enum SwiftElevationProfileOracle {

    struct SampleResult: Equatable {
        let correctedAltitudeMeters: Double?
        let sourceAltitudeWasRejected: Bool
        let cumulativeAscentMeters: Double
        let cumulativeDescentMeters: Double
        let cumulativeSignedChangeMeters: Double
        let reliableIntervalCount: Double
        let runIdentifier: Int?
        let reliableRunIdentifier: Int?
    }

    struct BuildResult: Equatable {
        let samples: [SampleResult]
        let rejectedAltitudeCount: Int
        let hasMeaningfulElevation: Bool
        let totalAscentMeters: Double?
        let totalDescentMeters: Double?
    }

    static func build(
        routePoints: [RoutePoint],
        policy: RouteQualityPolicy = .runningDefault
    ) -> BuildResult {
        guard !routePoints.isEmpty else {
            return BuildResult(
                samples: [],
                rejectedAltitudeCount: 0,
                hasMeaningfulElevation: false,
                totalAscentMeters: nil,
                totalDescentMeters: nil
            )
        }

        let count = routePoints.count
        var analysisAltitudes = Array<Double?>(repeating: nil, count: count)
        var rejected = Array(repeating: false, count: count)

        for index in routePoints.indices {
            guard let altitude = routePoints[index].altitudeMeters else { continue }
            if altitude.isFinite, policy.plausibleAltitudeRangeMeters.contains(altitude) {
                analysisAltitudes[index] = altitude
            } else {
                rejected[index] = true
            }
        }

        if count >= 3 {
            let sourceAltitudes = analysisAltitudes

            var endpointRunCursor = 0
            while endpointRunCursor < count {
                guard sourceAltitudes[endpointRunCursor] != nil else {
                    endpointRunCursor += 1
                    continue
                }
                let runSegment = routePoints[endpointRunCursor].routeSegmentIndex
                let runStart = endpointRunCursor
                endpointRunCursor += 1
                while endpointRunCursor < count,
                      routePoints[endpointRunCursor].routeSegmentIndex == runSegment,
                      sourceAltitudes[endpointRunCursor] != nil {
                    endpointRunCursor += 1
                }
                let runEnd = endpointRunCursor
                guard runEnd - runStart >= 3 else { continue }

                for endpointIndex in [runStart, runEnd - 1] {
                    let isLeadingEndpoint = endpointIndex == runStart
                    let nearIndex = isLeadingEndpoint ? endpointIndex + 1 : endpointIndex - 1
                    let farIndex = isLeadingEndpoint ? endpointIndex + 2 : endpointIndex - 2
                    let endpointPoint = routePoints[endpointIndex]
                    let farPoint = routePoints[farIndex]
                    guard let endpoint = sourceAltitudes[endpointIndex],
                          let near = sourceAltitudes[nearIndex],
                          let far = sourceAltitudes[farIndex],
                          abs(near - far) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                    else {
                        continue
                    }

                    let travelledSpan = abs(
                        farPoint.distanceFromStartMeters - endpointPoint.distanceFromStartMeters
                    )
                    let neighbourMidpoint = (near + far) / 2
                    guard travelledSpan.isFinite,
                          travelledSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters,
                          abs(endpoint - neighbourMidpoint) >= policy.altitudeSpikeMinimumDeviationMeters,
                          abs(endpoint - near) >= policy.altitudeSpikeMinimumDeviationMeters,
                          abs(endpoint - far) >= policy.altitudeSpikeMinimumDeviationMeters
                    else {
                        continue
                    }

                    analysisAltitudes[endpointIndex] = nil
                    rejected[endpointIndex] = true
                }
            }

            for index in 1..<(count - 1) {
                let previousPoint = routePoints[index - 1]
                let point = routePoints[index]
                let nextPoint = routePoints[index + 1]
                guard previousPoint.routeSegmentIndex == point.routeSegmentIndex,
                      point.routeSegmentIndex == nextPoint.routeSegmentIndex,
                      let previous = analysisAltitudes[index - 1],
                      let current = analysisAltitudes[index],
                      let next = analysisAltitudes[index + 1],
                      abs(previous - next) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                else {
                    continue
                }

                let horizontalSpan = nextPoint.distanceFromStartMeters
                    - previousPoint.distanceFromStartMeters
                guard horizontalSpan.isFinite,
                      horizontalSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters
                else {
                    continue
                }

                let neighbourMidpoint = (previous + next) / 2
                guard abs(current - neighbourMidpoint) >= policy.altitudeSpikeMinimumDeviationMeters,
                      abs(current - previous) >= policy.altitudeSpikeMinimumDeviationMeters,
                      abs(current - next) >= policy.altitudeSpikeMinimumDeviationMeters
                else {
                    continue
                }
                analysisAltitudes[index] = nil
                rejected[index] = true
            }

            if policy.altitudeShortExcursionMaximumSampleCount >= 2, count >= 4 {
                var start = 1
                while start < count - 1 {
                    guard let firstExcursionAltitude = analysisAltitudes[start] else {
                        start += 1
                        continue
                    }

                    var end = start + 1
                    while end < count - 1,
                          end - start < policy.altitudeShortExcursionMaximumSampleCount,
                          routePoints[end].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          let altitude = analysisAltitudes[end],
                          abs(altitude - firstExcursionAltitude)
                            <= policy.altitudeSpikeMaximumNeighborDifferenceMeters {
                        end += 1
                    }

                    let excursionCount = end - start
                    guard excursionCount >= 2,
                          end < count,
                          routePoints[start - 1].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          routePoints[end].routeSegmentIndex == routePoints[start].routeSegmentIndex,
                          let before = analysisAltitudes[start - 1],
                          let after = analysisAltitudes[end],
                          abs(before - after) <= policy.altitudeSpikeMaximumNeighborDifferenceMeters
                    else {
                        start += 1
                        continue
                    }

                    let neighbourMidpoint = (before + after) / 2
                    let excursionIsExtreme = (start..<end).allSatisfy { index in
                        guard let altitude = analysisAltitudes[index] else { return false }
                        return abs(altitude - neighbourMidpoint)
                            >= policy.altitudeShortExcursionMinimumDeviationMeters
                    }
                    let horizontalSpan = routePoints[end].distanceFromStartMeters
                        - routePoints[start - 1].distanceFromStartMeters
                    guard excursionIsExtreme,
                          horizontalSpan.isFinite,
                          horizontalSpan <= policy.altitudeSpikeMaximumHorizontalSpanMeters
                    else {
                        start += 1
                        continue
                    }

                    for index in start..<end {
                        analysisAltitudes[index] = nil
                        rejected[index] = true
                    }
                    start = end
                }
            }
        }

        if count >= 3 {
            let rejectedAltitudes = analysisAltitudes
            for index in 1..<(count - 1) where rejected[index] {
                let previousPoint = routePoints[index - 1]
                let point = routePoints[index]
                let nextPoint = routePoints[index + 1]
                guard previousPoint.routeSegmentIndex == point.routeSegmentIndex,
                      point.routeSegmentIndex == nextPoint.routeSegmentIndex,
                      let previous = rejectedAltitudes[index - 1],
                      let next = rejectedAltitudes[index + 1]
                else {
                    continue
                }
                let span = nextPoint.distanceFromStartMeters - previousPoint.distanceFromStartMeters
                let fraction = span > 0
                    ? (point.distanceFromStartMeters - previousPoint.distanceFromStartMeters) / span
                    : 0.5
                analysisAltitudes[index] = interpolate(previous, next, min(1, max(0, fraction)))
            }
        }

        var corrected = Array<Double?>(repeating: nil, count: count)
        var runIDs = Array<Int?>(repeating: nil, count: count)
        var reliableRunIDs = Array<Int?>(repeating: nil, count: count)
        var nextRunID = 0
        var cursor = 0

        while cursor < count {
            guard analysisAltitudes[cursor] != nil else {
                cursor += 1
                continue
            }
            let segment = routePoints[cursor].routeSegmentIndex
            let start = cursor
            cursor += 1
            while cursor < count,
                  routePoints[cursor].routeSegmentIndex == segment,
                  analysisAltitudes[cursor] != nil {
                cursor += 1
            }
            let end = cursor
            let runCount = end - start
            let runID = nextRunID
            nextRunID += 1
            for index in start..<end {
                runIDs[index] = runID
                if runCount >= policy.minimumReliableAltitudeSampleCount {
                    reliableRunIDs[index] = runID
                }
            }

            if runCount < policy.minimumReliableAltitudeSampleCount
                || policy.elevationSmoothingRadiusMeters == 0 {
                for index in start..<end {
                    corrected[index] = analysisAltitudes[index]
                }
                continue
            }

            var left = start
            var right = start
            var sum = 0.0
            var windowCount = 0
            for index in start..<end {
                let centerDistance = routePoints[index].distanceFromStartMeters
                let upperDistance = centerDistance + policy.elevationSmoothingRadiusMeters
                while right < end,
                      routePoints[right].distanceFromStartMeters <= upperDistance {
                    if let value = analysisAltitudes[right] {
                        sum += value
                        windowCount += 1
                    }
                    right += 1
                }

                let lowerDistance = centerDistance - policy.elevationSmoothingRadiusMeters
                while left < right,
                      routePoints[left].distanceFromStartMeters < lowerDistance {
                    if let value = analysisAltitudes[left] {
                        sum -= value
                        windowCount -= 1
                    }
                    left += 1
                }
                corrected[index] = windowCount > 0 ? sum / Double(windowCount) : analysisAltitudes[index]
            }
            corrected[start] = analysisAltitudes[start]
            corrected[end - 1] = analysisAltitudes[end - 1]
        }

        var cumulativeAscent = Array(repeating: 0.0, count: count)
        var cumulativeDescent = Array(repeating: 0.0, count: count)
        var cumulativeSigned = Array(repeating: 0.0, count: count)
        var reliableIntervals = Array(repeating: 0.0, count: count)
        var globalAscent = 0.0
        var globalDescent = 0.0
        var globalSigned = 0.0
        var globalReliableIntervals = 0.0
        cursor = 0

        while cursor < count {
            if let runID = runIDs[cursor] {
                let start = cursor
                cursor += 1
                while cursor < count, runIDs[cursor] == runID {
                    cursor += 1
                }
                let end = cursor
                let isReliable = reliableRunIDs[start] != nil

                guard isReliable, let firstAltitude = corrected[start] else {
                    for index in start..<end {
                        cumulativeAscent[index] = globalAscent
                        cumulativeDescent[index] = globalDescent
                        cumulativeSigned[index] = globalSigned
                        reliableIntervals[index] = globalReliableIntervals
                    }
                    continue
                }

                var trend = 0
                var pivot = firstAltitude
                var extreme = firstAltitude
                var committedAscent = globalAscent
                var committedDescent = globalDescent
                var previousAltitude = firstAltitude

                for index in start..<end {
                    guard let altitude = corrected[index] else { continue }
                    if index > start {
                        globalSigned += altitude - previousAltitude
                        globalReliableIntervals += 1
                    }
                    previousAltitude = altitude

                    switch trend {
                    case 0:
                        if altitude - pivot >= policy.elevationGainLossDeadbandMeters {
                            trend = 1
                            extreme = altitude
                        } else if pivot - altitude >= policy.elevationGainLossDeadbandMeters {
                            trend = -1
                            extreme = altitude
                        }
                    case 1:
                        if altitude > extreme {
                            extreme = altitude
                        } else if extreme - altitude >= policy.elevationGainLossDeadbandMeters {
                            committedAscent += max(0, extreme - pivot)
                            pivot = extreme
                            trend = -1
                            extreme = altitude
                        }
                    default:
                        if altitude < extreme {
                            extreme = altitude
                        } else if altitude - extreme >= policy.elevationGainLossDeadbandMeters {
                            committedDescent += max(0, pivot - extreme)
                            pivot = extreme
                            trend = 1
                            extreme = altitude
                        }
                    }

                    let provisionalAscent = trend == 1 ? max(0, extreme - pivot) : 0
                    let provisionalDescent = trend == -1 ? max(0, pivot - extreme) : 0
                    cumulativeAscent[index] = committedAscent + provisionalAscent
                    cumulativeDescent[index] = committedDescent + provisionalDescent
                    cumulativeSigned[index] = globalSigned
                    reliableIntervals[index] = globalReliableIntervals
                }
                globalAscent = cumulativeAscent[end - 1]
                globalDescent = cumulativeDescent[end - 1]
            } else {
                cumulativeAscent[cursor] = globalAscent
                cumulativeDescent[cursor] = globalDescent
                cumulativeSigned[cursor] = globalSigned
                reliableIntervals[cursor] = globalReliableIntervals
                cursor += 1
            }
        }

        let meaningful = (reliableIntervals.last ?? 0) > 0
        var samples: [SampleResult] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            samples.append(SampleResult(
                correctedAltitudeMeters: corrected[index],
                sourceAltitudeWasRejected: rejected[index],
                cumulativeAscentMeters: cumulativeAscent[index],
                cumulativeDescentMeters: cumulativeDescent[index],
                cumulativeSignedChangeMeters: cumulativeSigned[index],
                reliableIntervalCount: reliableIntervals[index],
                runIdentifier: runIDs[index],
                reliableRunIdentifier: reliableRunIDs[index]
            ))
        }

        return BuildResult(
            samples: samples,
            rejectedAltitudeCount: rejected.count(where: { $0 }),
            hasMeaningfulElevation: meaningful,
            totalAscentMeters: meaningful ? cumulativeAscent.last : nil,
            totalDescentMeters: meaningful ? cumulativeDescent.last : nil
        )
    }

    private static func interpolate(_ first: Double, _ second: Double, _ fraction: Double) -> Double {
        first + ((second - first) * fraction)
    }
}
