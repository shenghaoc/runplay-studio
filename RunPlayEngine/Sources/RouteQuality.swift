/// Selection strategies and diagnostic values of the route-quality kernel.
package enum EngineRouteDistancePolicy {
    case coordinates, allSupplied, suppliedPerSegment, suppliedForSelection
}

package enum EngineRouteDistanceSource: UInt8 {
    case coordinates, supplied, mixed
}

package struct EngineRouteQualityPolicy {
    package var maximumRunningSpeed: Double
    package var usefulAccuracy: Double
    package var minimumSpikeExcess: Double
    package var minimumSpikeDistortion: Double
    package var poorAccuracyMultiplier: Double
    package var minimumGapDistance: Double
    package var minimumGapInterval: Double
    package var minimumGapRatio: Double
    package var confirmationCount: UInt64
    package var maximumClusterStep: Double

    package init(
        maximumRunningSpeed: Double, usefulAccuracy: Double,
        minimumSpikeExcess: Double, minimumSpikeDistortion: Double, poorAccuracyMultiplier: Double,
        minimumGapDistance: Double, minimumGapInterval: Double, minimumGapRatio: Double,
        confirmationCount: UInt64, maximumClusterStep: Double
    ) {
        self.maximumRunningSpeed = maximumRunningSpeed
        self.usefulAccuracy = usefulAccuracy
        self.minimumSpikeExcess = minimumSpikeExcess
        self.minimumSpikeDistortion = minimumSpikeDistortion
        self.poorAccuracyMultiplier = poorAccuracyMultiplier
        self.minimumGapDistance = minimumGapDistance
        self.minimumGapInterval = minimumGapInterval
        self.minimumGapRatio = minimumGapRatio
        self.confirmationCount = confirmationCount
        self.maximumClusterStep = maximumClusterStep
    }

    fileprivate var isValid: Bool {
        maximumRunningSpeed.isFinite && usefulAccuracy.isFinite
            && minimumSpikeExcess.isFinite && minimumSpikeDistortion.isFinite
            && poorAccuracyMultiplier.isFinite && minimumGapDistance.isFinite
            && minimumGapInterval.isFinite && minimumGapRatio.isFinite && maximumClusterStep.isFinite
            && maximumRunningSpeed >= 0 && usefulAccuracy >= 0 && minimumSpikeExcess >= 0
            && minimumGapDistance >= 0 && minimumGapInterval >= 0 && maximumClusterStep >= 0
            && minimumSpikeDistortion >= 1 && minimumGapRatio >= 1
            && poorAccuracyMultiplier >= 0 && poorAccuracyMultiplier <= 1
            && confirmationCount >= 2 && confirmationCount <= UInt64(UInt.max)
    }
}

package struct EngineRouteQualityOutput {
    package let sourceIndex: UInt64
    package fileprivate(set) var normalizedSegmentIndex: Int64 = 0
    package fileprivate(set) var normalizedDistance: Double = 0
    package fileprivate(set) var distanceSource: EngineRouteDistanceSource = .coordinates
    package fileprivate(set) var retained = true
    package fileprivate(set) var rejected = false
    package fileprivate(set) var inferredBoundary = false

    fileprivate init(sourceIndex: UInt64) {
        self.sourceIndex = sourceIndex
    }
}

package struct EngineRouteQualityResult {
    package let samples: [EngineRouteQualityOutput]
    package let retainedCount: Int
    package let discardedCount: Int
    package let inferredGapCount: Int
    package let segmentCount: Int
    package let distanceSource: EngineRouteDistanceSource
    package let totalDistance: Double
}

package enum RouteQualityError: Error, Equatable {
    case invalidSelectionBuffer
    case invalidPolicy
    case invalidInputContract
    case resourceLimit
}

