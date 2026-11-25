/// The status failures segment detection can report with a borrowed input span and owned output.
/// `invalid_input_buffer`, `invalid_output_buffer` and `insufficient_output_capacity` have no
/// Swift counterpart: a `Span` cannot pair a positive count with null storage, and the engine
/// owns its fixed-size output.
package enum SegmentDetectionError: Error, Equatable {
    case invalidConfiguration
    case invalidInputContract
    case resourceLimit
    case internalFailure
}

/// Native segment-search input, reduced to the timeline and elevation fields read by the kernel.
package struct SegmentDetectionSample: Sendable {
    package var distance: Double = 0
    package var elapsed: Double = 0
    package var active: Double = 0
    package var ascent: Double = 0
    package var descent: Double = 0
    package var reliableCount: Double = 0
    package var continuityGroup: Int32 = 0
    package var reliableRun: Int32 = -1

    package init() {}

    fileprivate var isFinite: Bool {
        distance.isFinite && elapsed.isFinite && active.isFinite
            && ascent.isFinite && descent.isFinite && reliableCount.isFinite
    }
}

package enum SegmentDetectionKind: UInt8, Sendable {
    case fastest400m, fastest1km, slowest1km, biggestClimb, biggestDescent
    case fastestOneMile, fastest5km, fastest10km, fastestHalfMarathon, fastestMarathon
}

package struct SegmentDetectionCandidate: Sendable {
    package let kind: SegmentDetectionKind
    package let start: Double
    package let end: Double
    package let value: Double

    fileprivate init(_ kind: SegmentDetectionKind = .fastest400m, _ start: Double = 0, _ end: Double = 0, _ value: Double = 0) {
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
    }
}

package struct SegmentDetectionConfiguration: Sendable {
    package struct Window: Sendable {
        package var distance: Double
        package var step: Double

        package init(_ distance: Double, _ step: Double = 50) {
            self.distance = distance
            self.step = step
        }

        fileprivate var isValid: Bool {
            distance.isFinite && step.isFinite && distance > 0 && step > 0
        }

        fileprivate func fits(_ span: Double, maximum: UInt64) -> Bool {
            guard span >= distance else { return true }
            let spare = span - distance
            guard spare >= 0 else { return true }
            let steps = spare / step
            return steps.isFinite && steps < Double(maximum)
        }
    }

    package var fastest400m = Window(400)
    package var oneKilometer = Window(1_000)
    package var oneMile = Window(SegmentDetection.oneMileMeters)
    package var fiveKilometers = Window(SegmentDetection.fiveKilometersMeters)
    package var tenKilometers = Window(SegmentDetection.tenKilometersMeters)
    package var halfMarathon = Window(SegmentDetection.halfMarathonMeters)
    package var marathon = Window(SegmentDetection.marathonMeters)
    package var minimumPace: Double = 120
    package var maximumPace: Double = 1_200
    package var elevation = Window(0, 0)
    package var maximumEvaluations: UInt64 = 0
    package var elevationEnabled: UInt8 = 0

    package init() {}

    fileprivate var paceWindows: InlineArray<7, Window> {
        [fastest400m, oneKilometer, oneMile, fiveKilometers, tenKilometers, halfMarathon, marathon]
    }
}

package struct SegmentDetectionResult: Sendable {
    package fileprivate(set) var candidates = InlineArray<10, SegmentDetectionCandidate>(repeating: SegmentDetectionCandidate())
    package fileprivate(set) var candidateCount = 0
    package fileprivate(set) var paceEvaluationCount: UInt64 = 0
    package fileprivate(set) var elevationEvaluationCount: UInt64 = 0

    fileprivate mutating func append(_ candidate: SegmentDetectionCandidate?) {
        guard let candidate, candidateCount < candidates.count else { return }
        candidates[candidateCount] = candidate
        candidateCount += 1
    }
}

