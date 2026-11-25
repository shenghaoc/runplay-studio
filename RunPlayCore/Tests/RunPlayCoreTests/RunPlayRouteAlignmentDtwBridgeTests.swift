import XCTest
@testable import RunPlayCore

/// Behaviour coverage for the constrained-DTW path adapter. The golden digest
/// in `RouteAlignmentDtwGoldenTests` pins the full output over the generated
/// fixtures defined here.
final class RunPlayRouteAlignmentDtwBridgeTests: XCTestCase {

    // MARK: - Deterministic fixture generation

    /// SplitMix64. Fixed seed, no platform randomness, identical on every run.
    private struct DeterministicGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func nextBits() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func unit() -> Double {
            Double(nextBits() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        mutating func double(_ lower: Double, _ upper: Double) -> Double {
            lower + unit() * (upper - lower)
        }

        mutating func int(_ lower: Int, _ upper: Int) -> Int {
            let span = UInt64(upper - lower + 1)
            return lower + Int(nextBits() % span)
        }

        mutating func chance(_ probability: Double) -> Bool {
            unit() < probability
        }
    }

    struct Fixture {
        let name: String
        let primary: [RouteAlignmentSample]
        let comparison: [RouteAlignmentSample]
        let primaryRouteDistanceMeters: Double
        let comparisonRouteDistanceMeters: Double
        let effectiveSampleIntervalMeters: Double
        let policy: RouteAlignmentPolicy
    }

    private static func makeSamples(
        count: Int,
        distance: Double,
        startFraction: Double,
        offsetX: Double,
        offsetZ: Double,
        noise: Double,
        headingProbability: Double,
        generator: inout DeterministicGenerator
    ) -> [RouteAlignmentSample] {
        var result: [RouteAlignmentSample] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let t = count > 1 ? Double(index) / Double(count - 1) : 0
            let along = t * distance
            // A gently curving track so headings and separations actually vary.
            let curve = sin(t * 3.0) * 40.0
            let x = offsetX + (startFraction * distance * 0.6) + along * 0.6 + curve
                + (noise > 0 ? generator.double(-noise, noise) : 0)
            let z = offsetZ + (startFraction * distance * 0.8) + along * 0.8
                + (noise > 0 ? generator.double(-noise, noise) : 0)
            let heading: Double? = generator.chance(headingProbability)
                ? generator.double(-Double.pi, Double.pi)
                : nil
            result.append(RouteAlignmentSample(
                xMeters: x,
                zMeters: z,
                distanceFromStartMeters: along,
                routeSegmentIndex: 0,
                elapsedSeconds: nil,
                headingRadians: heading,
                normalizedProgress: t
            ))
        }
        return result
    }

    static func makeGeneratedFixtures(count: Int) -> [Fixture] {
        var generator = DeterministicGenerator(seed: 0x5250_4C41_5944_5457)
        var fixtures: [Fixture] = []
        fixtures.reserveCapacity(count)

        for index in 0..<count {
            let primaryCount = generator.int(4, 90)
            // Occasionally force a large count ratio so band edges get exercised.
            let comparisonCount = generator.chance(0.25)
                ? generator.int(4, 30)
                : max(4, primaryCount + generator.int(-12, 12))

            let primaryDistance = generator.double(200, 12_000)
            let lengthRatio = generator.double(0.55, 1.8)
            let comparisonDistance = max(1, primaryDistance * lengthRatio)

            let interval = generator.double(1, 60)
            let noise = generator.chance(0.7) ? generator.double(0, 55) : 0
            let headingProbability = generator.double(0, 1)
            let lateralOffset = generator.double(-160, 160)
            let startFraction = generator.chance(0.4) ? generator.double(0, 0.25) : 0

            let policy = RouteAlignmentPolicy(
                bandWidthFraction: generator.double(0.01, 0.6),
                maximumUnmatchedPrefixSuffixMeters: generator.double(0, 1_500),
                maximumUnmatchedPrefixSuffixFraction: generator.double(0, 0.5),
                nonDiagonalStepPenalty: generator.double(-0.2, 2.5),
                maximumConsecutiveWarpSteps: generator.chance(0.10) ? 0 : generator.int(1, 400),
                spatialDistanceCostScaleMeters: generator.double(0.1, 400),
                maximumSpatialCost: generator.double(0, 40),
                headingPenaltyWeight: generator.double(-1, 4),
                progressPenaltyWeight: generator.double(-1, 6),
                maximumBandCells: generator.chance(0.12)
                    ? generator.int(0, 4_000)
                    : 4_000_000
            )

            fixtures.append(Fixture(
                name: "generated#\(index)",
                primary: makeSamples(
                    count: primaryCount,
                    distance: primaryDistance,
                    startFraction: 0,
                    offsetX: 0,
                    offsetZ: 0,
                    noise: noise,
                    headingProbability: headingProbability,
                    generator: &generator
                ),
                comparison: makeSamples(
                    count: comparisonCount,
                    distance: comparisonDistance,
                    startFraction: startFraction,
                    offsetX: lateralOffset,
                    offsetZ: generator.double(-60, 60),
                    noise: noise,
                    headingProbability: headingProbability,
                    generator: &generator
                ),
                primaryRouteDistanceMeters: primaryDistance,
                comparisonRouteDistanceMeters: comparisonDistance,
                effectiveSampleIntervalMeters: interval,
                policy: policy
            ))
        }
        return fixtures
    }