package enum EngineRouteQuality {
    package static func process(
        _ samples: borrowing Span<EngineRouteInputSample>,
        policy: EngineRouteQualityPolicy,
        distancePolicy: EngineRouteDistancePolicy,
        selection: consuming Span<UInt8>?
    ) throws(RouteQualityError) -> EngineRouteQualityResult {
        guard samples.count <= EngineRouteLimits.maxRouteInputSamples else { throw .resourceLimit }
        if samples.count == 0 {
            return EngineRouteQualityResult(
                samples: [], retainedCount: 0, discardedCount: 0, inferredGapCount: 0,
                segmentCount: 0, distanceSource: .coordinates, totalDistance: 0
            )
        }
        guard policy.isValid else { throw .invalidPolicy }
        guard validateInput(samples) else { throw .invalidInputContract }
        switch consume selection {
        case .some(let selected):
            guard distancePolicy == .suppliedForSelection, validateSelection(samples, selected) else {
                throw .invalidSelectionBuffer
            }
            return processValidated(samples, policy, distancePolicy, selected)
        case .none:
            guard distancePolicy != .suppliedForSelection else { throw .invalidSelectionBuffer }
            return processValidated(samples, policy, distancePolicy, Span<UInt8>())
        }
    }

    private static func processValidated(
        _ samples: borrowing Span<EngineRouteInputSample>, _ policy: EngineRouteQualityPolicy,
        _ distancePolicy: EngineRouteDistancePolicy, _ selection: borrowing Span<UInt8>
    ) -> EngineRouteQualityResult {

        // SAFETY: the initializer writes exactly one element per allocated slot.
        var output = unsafe Array<EngineRouteQualityOutput>(unsafeUninitializedCapacity: samples.count) {
            buffer, count in
            for index in 0..<samples.count {
                // SAFETY: every index is within the allocated capacity and initialized once.
                unsafe buffer.initializeElement(
                    at: index, to: EngineRouteQualityOutput(sourceIndex: samples[index].sourceIndex)
                )
            }
            count = samples.count
        }
        var discarded = 0
        var retained = 0
        let inferredGaps: Int
        let segments: Int
        let normalization: (source: EngineRouteDistanceSource, distance: Double)
        do {
            // One exclusive window; no array copy-on-write checks in the geometry passes.
            var workspace = output.mutableSpan
            markCandidates(samples, &workspace, policy)
            for index in 0..<workspace.count {
                let entry = workspace[index]
                if entry.retained { retained += 1 }
                if entry.rejected { discarded += 1 }
            }
            inferredGaps = inferGaps(samples, &workspace, policy)
            segments = compactSegments(samples, &workspace)
            normalization = normalizeDistances(samples, &workspace, distancePolicy, selection, segments)
        }
        return EngineRouteQualityResult(
            samples: output, retainedCount: retained, discardedCount: discarded,
            inferredGapCount: inferredGaps, segmentCount: segments,
            distanceSource: normalization.source, totalDistance: normalization.distance
        )
    }

    private static func validateInput(_ samples: borrowing Span<EngineRouteInputSample>) -> Bool {
        var expectedSegment: Int64 = 0
        var previousElapsed = -Double.infinity
        var previousSegment: Int64 = -1
        for index in 0..<samples.count {
            let sample = samples[index]
            guard EngineGeodesy.isValidCoordinate(latitude: sample.latitude, longitude: sample.longitude),
                  sample.timestampSecondsSinceReferenceDate.isFinite,
                  sample.elapsedSeconds.isFinite,
                  sample.elapsedSeconds >= 0,
                  sample.elapsedSeconds >= previousElapsed
            else { return false }
            previousElapsed = sample.elapsedSeconds
            let segment = sample.routeSegmentIndex
            guard segment >= 0 else { return false }
            if index == 0 {
                guard segment == 0 else { return false }
                previousSegment = 0
                expectedSegment = 0
                continue // The first point's optional accuracy is not checked, as in the former C++ kernel.
            }
            guard segment >= previousSegment else { return false }
            if segment > previousSegment {
                guard segment == previousSegment + 1 else { return false }
                expectedSegment = segment
            } else if segment != expectedSegment {
                return false
            }
            previousSegment = segment
            if let accuracy = sample.horizontalAccuracy, !accuracy.isFinite || accuracy < 0 {
                return false
            }
        }
        return true
    }

    private static func validateSelection(
        _ samples: borrowing Span<EngineRouteInputSample>, _ selection: borrowing Span<UInt8>
    ) -> Bool {
        guard selection.count == samples.count else { return false }
        var segment = samples[0].routeSegmentIndex
        var value = selection[0]
        for index in 0..<samples.count {
            let entry = selection[index]
            guard entry == 0 || entry == 1 else { return false }
            if samples[index].routeSegmentIndex != segment {
                segment = samples[index].routeSegmentIndex
                value = entry
            } else if entry != value {
                return false
            }
        }
        return true
    }

    private static func duration(_ first: EngineRouteInputSample, _ second: EngineRouteInputSample) -> Double {
        second.timestampSecondsSinceReferenceDate - first.timestampSecondsSinceReferenceDate
    }

    private static func distance(_ first: EngineRouteInputSample, _ second: EngineRouteInputSample) -> Double {
        EngineGeodesy.distanceMeters(
            latitude1: first.latitude, longitude1: first.longitude,
            latitude2: second.latitude, longitude2: second.longitude
        )
    }

    private static func impliedSpeed(_ first: EngineRouteInputSample, _ second: EngineRouteInputSample) -> Double? {
        let interval = duration(first, second)
        guard interval.isFinite, interval > 0 else { return nil }
        let metres = distance(first, second)
        guard metres.isFinite, metres >= 0 else { return nil }
        return metres / interval
    }

    private static func poorAccuracySupportsRejection(
        _ previous: EngineRouteInputSample, _ candidate: EngineRouteInputSample,
        _ next: EngineRouteInputSample, _ policy: EngineRouteQualityPolicy
    ) -> Bool {
        guard let accuracy = candidate.horizontalAccuracy, accuracy > policy.usefulAccuracy else { return false }
        var anyNeighbour = false
        if let previous = previous.horizontalAccuracy {
            anyNeighbour = true
            guard previous <= policy.usefulAccuracy && previous < accuracy else { return false }
        }
        if let next = next.horizontalAccuracy {
            anyNeighbour = true
            guard next <= policy.usefulAccuracy && next < accuracy else { return false }
        }
        return anyNeighbour
    }

    private static func markCandidates(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: inout MutableSpan<EngineRouteQualityOutput>,
        _ policy: EngineRouteQualityPolicy
    ) {
        guard samples.count >= 3 else { return }
        let interior = 1..<(samples.count - 1)
        for index in interior {
            let previous = samples[index - 1]
            let candidate = samples[index]
            let next = samples[index + 1]
            guard previous.routeSegmentIndex == candidate.routeSegmentIndex,
                  candidate.routeSegmentIndex == next.routeSegmentIndex,
                  let inbound = impliedSpeed(previous, candidate), inbound > policy.maximumRunningSpeed,
                  let outbound = impliedSpeed(candidate, next), outbound > policy.maximumRunningSpeed,
                  let bridge = impliedSpeed(previous, next), bridge <= policy.maximumRunningSpeed
            else { continue }
            let inboundDistance = distance(previous, candidate)
            let outboundDistance = distance(candidate, next)
            let bridgeDistance = distance(previous, next)
            let pathDistance = inboundDistance + outboundDistance
            let distortion = pathDistance / firstOnMaxTie(1, bridgeDistance)
            let accuracySupports = poorAccuracySupportsRejection(previous, candidate, next, policy)
            let requiredExcess = policy.minimumSpikeExcess * (accuracySupports ? policy.poorAccuracyMultiplier : 1)
            if pathDistance - bridgeDistance >= requiredExcess && distortion >= policy.minimumSpikeDistortion {
                output[index].rejected = true
            }
        }
        // Preserve every candidate flag until the adjacency decisions are complete.
        for index in interior where output[index].rejected {
            if !output[index - 1].rejected && !output[index + 1].rejected {
                output[index].retained = false
            }
        }
        for index in interior where output[index].rejected && output[index].retained {
            output[index].rejected = false
        }
    }
}

