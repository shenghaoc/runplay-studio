import XCTest
@testable import RunPlayCore

/// Compatibility cases compare the pre-migration Swift oracle, the native
/// bridge, and — where a complete profile is representable —
/// `RouteMetricProfileBuilder` production output.
final class RouteMetricScaleBucketCompatibilityTests: XCTestCase {
    typealias Oracle = SwiftRouteMetricScaleBucketOracle

    private let builder = RouteMetricProfileBuilder()

    func testOriginMainNumericEdgeMatrix() throws {
        try assertParity(
            metrics: [],
            weights: [],
            scale: nil,
            assignments: [],
            validCount: 0,
            noDataCount: 0,
            coverage: 0
        )
        try assertParity(
            metrics: [7],
            weights: [1],
            scale: .init(lowerBound: 7, median: 7, upperBound: 7),
            assignments: [.init(normalizedValue: 0.5, bucketIndex: 3)],
            validCount: 1,
            noDataCount: 0,
            coverage: 1
        )
        try assertParity(
            metrics: [nil, nil],
            weights: [1, 2],
            scale: nil,
            assignments: [
                .init(normalizedValue: nil, bucketIndex: nil),
                .init(normalizedValue: nil, bucketIndex: nil)
            ],
            validCount: 0,
            noDataCount: 2,
            coverage: 0
        )
        try assertParity(
            metrics: [5, 10],
            weights: [0, 2],
            scale: .init(lowerBound: 10, median: 10, upperBound: 10),
            assignments: [
                .init(normalizedValue: 0.5, bucketIndex: 3),
                .init(normalizedValue: 0.5, bucketIndex: 3)
            ],
            validCount: 1,
            noDataCount: 0,
            coverage: 2
        )
        try assertParity(
            metrics: [4, 4, 4],
            weights: [1, 2, 3],
            scale: .init(lowerBound: 4, median: 4, upperBound: 4),
            assignments: Array(
                repeating: .init(normalizedValue: 0.5, bucketIndex: 3),
                count: 3
            ),
            validCount: 3,
            noDataCount: 0,
            coverage: 6
        )
    }

    func testOriginMainPolicyEdges() throws {
        let metrics: [Double?] = [1, 2, 3]
        let weights = [1.0, 2.0, 1.0]

        try assertParity(
            metrics: metrics,
            weights: weights,
            lower: 0,
            upper: 1,
            expectedScale: .init(lowerBound: 1, median: 2, upperBound: 3)
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            lower: -10,
            upper: 10,
            expectedScale: .init(lowerBound: 1, median: 2, upperBound: 3)
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            lower: .nan,
            upper: 1,
            expectedScale: nil
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            lower: 0,
            upper: .infinity,
            expectedScale: nil
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            lower: 0.5,
            upper: 0.5,
            expectedScale: .init(lowerBound: 2, median: 2, upperBound: 2)
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            minimumSpan: .nan,
            expectedScale: .init(lowerBound: 1, median: 2, upperBound: 3)
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            minimumSpan: -.infinity,
            expectedScale: .init(lowerBound: 1, median: 2, upperBound: 3)
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            minimumSpan: .infinity,
            expectedScale: nil
        )
        try assertParity(
            metrics: metrics,
            weights: weights,
            minimumValid: 4,
            expectedScale: nil
        )

        let twoBuckets = try bridge(metrics: metrics, weights: weights, bucketCount: 2)
        let twoOracle = oracle(metrics: metrics, weights: weights, bucketCount: 2)
        XCTAssertEqual(twoBuckets.assignments.map(\.bucketIndex), [0, 1, 1])
        XCTAssertEqual(
            twoBuckets.assignments.map(\.bucketIndex),
            twoOracle.assignments.map(\.bucketIndex)
        )

        let nineBuckets = try bridge(metrics: metrics, weights: weights, bucketCount: 9)
        let nineOracle = oracle(metrics: metrics, weights: weights, bucketCount: 9)
        XCTAssertEqual(nineBuckets.assignments.map(\.bucketIndex), [0, 4, 8])
        XCTAssertEqual(
            nineBuckets.assignments.map(\.bucketIndex),
            nineOracle.assignments.map(\.bucketIndex)
        )
    }