    // MARK: - Solve helper

    private func solve(_ fixture: Fixture) throws -> RunPlayRouteAlignmentDtwResult {
        try RunPlayRouteAlignmentDtwAdapter.solve(
            primary: fixture.primary,
            comparison: fixture.comparison,
            primaryRouteDistanceMeters: fixture.primaryRouteDistanceMeters,
            comparisonRouteDistanceMeters: fixture.comparisonRouteDistanceMeters,
            effectiveSampleIntervalMeters: fixture.effectiveSampleIntervalMeters,
            policy: fixture.policy,
            isCancelled: { false }
        )
    }

    // MARK: - Generated coverage

    func testGeneratedFixturesReachEveryOutcome() throws {
        let fixtures = Self.makeGeneratedFixtures(count: 1_200)
        XCTAssertGreaterThanOrEqual(fixtures.count, 1_000)

        var successes = 0
        var resourceLimits = 0
        var noPaths = 0

        for fixture in fixtures {
            let result = try solve(fixture)
            switch result {
            case .success: successes += 1
            case .resourceLimit: resourceLimits += 1
            case .noPath: noPaths += 1
            }
        }

        // The generator must actually reach every outcome, otherwise the sweep
        // silently stops covering a category.
        XCTAssertGreaterThan(successes, 500, "generated successes")
        XCTAssertGreaterThan(resourceLimits, 0, "generated resource limits")
        XCTAssertGreaterThan(noPaths, 0, "generated no-path cases")
    }

    // MARK: - Outcome categories

    func testResourceLimitAndNoPathCategories() throws {
        var generator = DeterministicGenerator(seed: 17)
        let a = Self.makeSamples(
            count: 60, distance: 2_500, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )
        let b = Self.makeSamples(
            count: 90, distance: 2_500, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )

        let limited = try solve(Fixture(
            name: "resource-limit",
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 2_500,
            comparisonRouteDistanceMeters: 2_500,
            effectiveSampleIntervalMeters: 42,
            policy: RouteAlignmentPolicy(maximumBandCells: 8)
        ))
        XCTAssertEqual(limited, .resourceLimit)

        // Diagonal-only transitions cannot reach the open-suffix window when the
        // two routes have different sample counts.
        let blocked = try solve(Fixture(
            name: "no-path",
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 2_500,
            comparisonRouteDistanceMeters: 2_500,
            effectiveSampleIntervalMeters: 10_000,
            policy: RouteAlignmentPolicy(
                bandWidthFraction: 0.001,
                maximumUnmatchedPrefixSuffixMeters: 0,
                maximumUnmatchedPrefixSuffixFraction: 0,
                maximumConsecutiveWarpSteps: 0
            )
        ))
        XCTAssertEqual(blocked, .noPath)
    }

    // MARK: - Bridge-only contract behaviour

    func testEmptyRoutesAreAnInputContractViolation() {
        var generator = DeterministicGenerator(seed: 18)
        let samples = Self.makeSamples(
            count: 30, distance: 1_000, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )
        for (primary, comparison) in [([RouteAlignmentSample](), samples), (samples, [])] {
            XCTAssertThrowsError(
                try RunPlayRouteAlignmentDtwAdapter.solve(
                    primary: primary,
                    comparison: comparison,
                    primaryRouteDistanceMeters: 1_000,
                    comparisonRouteDistanceMeters: 1_000,
                    effectiveSampleIntervalMeters: 30,
                    policy: .default,
                    isCancelled: { false }
                )
            ) { error in
                XCTAssertEqual(
                    error as? RunPlayRouteAlignmentDtwBridgeError,
                    .invalidInputContract
                )
            }
        }
    }