extension EngineRouteQuality {
    private static func confirmationEnd(
        _ output: borrowing Span<EngineRouteQualityOutput>, start: Int, count: UInt64
    ) -> Int {
        var seen: UInt64 = 0
        for index in start..<output.count where output[index].retained {
            seen += 1
            if seen == count { return index + 1 }
        }
        return output.count + 1
    }

    private static func confirmsTimeDiscontinuity(
        _ interval: Double, _ samples: borrowing Span<EngineRouteInputSample>,
        _ output: borrowing Span<EngineRouteQualityOutput>, start: Int, policy: EngineRouteQualityPolicy
    ) -> Bool {
        guard interval.isFinite, interval > 0 else { return false }
        let end = confirmationEnd(output, start: start, count: policy.confirmationCount)
        guard end <= output.count else { return false }

        var longest = 0.0
        var previous = start
        for index in (start + 1)..<end where output[index].retained {
            let candidate = duration(samples[previous], samples[index])
            guard candidate.isFinite, candidate > 0 else { return false }
            longest = firstOnMaxTie(longest, candidate)
            previous = index
        }
        guard longest > 0 else { return false }
        return interval / longest >= policy.minimumGapRatio
    }

    private static func confirmsRelocatedCluster(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: borrowing Span<EngineRouteQualityOutput>,
        start: Int, policy: EngineRouteQualityPolicy
    ) -> Bool {
        let end = confirmationEnd(output, start: start, count: policy.confirmationCount)
        guard end <= output.count else { return false }
        let segment = samples[start].routeSegmentIndex
        var retained = 0
        for index in start..<end where output[index].retained {
            retained += 1
            guard samples[index].routeSegmentIndex == segment else { return false }
        }
        guard retained >= 2 else { return false }
        var previousIndex = start
        for index in (start + 1)..<end where output[index].retained {
            let previous = samples[previousIndex]
            let current = samples[index]
            let step = distance(previous, current)
            let interval = duration(previous, current)
            if interval.isFinite && interval > 0 {
                guard step / interval <= policy.maximumRunningSpeed else { return false }
            } else if step > policy.maximumClusterStep {
                return false
            }
            previousIndex = index
        }
        return true
    }

