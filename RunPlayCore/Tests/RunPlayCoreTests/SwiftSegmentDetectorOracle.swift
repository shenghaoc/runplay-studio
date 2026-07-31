import Foundation
@testable import RunPlayCore

/// Independent Swift oracle of the pre-migration SegmentDetector window-search
/// semantics. Used for parity testing against the C++23 kernel.
///
/// Must not call the C++ bridge, the new production native search, or share
/// a candidate-search implementation with production code.
enum SwiftSegmentDetectorOracle {

    struct SearchConfig {
        let fastest400mDistance: Double
        let fastest400mStep: Double
        let oneKmDistance: Double
        let oneKmStep: Double
        let minPace: Double  // s/km
        let maxPace: Double  // s/km
        let elevationEnabled: Bool
        let elevationWindow: Double
        let elevationStep: Double
    }

    struct Candidate: Equatable {
        enum Kind: String, Equatable {
            case fastest400m
            case fastest1km
            case slowest1km
            case biggestClimb
            case biggestDescent
        }
        let kind: Kind
        let startDistanceMeters: Double
        let endDistanceMeters: Double
        let selectionValue: Double
    }

    static func search(
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        config: SearchConfig
    ) -> [Candidate] {
        var results: [Candidate] = []

        // Fastest 400m
        if let c = findFastestPace(
            timeline: timeline,
            distance: config.fastest400mDistance,
            step: config.fastest400mStep,
            minPace: config.minPace,
            maxPace: config.maxPace,
            kind: .fastest400m
        ) {
            results.append(c)
        }

        // Fastest + Slowest 1km (combined loop)
        let km = findCombined1km(
            timeline: timeline,
            distance: config.oneKmDistance,
            step: config.oneKmStep,
            minPace: config.minPace,
            maxPace: config.maxPace
        )
        if let c = km.fastest { results.append(c) }
        if let c = km.slowest { results.append(c) }

        // Elevation
        if config.elevationEnabled {
            let elev = findCombinedElevation(
                elevationProfile: elevationProfile,
                timeline: timeline,
                window: config.elevationWindow,
                step: config.elevationStep
            )
            if let c = elev.climb { results.append(c) }
            if let c = elev.descent { results.append(c) }
        }

        return results
    }

    // MARK: - Pace

    private static func findFastestPace(
        timeline: WorkoutTimeline,
        distance: Double,
        step: Double,
        minPace: Double,
        maxPace: Double,
        kind: Candidate.Kind
    ) -> Candidate? {
        guard timeline.totalDistanceMeters - timeline.startDistanceMeters >= distance else {
            return nil
        }

        var bestPace = Double.infinity
        var bestStart = 0.0
        var found = false
        var windowStart = timeline.startDistanceMeters

        while windowStart + distance <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + distance
            if let pace = computePace(timeline: timeline, start: windowStart, end: windowEnd),
               pace >= minPace, pace <= maxPace, pace < bestPace {
                bestPace = pace
                bestStart = windowStart
                found = true
            }
            windowStart += step
        }

        guard found else { return nil }
        return Candidate(kind: kind, startDistanceMeters: bestStart,
                         endDistanceMeters: bestStart + distance, selectionValue: bestPace)
    }

    private static func findCombined1km(
        timeline: WorkoutTimeline,
        distance: Double,
        step: Double,
        minPace: Double,
        maxPace: Double
    ) -> (fastest: Candidate?, slowest: Candidate?) {
        guard timeline.totalDistanceMeters - timeline.startDistanceMeters >= distance else {
            return (nil, nil)
        }

        var fastestPace = Double.infinity
        var fastestStart = 0.0
        var fastestFound = false
        var slowestPace = 0.0
        var slowestStart = 0.0
        var slowestFound = false
        var windowStart = timeline.startDistanceMeters

        while windowStart + distance <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + distance
            if let pace = computePace(timeline: timeline, start: windowStart, end: windowEnd),
               pace >= minPace, pace <= maxPace {
                if pace < fastestPace {
                    fastestPace = pace
                    fastestStart = windowStart
                    fastestFound = true
                }
                if pace > slowestPace {
                    slowestPace = pace
                    slowestStart = windowStart
                    slowestFound = true
                }
            }
            windowStart += step
        }

        let fastest = fastestFound
            ? Candidate(kind: .fastest1km, startDistanceMeters: fastestStart,
                        endDistanceMeters: fastestStart + distance, selectionValue: fastestPace)
            : nil
        let slowest = slowestFound
            ? Candidate(kind: .slowest1km, startDistanceMeters: slowestStart,
                        endDistanceMeters: slowestStart + distance, selectionValue: slowestPace)
            : nil
        return (fastest, slowest)
    }

    private static func computePace(
        timeline: WorkoutTimeline,
        start: Double,
        end: Double
    ) -> Double? {
        guard let range = timeline.distanceRange(from: start, to: end) else { return nil }
        let distance = end - start
        guard distance > 0, range.activeSeconds > 0 else { return nil }
        let pace = (range.activeSeconds / distance) * 1000
        guard pace.isFinite else { return nil }
        return pace
    }

    // MARK: - Elevation

    private static func findCombinedElevation(
        elevationProfile: ElevationProfile,
        timeline: WorkoutTimeline,
        window: Double,
        step: Double
    ) -> (climb: Candidate?, descent: Candidate?) {
        guard timeline.totalDistanceMeters - timeline.startDistanceMeters >= window,
              elevationProfile.hasMeaningfulElevation
        else {
            return (nil, nil)
        }

        var bestClimb: Double = 0
        var bestClimbStart = 0.0
        var climbFound = false
        var bestDescentDelta: Double = 0  // negative
        var bestDescentStart = 0.0
        var descentFound = false
        var windowStart = timeline.startDistanceMeters

        while windowStart + window <= timeline.totalDistanceMeters {
            let windowEnd = windowStart + window
            defer { windowStart += step }

            guard elevationProfile.hasContinuousReliableElevation(
                from: windowStart, to: windowEnd
            ), let change = elevationProfile.change(from: windowStart, to: windowEnd)
            else { continue }

            let climb = change.ascentMeters
            let descentDelta = -change.descentMeters

            if climb > bestClimb {
                bestClimb = climb
                bestClimbStart = windowStart
                climbFound = true
            }
            if descentDelta < bestDescentDelta {
                bestDescentDelta = descentDelta
                bestDescentStart = windowStart
                descentFound = true
            }
        }

        let climb = climbFound && bestClimb > 0
            ? Candidate(kind: .biggestClimb, startDistanceMeters: bestClimbStart,
                        endDistanceMeters: bestClimbStart + window, selectionValue: bestClimb)
            : nil
        let descent = descentFound && bestDescentDelta < 0
            ? Candidate(kind: .biggestDescent, startDistanceMeters: bestDescentStart,
                        endDistanceMeters: bestDescentStart + window, selectionValue: bestDescentDelta)
            : nil
        return (climb, descent)
    }
}