    func testNonFiniteRouteMeasurementsAreAnInputContractViolation() {
        var generator = DeterministicGenerator(seed: 19)
        let samples = Self.makeSamples(
            count: 30, distance: 1_000, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )
        let cases: [(Double, Double, Double)] = [
            (.nan, 1_000, 30),
            (1_000, .infinity, 30),
            (1_000, 1_000, .nan),
            (0, 1_000, 30),
            (1_000, 0, 30),
            (1_000, 1_000, 0),
            (-5, 1_000, 30),
        ]
        for (primaryDistance, comparisonDistance, interval) in cases {
            XCTAssertThrowsError(
                try RunPlayRouteAlignmentDtwAdapter.solve(
                    primary: samples,
                    comparison: samples,
                    primaryRouteDistanceMeters: primaryDistance,
                    comparisonRouteDistanceMeters: comparisonDistance,
                    effectiveSampleIntervalMeters: interval,
                    policy: .default,
                    isCancelled: { false }
                )
            ) { error in
                XCTAssertEqual(
                    error as? RunPlayRouteAlignmentDtwBridgeError,
                    .invalidInputContract,
                    "distances=\(primaryDistance)/\(comparisonDistance) interval=\(interval)"
                )
            }
        }
    }

    func testNonFinitePolicyFieldsAreRejected() {
        var generator = DeterministicGenerator(seed: 20)
        let samples = Self.makeSamples(
            count: 30, distance: 1_000, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )
        let policies: [(String, RouteAlignmentPolicy)] = [
            ("bandWidthFraction", RouteAlignmentPolicy(bandWidthFraction: .nan)),
            ("unmatchedMeters", RouteAlignmentPolicy(maximumUnmatchedPrefixSuffixMeters: .infinity)),
            ("unmatchedFraction", RouteAlignmentPolicy(maximumUnmatchedPrefixSuffixFraction: .nan)),
            ("stepPenalty", RouteAlignmentPolicy(nonDiagonalStepPenalty: .infinity)),
            ("costScale", RouteAlignmentPolicy(spatialDistanceCostScaleMeters: .nan)),
            ("maximumSpatialCost", RouteAlignmentPolicy(maximumSpatialCost: .nan)),
            ("headingWeight", RouteAlignmentPolicy(headingPenaltyWeight: .infinity)),
            ("progressWeight", RouteAlignmentPolicy(progressPenaltyWeight: .nan)),
        ]
        for (name, policy) in policies {
            XCTAssertThrowsError(
                try RunPlayRouteAlignmentDtwAdapter.solve(
                    primary: samples,
                    comparison: samples,
                    primaryRouteDistanceMeters: 1_000,
                    comparisonRouteDistanceMeters: 1_000,
                    effectiveSampleIntervalMeters: 30,
                    policy: policy,
                    isCancelled: { false }
                ),
                name
            ) { error in
                XCTAssertEqual(
                    error as? RunPlayRouteAlignmentDtwBridgeError,
                    .invalidPolicy,
                    name
                )
            }
        }
    }