    private static func inferGaps(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: inout MutableSpan<EngineRouteQualityOutput>,
        _ policy: EngineRouteQualityPolicy
    ) -> Int {
        var retainedCount: UInt64 = 0
        for index in 0..<output.count where output[index].retained { retainedCount += 1 }
        // The C++ confirmation count is uint64_t, whose +1 wraps at UINT64_MAX.
        guard retainedCount >= (policy.confirmationCount &+ 1) else { return 0 }

        var count = 0
        var previousIndex = samples.count
        for index in 0..<samples.count where output[index].retained {
            defer { previousIndex = index }
            guard previousIndex < samples.count else { continue }
            let previous = samples[previousIndex]
            let current = samples[index]
            guard previous.routeSegmentIndex == current.routeSegmentIndex else { continue }
            let jump = distance(previous, current)
            guard jump >= policy.minimumGapDistance else { continue }
            let interval = duration(previous, current)
            let implausiblyFast = interval.isFinite && interval > 0 && jump / interval > policy.maximumRunningSpeed
            let longDiscontinuity = interval.isFinite && interval >= policy.minimumGapInterval
                && confirmsTimeDiscontinuity(interval, samples, output.span, start: index, policy: policy)
            if (implausiblyFast || longDiscontinuity)
                && confirmsRelocatedCluster(samples, output.span, start: index, policy: policy)
            {
                output[index].inferredBoundary = true
                count += 1
            }
        }
        return count
    }

    private static func compactSegments(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: inout MutableSpan<EngineRouteQualityOutput>
    ) -> Int {
        var outputSegment: Int64 = -1
        var sourceSegment = Int64.min
        for index in 0..<samples.count {
            if !output[index].retained {
                output[index].normalizedSegmentIndex = 0
                continue
            }
            let segment = samples[index].routeSegmentIndex
            if segment != sourceSegment || output[index].inferredBoundary {
                outputSegment += 1
                sourceSegment = segment
            }
            output[index].normalizedSegmentIndex = outputSegment
        }
        return Int(outputSegment + 1)
    }