    func testBucketCountAboveInt32MaxAndIntMax() throws {
        let metrics: [Double?] = [0, 1]
        let weights = [1.0, 1.0]
        let aboveInt32 = Int(Int32.max) + 1

        let aboveNative = try bridge(metrics: metrics, weights: weights, bucketCount: aboveInt32)
        let aboveOracle = oracle(metrics: metrics, weights: weights, bucketCount: aboveInt32)
        assertEqual(native: aboveNative, oracle: aboveOracle, label: "Int32.max+1")
        XCTAssertEqual(aboveNative.assignments[0].bucketIndex, 0)
        XCTAssertEqual(aboveNative.assignments[1].bucketIndex, aboveInt32 - 1)

        let maxNative = try bridge(metrics: metrics, weights: weights, bucketCount: Int.max)
        let maxOracle = oracle(metrics: metrics, weights: weights, bucketCount: Int.max)
        assertEqual(native: maxNative, oracle: maxOracle, label: "Int.max")
        XCTAssertEqual(maxNative.assignments[0].bucketIndex, 0)
        XCTAssertEqual(maxNative.assignments[1].bucketIndex, Int.max - 1)

        // Public policy still accepts Int.max without narrowing.
        let policy = RouteMetricColorPolicy(bucketCount: Int.max)
        XCTAssertEqual(policy.bucketCount, Int.max)
    }

    func testOriginMainLargeWeightsAndNonFinitePresentValues() throws {
        let huge = Double.greatestFiniteMagnitude
        let largeNative = try bridge(metrics: [1, 2, 3], weights: [huge, huge, huge])
        let largeOracle = oracle(metrics: [1, 2, 3], weights: [huge, huge, huge])
        assertEqual(native: largeNative, oracle: largeOracle, label: "finite weight overflow")
        XCTAssertEqual(largeNative.scale, .init(lowerBound: 1, median: 2, upperBound: 3))
        XCTAssertTrue(largeNative.validCoverageDistanceMeters.isInfinite)
        XCTAssertEqual(largeNative.validIntervalCount, 3)

        let nonFiniteNative = try bridge(
            metrics: [1, .nan, .infinity, 3],
            weights: [1, 0, 0, 1]
        )
        let nonFiniteOracle = oracle(
            metrics: [1, .nan, .infinity, 3],
            weights: [1, 0, 0, 1]
        )
        assertEqual(native: nonFiniteNative, oracle: nonFiniteOracle, label: "non-finite present")
        XCTAssertEqual(nonFiniteNative.scale, .init(lowerBound: 1, median: 1, upperBound: 3))
        XCTAssertEqual(
            nonFiniteNative.assignments[1],
            .init(normalizedValue: 0.5, bucketIndex: 3)
        )
        XCTAssertEqual(
            nonFiniteNative.assignments[2],
            .init(normalizedValue: 0.5, bucketIndex: 3)
        )
        XCTAssertEqual(nonFiniteNative.validIntervalCount, 2)
        XCTAssertEqual(nonFiniteNative.noDataIntervalCount, 0)
    }

    func testPositiveInfiniteIndividualWeight() throws {
        let onlyInfNative = try bridge(metrics: [7], weights: [.infinity])
        let onlyInfOracle = oracle(metrics: [7], weights: [.infinity])
        assertEqual(native: onlyInfNative, oracle: onlyInfOracle, label: "only +inf weight")
        XCTAssertNil(onlyInfNative.scale)
        XCTAssertEqual(onlyInfNative.validIntervalCount, 1)
        XCTAssertTrue(onlyInfNative.validCoverageDistanceMeters.isInfinite)
        XCTAssertEqual(onlyInfNative.noDataIntervalCount, 1)

        let mixedNative = try bridge(
            metrics: [1, 2, 3],
            weights: [.infinity, 1, 1]
        )
        let mixedOracle = oracle(
            metrics: [1, 2, 3],
            weights: [.infinity, 1, 1]
        )
        assertEqual(native: mixedNative, oracle: mixedOracle, label: "mixed +inf weight")
        XCTAssertEqual(mixedNative.scale, .init(lowerBound: 2, median: 2, upperBound: 3))
        XCTAssertEqual(mixedNative.validIntervalCount, 3)
        XCTAssertTrue(mixedNative.validCoverageDistanceMeters.isInfinite)
        XCTAssertEqual(mixedNative.assignments[0].bucketIndex, 0)
    }