    func testNegativePolicyLimitsMapToZero() throws {
        var generator = DeterministicGenerator(seed: 21)
        let a = Self.makeSamples(
            count: 40, distance: 1_600, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 4, headingProbability: 0.5, generator: &generator
        )
        let b = Self.makeSamples(
            count: 55, distance: 1_600, startFraction: 0, offsetX: 5, offsetZ: 5,
            noise: 4, headingProbability: 0.5, generator: &generator
        )

        // A negative band-cell budget behaves exactly like zero: always limited.
        let negativeCells = try RunPlayRouteAlignmentDtwAdapter.solve(
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 1_600,
            comparisonRouteDistanceMeters: 1_600,
            effectiveSampleIntervalMeters: 40,
            policy: RouteAlignmentPolicy(maximumBandCells: -1),
            isCancelled: { false }
        )
        XCTAssertEqual(negativeCells, .resourceLimit)

        // A negative warp limit forbids every non-diagonal transition, matching
        // the Swift `run <= maximumConsecutiveWarpSteps` comparison for run >= 1.
        let negativeWarp = RouteAlignmentPolicy(maximumConsecutiveWarpSteps: -3)
        let zeroWarp = RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 0)
        let negativeResult = try RunPlayRouteAlignmentDtwAdapter.solve(
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 1_600,
            comparisonRouteDistanceMeters: 1_600,
            effectiveSampleIntervalMeters: 40,
            policy: negativeWarp,
            isCancelled: { false }
        )
        let zeroResult = try RunPlayRouteAlignmentDtwAdapter.solve(
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 1_600,
            comparisonRouteDistanceMeters: 1_600,
            effectiveSampleIntervalMeters: 40,
            policy: zeroWarp,
            isCancelled: { false }
        )
        XCTAssertEqual(negativeResult, zeroResult)
    }

    func testCancellationIsObservedAroundTheNativeCall() {
        var generator = DeterministicGenerator(seed: 22)
        let samples = Self.makeSamples(
            count: 60, distance: 2_400, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 0, headingProbability: 0, generator: &generator
        )
        XCTAssertThrowsError(
            try RunPlayRouteAlignmentDtwAdapter.solve(
                primary: samples,
                comparison: samples,
                primaryRouteDistanceMeters: 2_400,
                comparisonRouteDistanceMeters: 2_400,
                effectiveSampleIntervalMeters: 40,
                policy: .default,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testRepeatedSolvesAreDeterministic() throws {
        var generator = DeterministicGenerator(seed: 23)
        let a = Self.makeSamples(
            count: 75, distance: 3_100, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 9, headingProbability: 0.65, generator: &generator
        )
        let b = Self.makeSamples(
            count: 68, distance: 3_300, startFraction: 0.08, offsetX: 22, offsetZ: -18,
            noise: 9, headingProbability: 0.65, generator: &generator
        )
        var previous: RunPlayRouteAlignmentDtwResult?
        for _ in 0..<5 {
            let result = try RunPlayRouteAlignmentDtwAdapter.solve(
                primary: a, comparison: b,
                primaryRouteDistanceMeters: 3_100,
                comparisonRouteDistanceMeters: 3_300,
                effectiveSampleIntervalMeters: 46,
                policy: .default,
                isCancelled: { false }
            )
            if let previous {
                XCTAssertEqual(result, previous)
            }
            previous = result
        }
    }

    func testSolvedPathIsMonotoneAndInRange() throws {
        var generator = DeterministicGenerator(seed: 25)
        let a = Self.makeSamples(
            count: 85, distance: 3_600, startFraction: 0, offsetX: 0, offsetZ: 0,
            noise: 7, headingProbability: 0.7, generator: &generator
        )
        let b = Self.makeSamples(
            count: 72, distance: 3_400, startFraction: 0.05, offsetX: 18, offsetZ: 12,
            noise: 7, headingProbability: 0.7, generator: &generator
        )
        let result = try RunPlayRouteAlignmentDtwAdapter.solve(
            primary: a, comparison: b,
            primaryRouteDistanceMeters: 3_600,
            comparisonRouteDistanceMeters: 3_400,
            effectiveSampleIntervalMeters: 45,
            policy: .default,
            isCancelled: { false }
        )
        guard case .success(let path, _, _, _) = result else {
            return XCTFail("expected a solved path, got \(result)")
        }
        XCTAssertFalse(path.isEmpty)
        XCTAssertLessThanOrEqual(path.count, a.count + b.count + 1)
        for cell in path {
            XCTAssertTrue((0..<a.count).contains(cell.primaryIndex))
            XCTAssertTrue((0..<b.count).contains(cell.comparisonIndex))
        }
        for index in 1..<path.count {
            let previous = path[index - 1]
            let current = path[index]
            let primaryDelta = current.primaryIndex - previous.primaryIndex
            let comparisonDelta = current.comparisonIndex - previous.comparisonIndex
            switch current.step {
            case .diagonal:
                XCTAssertEqual(primaryDelta, 1)
                XCTAssertEqual(comparisonDelta, 1)
            case .primaryOnly:
                XCTAssertEqual(primaryDelta, 1)
                XCTAssertEqual(comparisonDelta, 0)
            case .comparisonOnly:
                XCTAssertEqual(primaryDelta, 0)
                XCTAssertEqual(comparisonDelta, 1)
            }
        }
    }
}
