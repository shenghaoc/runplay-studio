import Foundation

// Keep imported C++ declarations confined to the internal Interop layer.
internal import CxxStdlib
internal import RunPlayEngineCpp

// MARK: - Pure-Swift types matching the C++ contract

enum RunPlaySegmentWindowKind: UInt8, Sendable, Equatable {
    case fastest400m = 0
    case fastest1km = 1
    case slowest1km = 2
    case biggestClimb = 3
    case biggestDescent = 4
}

struct RunPlaySegmentWindowCandidate: Equatable, Sendable {
    let kind: RunPlaySegmentWindowKind
    let startDistanceMeters: Double
    let endDistanceMeters: Double
    let selectionValue: Double
}

struct RunPlaySegmentWindowSearchResult: Sendable {
    let candidates: [RunPlaySegmentWindowCandidate]
    let paceEvaluationCount: Int
    let elevationEvaluationCount: Int
}

enum RunPlaySegmentDetectorBridgeError: Error, Equatable {
    case resourceLimit
    case invalidConfiguration
    case invalidInputContract
    case engineContractViolation
}

// MARK: - Pure-Swift search configuration

struct SegmentDetectorSearchConfiguration: Sendable {
    let fastest400mDistanceMeters: Double
    let fastest400mStepMeters: Double
    let oneKilometerDistanceMeters: Double
    let oneKilometerStepMeters: Double
    let minimumValidPaceSecondsPerKilometer: Double
    let maximumValidPaceSecondsPerKilometer: Double
    let elevationEnabled: Bool
    let elevationWindowDistanceMeters: Double
    let elevationStepMeters: Double
    let maximumEvaluationsPerSearch: UInt64
}

// MARK: - Bridge

enum RunPlaySegmentDetectorBridge {
    /// Test-only invocation counter for native window-search calls.
    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private static let invocationCounter = InvocationCounter()

    static var nativeInvocationCount: Int {
        invocationCounter.value
    }

    static func resetNativeInvocationCountForTests() {
        invocationCounter.reset()
    }

    private static func recordNativeInvocation() {
        invocationCounter.increment()
    }

