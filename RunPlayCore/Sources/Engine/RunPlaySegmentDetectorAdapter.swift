internal import RunPlayEngine

// MARK: - Pure-Swift types used by Core

enum RunPlaySegmentWindowKind: UInt8, Sendable, Equatable {
    case fastest400m = 0
    case fastest1km = 1
    case slowest1km = 2
    case biggestClimb = 3
    case biggestDescent = 4
    case fastestOneMile = 5
    case fastest5km = 6
    case fastest10km = 7
    case fastestHalfMarathon = 8
    case fastestMarathon = 9
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
    let oneMileDistanceMeters: Double
    let oneMileStepMeters: Double
    let fiveKilometerDistanceMeters: Double
    let fiveKilometerStepMeters: Double
    let tenKilometerDistanceMeters: Double
    let tenKilometerStepMeters: Double
    let halfMarathonDistanceMeters: Double
    let halfMarathonStepMeters: Double
    let marathonDistanceMeters: Double
    let marathonStepMeters: Double
    let minimumValidPaceSecondsPerKilometer: Double
    let maximumValidPaceSecondsPerKilometer: Double
    let elevationEnabled: Bool
    let elevationWindowDistanceMeters: Double
    let elevationStepMeters: Double
    let maximumEvaluationsPerSearch: UInt64

    /// The five personal-record window pairs default to the canonical engine
    /// lengths with the shared 50 m step. A search over a span evaluates at
    /// most span / step + 1 start positions regardless of window length, so a
    /// step at or above `RouteAnalysisBudget.boundedStep`'s span-covering
    /// floor keeps every record window inside the per-search budget — it is
    /// the step, not the relative window length, that bounds the work.
    init(
        fastest400mDistanceMeters: Double,
        fastest400mStepMeters: Double,
        oneKilometerDistanceMeters: Double,
        oneKilometerStepMeters: Double,
        oneMileDistanceMeters: Double = SegmentDetection.oneMileMeters,
        oneMileStepMeters: Double = 50,
        fiveKilometerDistanceMeters: Double = SegmentDetection.fiveKilometersMeters,
        fiveKilometerStepMeters: Double = 50,
        tenKilometerDistanceMeters: Double = SegmentDetection.tenKilometersMeters,
        tenKilometerStepMeters: Double = 50,
        halfMarathonDistanceMeters: Double = SegmentDetection.halfMarathonMeters,
        halfMarathonStepMeters: Double = 50,
        marathonDistanceMeters: Double = SegmentDetection.marathonMeters,
        marathonStepMeters: Double = 50,
        minimumValidPaceSecondsPerKilometer: Double,
        maximumValidPaceSecondsPerKilometer: Double,
        elevationEnabled: Bool,
        elevationWindowDistanceMeters: Double,
        elevationStepMeters: Double,
        maximumEvaluationsPerSearch: UInt64
    ) {
        self.fastest400mDistanceMeters = fastest400mDistanceMeters
        self.fastest400mStepMeters = fastest400mStepMeters
        self.oneKilometerDistanceMeters = oneKilometerDistanceMeters
        self.oneKilometerStepMeters = oneKilometerStepMeters
        self.oneMileDistanceMeters = oneMileDistanceMeters
        self.oneMileStepMeters = oneMileStepMeters
        self.fiveKilometerDistanceMeters = fiveKilometerDistanceMeters
        self.fiveKilometerStepMeters = fiveKilometerStepMeters
        self.tenKilometerDistanceMeters = tenKilometerDistanceMeters
        self.tenKilometerStepMeters = tenKilometerStepMeters
        self.halfMarathonDistanceMeters = halfMarathonDistanceMeters
        self.halfMarathonStepMeters = halfMarathonStepMeters
        self.marathonDistanceMeters = marathonDistanceMeters
        self.marathonStepMeters = marathonStepMeters
        self.minimumValidPaceSecondsPerKilometer = minimumValidPaceSecondsPerKilometer
        self.maximumValidPaceSecondsPerKilometer = maximumValidPaceSecondsPerKilometer
        self.elevationEnabled = elevationEnabled
        self.elevationWindowDistanceMeters = elevationWindowDistanceMeters
        self.elevationStepMeters = elevationStepMeters
        self.maximumEvaluationsPerSearch = maximumEvaluationsPerSearch
    }
}