package enum SegmentDetection {
    package static let oneMileMeters: Double = 1_609.344
    package static let fiveKilometersMeters: Double = 5_000
    package static let tenKilometersMeters: Double = 10_000
    package static let halfMarathonMeters: Double = 21_097.5
    package static let marathonMeters: Double = 42_195
    package static let paceSearchCount: UInt64 = 7

    private struct Location {
        let before: Int
        let after: Int
        let fraction: Double

        init(_ before: Int, _ after: Int, _ fraction: Double = 0) {
            self.before = before
            self.after = after
            self.fraction = fraction
        }

        init(exact index: Int) { self.init(index, index) }
    }

    /// `std::lower_bound` (or `upper_bound`) over the sorted distances. The
    /// halving form keeps the loop free of data-dependent branches, so the
    /// compiler can select between the two bounds without a mispredicted jump.
    @inline(__always)
    private static func bound(
        _ samples: borrowing Span<SegmentDetectionSample>, target: Double, upper: Bool
    ) -> Int {
        var low = 0
        var length = samples.count
        while length > 0 {
            let half = length >> 1
            let middle = low + half
            let distance = samples[middle].distance
            let advance = upper ? distance <= target : distance < target
            low = advance ? middle + 1 : low
            length = advance ? length - half - 1 : half
        }
        return low
    }

    @inline(__always)
    private static func location(
        _ samples: borrowing Span<SegmentDetectionSample>, distance: Double, start: Bool, elevation: Bool
    ) -> Location? {
        let count = samples.count
        guard count != 0 else { return nil }
        let target = max(samples[0].distance, min(distance, samples[count - 1].distance))
        let first = bound(samples, target: target, upper: false)
        if first < count, samples[first].distance == target {
            // An exact match proves upper_bound is greater than zero.
            let last = bound(samples, target: target, upper: true) - 1
            if elevation {
                return Location(exact: start ? last : first)
            }
            if samples[first].continuityGroup == samples[last].continuityGroup {
                return Location(exact: !start && last == count - 1 ? last : first)
            }
            if start {
                let group = samples[last].continuityGroup
                var selected = last
                // The span is read outside `&&`: a span read inside that autoclosure
                // crashes Swift 6.3.3 in an optimized build (CopyPropagation).
                while selected > first {
                    guard samples[selected - 1].continuityGroup == group else { break }
                    selected -= 1
                }
                return Location(exact: selected)
            }
            let group = samples[first].continuityGroup
            var selected = first
            while selected < last {
                guard samples[selected + 1].continuityGroup == group else { break }
                selected += 1
            }
            return Location(exact: selected)
        }

        if first == 0 { return Location(exact: 0) }
        if first >= count { return Location(exact: count - 1) }
        let before = first - 1
        let a = samples[before]
        let b = samples[first]
        if a.continuityGroup != b.continuityGroup {
            return Location(exact: start ? first : before)
        }
        let width = b.distance - a.distance
        guard width > 0 else { return Location(exact: start ? first : before) }
        let fraction = max(0, min(1, (target - a.distance) / width))
        return Location(before, first, fraction)
    }

    @inline(__always)
    private static func interpolate(_ before: Double, _ after: Double, _ fraction: Double) -> Double {
        let difference = after - before
        let scaled = difference * fraction
        return before + scaled
    }

    @inline(__always)
    private static func clocks(
        _ samples: borrowing Span<SegmentDetectionSample>, distance: Double, start: Bool
    ) -> (elapsed: Double, active: Double)? {
        guard let loc = location(samples, distance: distance, start: start, elevation: false) else { return nil }
        let before = samples[loc.before]
        if loc.before == loc.after { return (before.elapsed, before.active) }
        let after = samples[loc.after]
        return (
            interpolate(before.elapsed, after.elapsed, loc.fraction),
            interpolate(before.active, after.active, loc.fraction)
        )
    }

    private static func validateInput(_ samples: borrowing Span<SegmentDetectionSample>) throws(SegmentDetectionError) {
        guard samples.count <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }
        let first = samples[0]
        guard first.isFinite, first.distance >= 0, first.elapsed >= 0, first.active >= 0,
              first.active - first.elapsed <= 1e-12,
              first.ascent >= 0, first.descent >= 0, first.reliableCount >= 0, first.continuityGroup == 0,
              first.reliableRun == -1 || first.reliableRun == 0
        else { throw .invalidInputContract }

        var previous = first
        var lastCompletedRun: Int32 = -1
        for i in 1..<samples.count {
            let sample = samples[i]
            guard sample.isFinite, sample.distance >= previous.distance,
                  sample.elapsed >= previous.elapsed, sample.active >= previous.active,
                  sample.active - sample.elapsed <= 1e-12,
                  sample.ascent >= previous.ascent, sample.descent >= previous.descent,
                  sample.reliableCount >= previous.reliableCount,
                  sample.continuityGroup >= 0, sample.continuityGroup >= previous.continuityGroup
            else { throw .invalidInputContract }

            let delta = sample.continuityGroup - previous.continuityGroup
            guard delta <= 1,
                  delta == 0 || sample.reliableRun < 0 || sample.reliableRun != previous.reliableRun,
                  sample.reliableRun >= -1
            else { throw .invalidInputContract }
            if sample.reliableRun != previous.reliableRun {
                if previous.reliableRun >= 0 {
                    guard previous.reliableRun > lastCompletedRun else { throw .invalidInputContract }
                    lastCompletedRun = previous.reliableRun
                }
                if sample.reliableRun >= 0 {
                    // IDs start at zero and grow by only one per sample;
                    // the preceding 1,250,000-point cap keeps Int32 in range.
                    guard sample.reliableRun == lastCompletedRun + 1 else { throw .invalidInputContract }
                }
            }
            previous = sample
        }
        if previous.reliableRun >= 0, previous.reliableRun <= lastCompletedRun {
            throw .invalidInputContract
        }
    }

    private static func validateConfiguration(_ config: SegmentDetectionConfiguration) throws(SegmentDetectionError) {
        let windows = config.paceWindows
        for i in 0..<windows.count where !windows[i].isValid { throw .invalidConfiguration }
        guard config.minimumPace.isFinite, config.maximumPace.isFinite,
              config.minimumPace > 0, config.maximumPace >= config.minimumPace,
              config.elevation.distance.isFinite, config.elevation.step.isFinite,
              config.elevationEnabled <= 1, config.maximumEvaluations > 0,
              config.elevationEnabled == 0 || config.elevation.isValid
        else { throw .invalidConfiguration }
    }

    /// A fastest-only sweep or the combined 1 km fastest/slowest sweep.
    private static func pace(
        _ samples: borrowing Span<SegmentDetectionSample>,
        window: SegmentDetectionConfiguration.Window,
        fastestKind: SegmentDetectionKind, recordSlowest: Bool,
        total: Double, config: SegmentDetectionConfiguration
    ) -> (fastest: SegmentDetectionCandidate?, slowest: SegmentDetectionCandidate?, evaluations: UInt64) {
        guard total >= window.distance, window.step > 0, samples.count >= 2 else { return (nil, nil, 0) }
        var fastest: SegmentDetectionCandidate?
        var slowest: SegmentDetectionCandidate?
        var fastestPace = Double.infinity
        var slowestPace = 0.0
        var evaluations: UInt64 = 0
        var start = samples[0].distance
        while start + window.distance <= total, evaluations < config.maximumEvaluations {
            evaluations += 1
            let end = start + window.distance
            guard let a = clocks(samples, distance: start, start: true),
                  let b = clocks(samples, distance: end, start: false)
            else { break }

            let elapsed = max(0, b.elapsed - a.elapsed)
            let active = min(max(0, b.active - a.active), elapsed)
            let evaluatedDistance = end - start
            if active > 0, evaluatedDistance > 0 {
                // This is the rounded distance between boundaries, not the
                // configured mathematical window length.
                let value = (active / evaluatedDistance) * 1000
                if value.isFinite, value >= config.minimumPace, value <= config.maximumPace {
                    if value < fastestPace {
                        fastestPace = value
                        fastest = SegmentDetectionCandidate(fastestKind, start, end, value)
                    }
                    if recordSlowest, value > slowestPace {
                        slowestPace = value
                        slowest = SegmentDetectionCandidate(.slowest1km, start, end, value)
                    }
                }
            }
            start += window.step
        }
        return (fastest, slowest, evaluations)
    }

    private struct ElevationValues {
        let ascent: Double
        let descent: Double
        let reliableCount: Double

        init(_ before: SegmentDetectionSample, _ after: SegmentDetectionSample, _ location: Location, start: Bool) {
            if location.before == location.after || before.continuityGroup != after.continuityGroup {
                let sample = start && location.before != location.after ? after : before
                ascent = sample.ascent
                descent = sample.descent
                reliableCount = sample.reliableCount
            } else {
                ascent = interpolate(before.ascent, after.ascent, location.fraction)
                descent = interpolate(before.descent, after.descent, location.fraction)
                reliableCount = interpolate(before.reliableCount, after.reliableCount, location.fraction)
            }
        }
    }

    private static func elevation(
        _ samples: borrowing Span<SegmentDetectionSample>,
        total: Double, config: SegmentDetectionConfiguration
    ) -> (climb: SegmentDetectionCandidate?, descent: SegmentDetectionCandidate?, evaluations: UInt64) {
        let window = config.elevation
        guard total >= window.distance, window.step > 0, samples.count >= 2 else { return (nil, nil, 0) }
        var climb: SegmentDetectionCandidate?
        var descent: SegmentDetectionCandidate?
        var bestClimb = 0.0
        var bestDescent = -0.0
        var evaluations: UInt64 = 0
        var start = samples[0].distance
        while start + window.distance <= total, evaluations < config.maximumEvaluations {
            evaluations += 1
            let end = start + window.distance
            defer { start += window.step }
            guard let a = location(samples, distance: start, start: true, elevation: true),
                  let b = location(samples, distance: end, start: false, elevation: true)
            else { continue }

            // The C++ code repeats these pure distance lookups for each
            // cumulative field. Reuse the same locations without changing
            // boundary selection or arithmetic within any field.
            let startBefore = samples[a.before]
            let startAfter = samples[a.after]
            let endBefore = samples[b.before]
            let endAfter = samples[b.after]
            let run = startBefore.reliableRun
            guard run >= 0, run == startAfter.reliableRun, run == endBefore.reliableRun, run == endAfter.reliableRun
            else { continue }

            let first = ElevationValues(startBefore, startAfter, a, start: true)
            let last = ElevationValues(endBefore, endAfter, b, start: false)
            guard last.reliableCount > first.reliableCount else { continue }

            let rise = max(0, last.ascent - first.ascent)
            let fall = max(0, last.descent - first.descent)
            if rise > bestClimb {
                bestClimb = rise
                climb = SegmentDetectionCandidate(.biggestClimb, start, end, rise)
            }
            let negativeDescent = -fall
            if negativeDescent < bestDescent {
                bestDescent = negativeDescent
                descent = SegmentDetectionCandidate(.biggestDescent, start, end, negativeDescent)
            }
        }
        return (climb, descent, evaluations)
    }

    package static func search(
        _ samples: borrowing Span<SegmentDetectionSample>,
        configuration config: SegmentDetectionConfiguration
    ) throws(SegmentDetectionError) -> SegmentDetectionResult {
        var result = SegmentDetectionResult()
        guard !samples.isEmpty else { return result }
        try validateConfiguration(config)
        try validateInput(samples)

        let total = samples[samples.count - 1].distance
        let span = total - samples[0].distance
        let windows = config.paceWindows
        for i in 0..<windows.count where !windows[i].fits(span, maximum: config.maximumEvaluations) {
            throw .resourceLimit
        }
        if config.elevationEnabled == 1, !config.elevation.fits(span, maximum: config.maximumEvaluations) {
            throw .resourceLimit
        }

        let kinds: InlineArray<7, SegmentDetectionKind> = [
            .fastest400m, .fastest1km, .fastestOneMile, .fastest5km, .fastest10km, .fastestHalfMarathon, .fastestMarathon,
        ]
        for i in 0..<windows.count {
            let evaluated = pace(
                samples, window: windows[i], fastestKind: kinds[i], recordSlowest: i == 1,
                total: total, config: config
            )
            result.paceEvaluationCount &+= evaluated.evaluations
            result.append(evaluated.fastest)
            if i == 1 {
                result.append(evaluated.slowest)
                if config.elevationEnabled == 1 {
                    let evaluated = elevation(samples, total: total, config: config)
                    result.elevationEvaluationCount = evaluated.evaluations
                    result.append(evaluated.climb)
                    result.append(evaluated.descent)
                }
            }
        }
        return result
    }
}