    static func search(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        configuration: SegmentDetectorSearchConfiguration,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlaySegmentWindowSearchResult {
        let count = routePoints.count

        // Product limit
        guard count <= WorkoutImportResourceLimits.maxRoutePointCount else {
            throw RunPlaySegmentDetectorBridgeError.resourceLimit
        }

        // Empty / one-point route
        if count <= 1 {
            return RunPlaySegmentWindowSearchResult(
                candidates: [],
                paceEvaluationCount: 0,
                elevationEvaluationCount: 0
            )
        }

        return try searchNative(
            routePoints: routePoints,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: configuration,
            cancellationCheckStride: max(1, cancellationCheckStride),
            isCancelled: isCancelled
        )
    }

    private static func searchNative(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        configuration: SegmentDetectorSearchConfiguration,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlaySegmentWindowSearchResult {
        let count = routePoints.count

        // Snapshots
        let timelineSnapshot = timeline.segmentDetectionSnapshot()
        let elevationSnapshot = elevationProfile.segmentDetectionSnapshot()

        // Verify array alignment
        guard timelineSnapshot.distancesMeters.count == count,
              timelineSnapshot.elapsedSeconds.count == count,
              timelineSnapshot.activeSeconds.count == count,
              elevationSnapshot.cumulativeAscentMeters.count == count,
              elevationSnapshot.cumulativeDescentMeters.count == count,
              elevationSnapshot.reliableIntervalCounts.count == count,
              elevationSnapshot.reliableRunIdentifiers.count == count
        else {
            throw RunPlaySegmentDetectorBridgeError.invalidInputContract
        }

        // Build compact native samples
        var samples = ContiguousArray<runplay.SegmentDetectionSample>()
        samples.reserveCapacity(count)

        // Compact continuity groups from route-segment transitions
        var compactGroup: Int32 = 0
        var previousRouteSegment: Int? = nil

        // Compact reliable run identifiers
        var compactReliableRun: Int32 = 0
        var previousRawReliableRun: Int?

        for index in 0..<count {
            if index.isMultiple(of: cancellationCheckStride), isCancelled() {
                throw CancellationError()
            }

            let point = routePoints[index]
            let segment = point.routeSegmentIndex

            // Compact route continuity groups
            if let prev = previousRouteSegment {
                if segment != prev {
                    compactGroup += 1
                }
            }
            previousRouteSegment = segment

            // Compact reliable run identifiers
            let rawRun = elevationSnapshot.reliableRunIdentifiers[index]
            let mappedRun: Int32
            if let raw = rawRun {
                if let prev = previousRawReliableRun {
                    if raw != prev {
                        compactReliableRun += 1
                    }
                }
                // First reliable run uses current compactReliableRun (starts at 0)
                mappedRun = compactReliableRun
                // Keep the previous reliable run across nil samples. A missing
                // elevation interval separates runs, and the next non-nil raw
                // identifier must advance the compact identifier.
                previousRawReliableRun = raw
            } else {
                mappedRun = -1
            }

            var sample = runplay.SegmentDetectionSample()
            sample.distance_meters = timelineSnapshot.distancesMeters[index]
            sample.elapsed_seconds = timelineSnapshot.elapsedSeconds[index]
            sample.active_seconds = timelineSnapshot.activeSeconds[index]
            sample.cumulative_ascent_meters = elevationSnapshot.cumulativeAscentMeters[index]
            sample.cumulative_descent_meters = elevationSnapshot.cumulativeDescentMeters[index]
            sample.reliable_interval_count = elevationSnapshot.reliableIntervalCounts[index]
            sample.continuity_group = compactGroup
            sample.reliable_elevation_run = mappedRun

            samples.append(sample)
        }

        // Native configuration
        var nativeConfig = runplay.SegmentDetectionConfiguration()
        nativeConfig.fastest_400m_distance_meters = configuration.fastest400mDistanceMeters
        nativeConfig.fastest_400m_step_meters = configuration.fastest400mStepMeters
        nativeConfig.one_kilometer_distance_meters = configuration.oneKilometerDistanceMeters
        nativeConfig.one_kilometer_step_meters = configuration.oneKilometerStepMeters
        nativeConfig.minimum_valid_pace_seconds_per_kilometer = configuration.minimumValidPaceSecondsPerKilometer
        nativeConfig.maximum_valid_pace_seconds_per_kilometer = configuration.maximumValidPaceSecondsPerKilometer
        nativeConfig.elevation_window_distance_meters = configuration.elevationWindowDistanceMeters
        nativeConfig.elevation_step_meters = configuration.elevationStepMeters
        nativeConfig.maximum_evaluations_per_search = configuration.maximumEvaluationsPerSearch
        nativeConfig.elevation_enabled = configuration.elevationEnabled ? 1 : 0

        // Allocate exactly five output candidates
        var output = ContiguousArray<runplay.SegmentWindowCandidate>(
            repeating: runplay.SegmentWindowCandidate(),
            count: Int(runplay.segment_detection_max_candidate_count)
        )

        // Cancellation check before native call
        try checkCancellation(isCancelled: isCancelled)

        // One native call
        recordNativeInvocation()
        let summary = samples.withUnsafeBufferPointer { samplesBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                runplay.detect_segment_windows(
                    samplesBuffer.baseAddress,
                    samplesBuffer.count,
                    nativeConfig,
                    outputBuffer.baseAddress,
                    outputBuffer.count
                )
            }
        }

        // Cancellation check after native call
        try checkCancellation(isCancelled: isCancelled)

        // Validate result
        switch summary.status {
        case .success:
            break
        case .resource_limit:
            throw RunPlaySegmentDetectorBridgeError.resourceLimit
        case .invalid_configuration:
            throw RunPlaySegmentDetectorBridgeError.invalidConfiguration
        case .invalid_input_contract:
            throw RunPlaySegmentDetectorBridgeError.invalidInputContract
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .internal_failure:
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        default:
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        guard summary.sample_count == UInt64(count) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        let maximumCandidateCount = Int(runplay.segment_detection_max_candidate_count)
        guard summary.candidate_count <= UInt64(maximumCandidateCount) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }
        let candidateCount = Int(summary.candidate_count)
        guard summary.required_output_capacity == UInt64(maximumCandidateCount) else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        // Translate candidates with validation
        var candidates: [RunPlaySegmentWindowCandidate] = []
        candidates.reserveCapacity(candidateCount)
        var seenKinds: Set<RunPlaySegmentWindowKind> = []

        for i in 0..<candidateCount {
            let c = output[i]

            guard let kind = RunPlaySegmentWindowKind(rawValue: c.kind.rawValue) else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

            guard seenKinds.insert(kind).inserted else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

            let startDistance = c.start_distance_meters
            let endDistance = c.end_distance_meters
            let value = c.selection_value

            guard startDistance.isFinite,
                  endDistance.isFinite,
                  value.isFinite,
                  startDistance <= endDistance,
                  startDistance >= timeline.startDistanceMeters,
                  endDistance <= timeline.totalDistanceMeters
            else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

            switch kind {
            case .fastest400m, .fastest1km, .slowest1km:
                let minPace = configuration.minimumValidPaceSecondsPerKilometer
                let maxPace = configuration.maximumValidPaceSecondsPerKilometer
                if value < minPace || value > maxPace {
                    throw RunPlaySegmentDetectorBridgeError.engineContractViolation
                }
            case .biggestClimb:
                if !(value > 0) {
                    throw RunPlaySegmentDetectorBridgeError.engineContractViolation
                }
            case .biggestDescent:
                if !(value < 0) {
                    throw RunPlaySegmentDetectorBridgeError.engineContractViolation
                }
            }

            let expectedWindowDistance: Double
            switch kind {
            case .fastest400m:
                expectedWindowDistance = configuration.fastest400mDistanceMeters
            case .fastest1km, .slowest1km:
                expectedWindowDistance = configuration.oneKilometerDistanceMeters
            case .biggestClimb, .biggestDescent:
                expectedWindowDistance = configuration.elevationWindowDistanceMeters
            }
            let expectedEndDistance = startDistance + expectedWindowDistance
            guard endDistance == expectedEndDistance else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

            candidates.append(RunPlaySegmentWindowCandidate(
                kind: kind,
                startDistanceMeters: startDistance,
                endDistanceMeters: endDistance,
                selectionValue: value
            ))
        }

        // Verify deterministic order (kinds appear in expected display-priority order)
        let expectedOrder: [RunPlaySegmentWindowKind] = [
            .fastest400m, .fastest1km, .slowest1km, .biggestClimb, .biggestDescent
        ]
        var orderIndex = 0
        for candidate in candidates {
            while orderIndex < expectedOrder.count,
                  expectedOrder[orderIndex] != candidate.kind {
                orderIndex += 1
            }
            guard orderIndex < expectedOrder.count else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }
        }

        let (maximumPaceEvaluations, paceLimitOverflow) =
            configuration.maximumEvaluationsPerSearch.multipliedReportingOverflow(by: 2)
        guard !paceLimitOverflow,
              summary.pace_window_evaluation_count <= maximumPaceEvaluations,
              summary.elevation_window_evaluation_count
                <= configuration.maximumEvaluationsPerSearch,
              let paceEvalCount = Int(exactly: summary.pace_window_evaluation_count),
              let elevEvalCount = Int(exactly: summary.elevation_window_evaluation_count)
        else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        return RunPlaySegmentWindowSearchResult(
            candidates: candidates,
            paceEvaluationCount: paceEvalCount,
            elevationEvaluationCount: elevEvalCount
        )
    }

    private static func checkCancellation(
        isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() {
            throw CancellationError()
        }
    }
}
