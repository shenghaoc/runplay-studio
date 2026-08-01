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

    /// Full test-only reconstruction of the pre-migration public highlight
    /// output. UUIDs remain intentionally fresh; parity tests compare every
    /// durable and user-visible field instead.
    static func detectSegments(
        from workout: RunWorkout,
        context: WorkoutAnalysisContext,
        policy: RouteQualityPolicy = .runningDefault
    ) -> [SegmentHighlight] {
        let points = workout.routePoints
        let timeline = context.timeline
        let elevationProfile = context.elevationProfile
        guard points.count >= 2 else { return [] }

        let distanceSpan = timeline.totalDistanceMeters - timeline.startDistanceMeters
        let fastest400mStep = RouteAnalysisBudget.boundedStep(
            preferredStep: 50,
            distanceSpan: distanceSpan,
            routePointCount: points.count
        )
        let oneKilometerStep = RouteAnalysisBudget.boundedStep(
            preferredStep: 50,
            distanceSpan: distanceSpan,
            routePointCount: points.count
        )
        let elevationEnabled = elevationProfile.hasMeaningfulElevation
            && timeline.totalDistanceMeters >= policy.elevationHighlightMinimumWindowMeters
        let elevationWindow = elevationEnabled
            ? max(
                policy.elevationHighlightMinimumWindowMeters,
                min(
                    policy.elevationHighlightMaximumWindowMeters,
                    timeline.totalDistanceMeters
                        * policy.elevationHighlightWindowRouteFraction
                )
            )
            : 0
        let elevationStep = elevationEnabled
            ? RouteAnalysisBudget.boundedStep(
                preferredStep: max(
                    policy.elevationHighlightMinimumStepMeters,
                    elevationWindow / Double(policy.elevationHighlightStepsPerWindow)
                ),
                distanceSpan: distanceSpan,
                routePointCount: points.count
            )
            : 0

        let candidates = search(
            timeline: timeline,
            elevationProfile: elevationProfile,
            config: SearchConfig(
                fastest400mDistance: 400,
                fastest400mStep: fastest400mStep,
                oneKmDistance: 1_000,
                oneKmStep: oneKilometerStep,
                minPace: 120,
                maxPace: 1_200,
                elevationEnabled: elevationEnabled,
                elevationWindow: elevationWindow,
                elevationStep: elevationStep
            )
        )

        return candidates.compactMap { candidate in
            switch candidate.kind {
            case .fastest400m:
                return makePaceHighlight(
                    candidate,
                    type: .fastest400m,
                    timeline: timeline,
                    displayPriority: 1
                )
            case .fastest1km:
                return makePaceHighlight(
                    candidate,
                    type: .fastest1km,
                    timeline: timeline,
                    displayPriority: 2
                )
            case .slowest1km:
                return makePaceHighlight(
                    candidate,
                    type: .slowest1km,
                    timeline: timeline,
                    displayPriority: 3
                )
            case .biggestClimb:
                return makeElevationHighlight(
                    candidate,
                    ascending: true,
                    timeline: timeline,
                    elevationProfile: elevationProfile,
                    displayPriority: 4
                )
            case .biggestDescent:
                return makeElevationHighlight(
                    candidate,
                    ascending: false,
                    timeline: timeline,
                    elevationProfile: elevationProfile,
                    displayPriority: 5
                )
            }
        }
        .sorted { $0.displayPriority < $1.displayPriority }
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

    private static func makePaceHighlight(
        _ candidate: Candidate,
        type: SegmentType,
        timeline: WorkoutTimeline,
        displayPriority: Int
    ) -> SegmentHighlight? {
        guard let range = timeline.distanceRange(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ) else {
            return nil
        }
        let distance = candidate.endDistanceMeters - candidate.startDistanceMeters
        guard distance > 0, range.activeSeconds > 0 else { return nil }
        let pace = (range.activeSeconds / distance) * 1_000
        guard pace.isFinite, (120...1_200).contains(pace) else { return nil }

        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: DisplayFormatter.formatPace(pace),
            startDistanceMeters: candidate.startDistanceMeters,
            endDistanceMeters: candidate.endDistanceMeters,
            startElapsedSeconds: range.start.elapsedSeconds,
            endElapsedSeconds: range.end.elapsedSeconds,
            durationSeconds: range.activeSeconds,
            distanceMeters: distance,
            paceSecondsPerKilometer: pace,
            elevationDeltaMeters: timeline.signedElevationChange(
                from: candidate.startDistanceMeters,
                to: candidate.endDistanceMeters
            ),
            averageHeartRate: timeline.averageHeartRate(
                from: candidate.startDistanceMeters,
                to: candidate.endDistanceMeters
            ),
            sourcePointRange: range.sourcePointRange,
            displayPriority: displayPriority
        )
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

    private static func makeElevationHighlight(
        _ candidate: Candidate,
        ascending: Bool,
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        displayPriority: Int
    ) -> SegmentHighlight? {
        guard elevationProfile.hasContinuousReliableElevation(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ),
        let change = elevationProfile.change(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ),
        let range = timeline.distanceRange(
            from: candidate.startDistanceMeters,
            to: candidate.endDistanceMeters
        ) else {
            return nil
        }

        let delta = ascending ? change.ascentMeters : -change.descentMeters
        guard delta != 0 else { return nil }
        let type: SegmentType = ascending ? .biggestClimb : .biggestDescent
        return SegmentHighlight(
            type: type,
            title: type.displayName,
            subtitle: String(format: "%.0f m %@", abs(delta), ascending ? "↑" : "↓"),
            startDistanceMeters: candidate.startDistanceMeters,
            endDistanceMeters: candidate.endDistanceMeters,
            startElapsedSeconds: range.start.elapsedSeconds,
            endElapsedSeconds: range.end.elapsedSeconds,
            durationSeconds: range.activeSeconds,
            distanceMeters: candidate.endDistanceMeters - candidate.startDistanceMeters,
            elevationDeltaMeters: delta,
            averageHeartRate: timeline.averageHeartRate(
                from: candidate.startDistanceMeters,
                to: candidate.endDistanceMeters
            ),
            sourcePointRange: range.sourcePointRange,
            displayPriority: displayPriority
        )
    }
}