/// Core owns snapshots, cancellation, model mapping, and diagnostic translation.
enum RunPlaySegmentDetectorAdapter {
    // Canonical personal-record window lengths, sourced from the engine
    // constants so record identity and the engine searches can never
    // drift. Internal because the public model re-exposes them as
    // `PersonalRecordCategory.nominalWindowDistanceMeters`.
    static let personalRecordOneMileMeters = SegmentDetection.oneMileMeters
    static let personalRecordFiveKmMeters = SegmentDetection.fiveKilometersMeters
    static let personalRecordTenKmMeters = SegmentDetection.tenKilometersMeters
    static let personalRecordHalfMarathonMeters = SegmentDetection.halfMarathonMeters
    static let personalRecordMarathonMeters = SegmentDetection.marathonMeters

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

        return try searchSwift(
            routePoints: routePoints,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: configuration,
            cancellationCheckStride: max(1, cancellationCheckStride),
            isCancelled: isCancelled
        )
    }

    private static func searchSwift(
        routePoints: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile,
        configuration: SegmentDetectorSearchConfiguration,
        cancellationCheckStride: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlaySegmentWindowSearchResult {
        let samples = try RunPlaySegmentDetectorAdapter.pack(
            routePoints: routePoints, timeline: timeline, elevationProfile: elevationProfile,
            cancellationCheckStride: cancellationCheckStride, isCancelled: isCancelled
        ) { distance, elapsed, active, ascent, descent, reliableCount, group, run in
            var sample = SegmentDetectionSample()
            sample.distance = distance
            sample.elapsed = elapsed
            sample.active = active
            sample.ascent = ascent
            sample.descent = descent
            sample.reliableCount = reliableCount
            sample.continuityGroup = group
            sample.reliableRun = run
            return sample
        }

        let engineConfig = engineConfiguration(configuration)

        if isCancelled() { throw CancellationError() }
        EngineCallObserver.record(.segmentDetection)
        let summary: SegmentDetectionResult
        do {
            summary = try SegmentDetection.search(samples.span, configuration: engineConfig)
        } catch {
            if isCancelled() { throw CancellationError() }
            switch error {
            case .resourceLimit: throw RunPlaySegmentDetectorBridgeError.resourceLimit
            case .invalidConfiguration: throw RunPlaySegmentDetectorBridgeError.invalidConfiguration
            case .invalidInputContract: throw RunPlaySegmentDetectorBridgeError.invalidInputContract
            default: throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }
        }
        if isCancelled() { throw CancellationError() }

        var candidates: [RunPlaySegmentWindowCandidate] = []
        candidates.reserveCapacity(summary.candidateCount)
        for index in 0..<summary.candidateCount {
            let candidate = summary.candidates[index]
            guard let kind = RunPlaySegmentWindowKind(rawValue: candidate.kind.rawValue) else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }
            candidates.append(RunPlaySegmentWindowCandidate(
                kind: kind, startDistanceMeters: candidate.start,
                endDistanceMeters: candidate.end, selectionValue: candidate.value
            ))
        }
        return try validateCandidates(
            candidates, timeline: timeline, configuration: configuration,
            paceEvaluations: summary.paceEvaluationCount,
            elevationEvaluations: summary.elevationEvaluationCount
        )
    }

    static func engineConfiguration(_ configuration: SegmentDetectorSearchConfiguration) -> SegmentDetectionConfiguration {
        var engineConfig = SegmentDetectionConfiguration()
        engineConfig.fastest400m = .init(configuration.fastest400mDistanceMeters, configuration.fastest400mStepMeters)
        engineConfig.oneKilometer = .init(configuration.oneKilometerDistanceMeters, configuration.oneKilometerStepMeters)
        engineConfig.oneMile = .init(configuration.oneMileDistanceMeters, configuration.oneMileStepMeters)
        engineConfig.fiveKilometers = .init(configuration.fiveKilometerDistanceMeters, configuration.fiveKilometerStepMeters)
        engineConfig.tenKilometers = .init(configuration.tenKilometerDistanceMeters, configuration.tenKilometerStepMeters)
        engineConfig.halfMarathon = .init(configuration.halfMarathonDistanceMeters, configuration.halfMarathonStepMeters)
        engineConfig.marathon = .init(configuration.marathonDistanceMeters, configuration.marathonStepMeters)
        engineConfig.elevation = .init(configuration.elevationWindowDistanceMeters, configuration.elevationStepMeters)
        engineConfig.minimumPace = configuration.minimumValidPaceSecondsPerKilometer
        engineConfig.maximumPace = configuration.maximumValidPaceSecondsPerKilometer
        engineConfig.maximumEvaluations = configuration.maximumEvaluationsPerSearch
        engineConfig.elevationEnabled = configuration.elevationEnabled ? 1 : 0

        return engineConfig
    }

    @inline(__always)
    static func pack<Sample>(
        routePoints: [RoutePoint], timeline: WorkoutTimeline, elevationProfile: ElevationProfile,
        cancellationCheckStride: Int, isCancelled: @Sendable () -> Bool,
        makeSample: (Double, Double, Double, Double, Double, Double, Int32, Int32) -> Sample
    ) throws -> ContiguousArray<Sample> {
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

        // Build compact samples in the destination representation.
        var samples = ContiguousArray<Sample>()
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

            samples.append(makeSample(
                timelineSnapshot.distancesMeters[index],
                timelineSnapshot.elapsedSeconds[index],
                timelineSnapshot.activeSeconds[index],
                elevationSnapshot.cumulativeAscentMeters[index],
                elevationSnapshot.cumulativeDescentMeters[index],
                elevationSnapshot.reliableIntervalCounts[index],
                compactGroup,
                mappedRun
            ))
        }

        return samples
    }

    static func validateCandidates(
        _ candidates: [RunPlaySegmentWindowCandidate],
        timeline: WorkoutTimeline, configuration: SegmentDetectorSearchConfiguration,
        paceEvaluations: UInt64, elevationEvaluations: UInt64
    ) throws -> RunPlaySegmentWindowSearchResult {
        var seenKinds: Set<RunPlaySegmentWindowKind> = []
        for c in candidates {
            let kind = c.kind
            guard seenKinds.insert(kind).inserted else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

            let startDistance = c.startDistanceMeters
            let endDistance = c.endDistanceMeters
            let value = c.selectionValue

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
            case .fastest400m, .fastest1km, .slowest1km,
                    .fastestOneMile, .fastest5km, .fastest10km,
                    .fastestHalfMarathon, .fastestMarathon:
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
            case .fastestOneMile:
                expectedWindowDistance = configuration.oneMileDistanceMeters
            case .fastest5km:
                expectedWindowDistance = configuration.fiveKilometerDistanceMeters
            case .fastest10km:
                expectedWindowDistance = configuration.tenKilometerDistanceMeters
            case .fastestHalfMarathon:
                expectedWindowDistance = configuration.halfMarathonDistanceMeters
            case .fastestMarathon:
                expectedWindowDistance = configuration.marathonDistanceMeters
            case .biggestClimb, .biggestDescent:
                expectedWindowDistance = configuration.elevationWindowDistanceMeters
            }
            let expectedEndDistance = startDistance + expectedWindowDistance
            guard endDistance == expectedEndDistance else {
                throw RunPlaySegmentDetectorBridgeError.engineContractViolation
            }

        }

        // Verify deterministic order (kinds appear in expected emission order)
        let expectedOrder: [RunPlaySegmentWindowKind] = [
            .fastest400m, .fastest1km, .slowest1km, .biggestClimb, .biggestDescent,
            .fastestOneMile, .fastest5km, .fastest10km, .fastestHalfMarathon,
            .fastestMarathon
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

        // Each of the seven pace searches is individually capped by the
        // per-search budget, so the summed pace evaluation count is capped by
        // seven times that budget.
        let (maximumPaceEvaluations, paceLimitOverflow) =
            configuration.maximumEvaluationsPerSearch.multipliedReportingOverflow(
                by: SegmentDetection.paceSearchCount)
        guard !paceLimitOverflow,
              paceEvaluations <= maximumPaceEvaluations,
              elevationEvaluations
                <= configuration.maximumEvaluationsPerSearch,
              let paceEvalCount = Int(exactly: paceEvaluations),
              let elevEvalCount = Int(exactly: elevationEvaluations)
        else {
            throw RunPlaySegmentDetectorBridgeError.engineContractViolation
        }

        return RunPlaySegmentWindowSearchResult(
            candidates: candidates,
            paceEvaluationCount: paceEvalCount,
            elevationEvaluationCount: elevEvalCount
        )
    }

}

// Preserve the service call site and pre-removal architecture validator.
typealias RunPlaySegmentDetectorBridge = RunPlaySegmentDetectorAdapter