    private struct SegmentScan {
        let end: Int
        let suppliedValid: Bool
    }

    private static func scanSegment(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: borrowing Span<EngineRouteQualityOutput>,
        start: Int, segment: Int64
    ) -> SegmentScan {
        var previous = -Double.infinity
        var valid = true
        var any = false
        var end = start
        for index in start..<samples.count where output[index].retained {
            if output[index].normalizedSegmentIndex != segment { break }
            end = index + 1
            any = true
            if !valid { continue }
            let distance = samples[index].distanceFromStartMeters
            if !distance.isFinite || distance < 0 || distance < previous {
                valid = false
                continue
            }
            previous = distance
        }
        return SegmentScan(end: end, suppliedValid: valid && any)
    }

    private static func nextRetained(_ output: borrowing Span<EngineRouteQualityOutput>, from: Int) -> Int {
        for index in from..<output.count where output[index].retained { return index }
        return output.count
    }

    private static func everySegmentSupplied(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: borrowing Span<EngineRouteQualityOutput>
    ) -> Bool {
        var index = nextRetained(output, from: 0)
        while index < samples.count {
            let scan = scanSegment(samples, output, start: index, segment: output[index].normalizedSegmentIndex)
            if !scan.suppliedValid { return false }
            index = nextRetained(output, from: scan.end)
        }
        return true
    }

    // std::max returns the first operand for ties, including opposite-signed zero.
    private static func firstOnMaxTie(_ first: Double, _ second: Double) -> Double {
        first < second ? second : first
    }

    private static func normalizeDistances(
        _ samples: borrowing Span<EngineRouteInputSample>, _ output: inout MutableSpan<EngineRouteQualityOutput>,
        _ policy: EngineRouteDistancePolicy, _ selection: borrowing Span<UInt8>, _ segmentCount: Int
    ) -> (source: EngineRouteDistanceSource, distance: Double) {
        guard segmentCount > 0 else { return (.coordinates, 0) }
        var suppliedCount = 0
        var cumulativeDistance = 0.0
        let allSegmentsValid = policy == .allSupplied && everySegmentSupplied(samples, output.span)

        var first = nextRetained(output.span, from: 0)
        while first < samples.count {
            let scan = scanSegment(samples, output.span, start: first, segment: output[first].normalizedSegmentIndex)
            let useSupplied = switch policy {
            case .coordinates: false
            case .allSupplied: allSegmentsValid
            case .suppliedPerSegment: scan.suppliedValid
            case .suppliedForSelection: selection[first] != 0 && scan.suppliedValid
            }
            if useSupplied { suppliedCount += 1 }
            let source: EngineRouteDistanceSource = useSupplied ? .supplied : .coordinates
            let suppliedBase = samples[first].distanceFromStartMeters
            var previous = samples.count
            for index in first..<scan.end where output[index].retained {
                output[index].distanceSource = source
                if previous >= samples.count {
                    output[index].normalizedDistance = cumulativeDistance
                } else {
                    let previousDistance = output[previous].normalizedDistance
                    if useSupplied {
                        let relative = firstOnMaxTie(0, samples[index].distanceFromStartMeters - suppliedBase)
                        let candidate = cumulativeDistance + relative
                        output[index].normalizedDistance = firstOnMaxTie(previousDistance, candidate)
                    } else {
                        // validateInput already proved both retained coordinates valid.
                        let step = distance(samples[previous], samples[index])
                        let addition = step.isFinite ? firstOnMaxTie(0, step) : 0
                        output[index].normalizedDistance = previousDistance + addition
                    }
                }
                previous = index
            }
            if previous < samples.count { cumulativeDistance = output[previous].normalizedDistance }
            first = nextRetained(output.span, from: scan.end)
        }

        let source: EngineRouteDistanceSource = if suppliedCount == 0 {
            .coordinates
        } else if suppliedCount == segmentCount {
            .supplied
        } else {
            .mixed
        }
        return (source, cumulativeDistance)
    }
}