    func testNegativeInfinityAndNaNWeightRejected() {
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [-.infinity])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
        XCTAssertThrowsError(try bridge(metrics: [1], weights: [.nan])) {
            XCTAssertEqual($0 as? RunPlayRouteMetricScaleBucketBridgeError, .invalidInputContract)
        }
    }

    func testPositiveInfinityAndNegativeZeroWeightBitPatterns() throws {
        let mixed = try bridge(
            metrics: [1, 2, 3],
            weights: [.infinity, -0.0, 1.0]
        )
        let mixedOracle = oracle(
            metrics: [1, 2, 3],
            weights: [.infinity, -0.0, 1.0]
        )
        assertEqual(native: mixed, oracle: mixedOracle, label: "+inf and -0")
        XCTAssertEqual(mixed.validIntervalCount, 2)
        XCTAssertTrue(mixed.validCoverageDistanceMeters.isInfinite)
        XCTAssertEqual(mixed.scale, .init(lowerBound: 3, median: 3, upperBound: 3))

        let negZero = try bridge(metrics: [4], weights: [-0.0])
        let negZeroOracle = oracle(metrics: [4], weights: [-0.0])
        assertEqual(native: negZero, oracle: negZeroOracle, label: "only -0")
        XCTAssertNil(negZero.scale)
        XCTAssertEqual(negZero.validIntervalCount, 0)
    }

    func testCompleteProfileHeartRateWithOverflowingIntervalDistance() throws {
        // Heart-rate mode keeps a finite metric available even when an interval
        // distance is extreme. Weights come from max(0, end - start); with
        // cumulative distances 0 and greatestFiniteMagnitude the single
        // interval weight is finite-huge. Three such independent bridge-level
        // weights still prove coverage-sum overflow; the complete profile
        // proves the production path accepts the resulting coverage.
        let huge = Double.greatestFiniteMagnitude
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Bridge: three greatestFiniteMagnitude weights → coverage +infinity.
        let bridgeResult = try bridge(
            metrics: [140, 145, 150],
            weights: [huge, huge, huge]
        )
        let bridgeOracle = oracle(
            metrics: [140, 145, 150],
            weights: [huge, huge, huge]
        )
        assertEqual(native: bridgeResult, oracle: bridgeOracle, label: "HR overflow bridge")
        XCTAssertTrue(bridgeResult.validCoverageDistanceMeters.isInfinite)
        XCTAssertEqual(bridgeResult.validIntervalCount, 3)
        XCTAssertNotNil(bridgeResult.scale)

        // Public coverage-fraction calculation clamps +infinity to 1.
        let fraction = min(1, max(0, bridgeResult.validCoverageDistanceMeters / max(huge, 1)))
        XCTAssertEqual(fraction, 1)

        // Complete production profile with a huge finite interval weight and
        // heart-rate metrics. Smoothing disabled so values stay local.
        let points: [RoutePoint] = [
            RoutePoint(
                timestamp: start,
                latitude: 37.77,
                longitude: -122.42,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                heartRateBPM: 140,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(30),
                latitude: 37.7701,
                longitude: -122.42,
                distanceFromStartMeters: huge,
                elapsedSeconds: 30,
                heartRateBPM: 160,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(60),
                latitude: 37.7702,
                longitude: -122.42,
                distanceFromStartMeters: huge, // zero-length second interval
                elapsedSeconds: 60,
                heartRateBPM: 150,
                routeSegmentIndex: 0
            )
        ]
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(
            workout: workout,
            context: context,
            mode: .heartRate,
            policy: RouteMetricColorPolicy(
                heartRateSmoothingHalfWindowMeters: 0,
                lowerQuantile: 0,
                upperQuantile: 1
            )
        )

        XCTAssertEqual(profile.mode, .heartRate)
        XCTAssertGreaterThan(profile.validCoverageDistanceMeters, 0)
        // totalRouteDistance is huge; coverage is huge; fraction clamps to 1.
        XCTAssertEqual(profile.validCoverageFraction, 1, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(profile.diagnostics.validIntervalCount, 1)

        // Recompute oracle from the production intervals to confirm parity.
        let values = profile.intervals.map(\.metricValue)
        let weights = profile.intervals.map {
            max(0, $0.endDistanceMeters - $0.startDistanceMeters)
        }
        let fromProfile = try bridge(
            metrics: values,
            weights: weights,
            lower: 0,
            upper: 1
        )
        let oracleFromProfile = oracle(
            metrics: values,
            weights: weights,
            lower: 0,
            upper: 1
        )
        assertEqual(
            native: fromProfile,
            oracle: oracleFromProfile,
            label: "profile interval recompute"
        )
        XCTAssertEqual(profile.validCoverageDistanceMeters, fromProfile.validCoverageDistanceMeters)
        XCTAssertEqual(profile.diagnostics.validIntervalCount, fromProfile.validIntervalCount)
        XCTAssertEqual(profile.diagnostics.noDataIntervalCount, fromProfile.noDataIntervalCount)
    }

    // MARK: - Helpers

    private func assertParity(
        metrics: [Double?],
        weights: [Double],
        scale: Oracle.Scale?,
        assignments: [Oracle.Assignment],
        validCount: Int,
        noDataCount: Int,
        coverage: Double,
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7
    ) throws {
        let expected = Oracle.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: lower,
            upperQuantile: upper,
            minimumScaleSpan: minimumSpan,
            minimumValidIntervalCount: minimumValid,
            bucketCount: bucketCount
        )
        XCTAssertEqual(expected.scale, scale)
        XCTAssertEqual(expected.assignments, assignments)
        XCTAssertEqual(expected.validIntervalCount, validCount)
        XCTAssertEqual(expected.noDataIntervalCount, noDataCount)
        XCTAssertEqual(expected.validCoverageDistanceMeters, coverage)

        let native = try bridge(
            metrics: metrics,
            weights: weights,
            lower: lower,
            upper: upper,
            minimumSpan: minimumSpan,
            minimumValid: minimumValid,
            bucketCount: bucketCount
        )
        assertEqual(native: native, oracle: expected, label: "matrix")
    }

    private func assertParity(
        metrics: [Double?],
        weights: [Double],
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7,
        expectedScale: Oracle.Scale?
    ) throws {
        let expected = oracle(
            metrics: metrics,
            weights: weights,
            lower: lower,
            upper: upper,
            minimumSpan: minimumSpan,
            minimumValid: minimumValid,
            bucketCount: bucketCount
        )
        XCTAssertEqual(expected.scale, expectedScale)
        let native = try bridge(
            metrics: metrics,
            weights: weights,
            lower: lower,
            upper: upper,
            minimumSpan: minimumSpan,
            minimumValid: minimumValid,
            bucketCount: bucketCount
        )
        assertEqual(native: native, oracle: expected, label: "policy")
    }

    private func assertEqual(
        native: RunPlayRouteMetricScaleBucketResult,
        oracle: Oracle.Result,
        label: String
    ) {
        XCTAssertEqual(native.scale?.lowerBound, oracle.scale?.lowerBound, "\(label) lower")
        XCTAssertEqual(native.scale?.median, oracle.scale?.median, "\(label) median")
        XCTAssertEqual(native.scale?.upperBound, oracle.scale?.upperBound, "\(label) upper")
        XCTAssertEqual(native.assignments.count, oracle.assignments.count, "\(label) count")
        for index in native.assignments.indices {
            XCTAssertEqual(
                native.assignments[index].normalizedValue,
                oracle.assignments[index].normalizedValue,
                "\(label) normalized[\(index)]"
            )
            XCTAssertEqual(
                native.assignments[index].bucketIndex,
                oracle.assignments[index].bucketIndex,
                "\(label) bucket[\(index)]"
            )
        }
        if oracle.validCoverageDistanceMeters.isInfinite {
            XCTAssertTrue(
                native.validCoverageDistanceMeters.isInfinite
                    && native.validCoverageDistanceMeters > 0,
                "\(label) coverage +inf"
            )
        } else {
            XCTAssertEqual(
                native.validCoverageDistanceMeters,
                oracle.validCoverageDistanceMeters,
                "\(label) coverage"
            )
        }
        XCTAssertEqual(native.validIntervalCount, oracle.validIntervalCount, "\(label) valid")
        XCTAssertEqual(native.noDataIntervalCount, oracle.noDataIntervalCount, "\(label) no-data")
    }

    private func oracle(
        metrics: [Double?],
        weights: [Double],
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7
    ) -> Oracle.Result {
        Oracle.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: lower,
            upperQuantile: upper,
            minimumScaleSpan: minimumSpan,
            minimumValidIntervalCount: minimumValid,
            bucketCount: bucketCount
        )
    }

    private func bridge(
        metrics: [Double?],
        weights: [Double],
        lower: Double = 0,
        upper: Double = 1,
        minimumSpan: Double = 0,
        minimumValid: Int = 1,
        bucketCount: Int = 7
    ) throws -> RunPlayRouteMetricScaleBucketResult {
        try RunPlayRouteMetricScaleBucketBridge.assign(
            metricValues: metrics,
            weightsMeters: weights,
            lowerQuantile: lower,
            upperQuantile: upper,
            minimumScaleSpan: minimumSpan,
            minimumValidIntervalCount: minimumValid,
            bucketCount: bucketCount,
            cancellationCheckStride: 512,
            isCancelled: { false }
        )
    }
}
