import XCTest
@testable import RunPlayCore

final class DynamicTimeWarpingRouteAlignerTests: XCTestCase {
    private let aligner = ConstrainedDynamicTimeWarpingAligner()
    private let policy = RouteAlignmentPolicy.default

    /// Complete pre-migration aligner, used only by the snapshot-parity tests.
    private let preMigrationOracle = PreMigrationRouteAlignerOracle()

    func testIdenticalRoutesProduceAvailableHighQualityAlignment() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 25)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout),
            policy: policy
        )
        guard case .available(let quality) = snapshot.availability else {
            return XCTFail("Expected available, got \(snapshot.availability)")
        }
        XCTAssertTrue([RouteAlignmentQuality.excellent, .good].contains(quality))
        XCTAssertGreaterThan(snapshot.totalAlignedDistanceMeters, 2_000)
        XCTAssertFalse(snapshot.blocks.isEmpty)
        assertMonotonic(snapshot)
        assertFiniteDiagnostics(snapshot.diagnostics)
    }

    func testDifferentSampleRatesStillAlign() throws {
        let dense = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 10)
        let sparse = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 40)
        let snapshot = try aligner.align(
            primary: dense,
            comparison: sparse,
            primaryContext: WorkoutAnalysisContext(workout: dense),
            comparisonContext: WorkoutAnalysisContext(workout: sparse),
            policy: policy
        )
        XCTAssertTrue(snapshot.availability.isAvailable)
        assertMonotonic(snapshot)
    }

    func testSmallGPSNoiseRemainsAvailable() throws {
        let clean = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let noisy = makeNoisyWorkout(from: clean, noiseMeters: 4)
        let snapshot = try aligner.align(
            primary: clean,
            comparison: noisy,
            primaryContext: WorkoutAnalysisContext(workout: clean),
            comparisonContext: WorkoutAnalysisContext(workout: noisy),
            policy: policy
        )
        XCTAssertTrue(
            snapshot.availability.isAvailable,
            "availability=\(snapshot.availability) median=\(snapshot.diagnostics.medianSpatialSeparationMeters) p90=\(snapshot.diagnostics.p90SpatialSeparationMeters)"
        )
        XCTAssertLessThan(snapshot.diagnostics.medianSpatialSeparationMeters, 40)
    }

    func testModestPrefixOffsetStillAligns() throws {
        // Comparison starts ~80 m further along the same line (shared geography,
        // different start). Route-Aware should still produce an available mapping.
        let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let offset = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20, startOffsetMeters: 80)
        let snapshot = try aligner.align(
            primary: base,
            comparison: offset,
            primaryContext: WorkoutAnalysisContext(workout: base),
            comparisonContext: WorkoutAnalysisContext(workout: offset),
            policy: policy
        )
        XCTAssertTrue(
            snapshot.availability.isAvailable,
            "availability=\(snapshot.availability) coverage=\(snapshot.diagnostics.primaryCoverageFraction)/\(snapshot.diagnostics.comparisonCoverageFraction)"
        )
        XCTAssertGreaterThan(snapshot.totalAlignedDistanceMeters, 2_000)
    }

    func testOppositeDirectionIsUnavailable() throws {
        let forward = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20)
        let reverse = reverseWorkout(forward)
        let snapshot = try aligner.align(
            primary: forward,
            comparison: reverse,
            primaryContext: WorkoutAnalysisContext(workout: forward),
            comparisonContext: WorkoutAnalysisContext(workout: reverse),
            policy: policy
        )
        guard case .unavailable(let reason) = snapshot.availability else {
            return XCTFail("Expected unavailable for opposite direction")
        }
        XCTAssertEqual(reason, .oppositeDirection)
        XCTAssertEqual(snapshot.diagnostics.detectedDirection, .opposite)
    }

    func testUnrelatedRoutesAreUnavailable() throws {
        let a = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 37.77, lon: -122.42)
        let b = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 40.71, lon: -74.00)
        let snapshot = try aligner.align(
            primary: a,
            comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        XCTAssertFalse(snapshot.availability.isAvailable)
    }

    func testRecordingGapProducesSeparateBlocks() throws {
        let gapped = makeGappedWorkout(segmentDistances: [1_500, 1_500])
        let continuous = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let snapshot = try aligner.align(
            primary: continuous,
            comparison: gapped,
            primaryContext: WorkoutAnalysisContext(workout: continuous),
            comparisonContext: WorkoutAnalysisContext(workout: gapped),
            policy: policy
        )
        if snapshot.availability.isAvailable {
            // Gap handling: either multiple blocks or still available with diagnostics.
            XCTAssertGreaterThanOrEqual(snapshot.diagnostics.matchedBlockCount, 1)
            for block in snapshot.blocks {
                let segmentsP = Set(block.anchors.map(\.primarySegmentIndex))
                // Within a block, primary segment may be continuous; comparison may split.
                XCTAssertFalse(block.anchors.isEmpty)
                _ = segmentsP
            }
            // Mapping must not interpolate across blocks.
            if snapshot.blocks.count >= 2 {
                let end0 = snapshot.blocks[0].alignedEndMeters
                let start1 = snapshot.blocks[1].alignedStartMeters
                XCTAssertGreaterThanOrEqual(start1, end0)
                if let mid = snapshot.positions(atAlignedProgress: (end0 + start1) / 2) {
                    // Position resolves to a block boundary, not a bridged interior.
                    XCTAssertTrue(
                        abs(mid.alignedProgressMeters - end0) < 1e-6
                            || abs(mid.alignedProgressMeters - start1) < 1e-6
                            || snapshot.blocks.contains { mid.alignedProgressMeters >= $0.alignedStartMeters
                                && mid.alignedProgressMeters <= $0.alignedEndMeters }
                    )
                }
            }
        }
    }

    func testDeterministicOutput() throws {
        let a = makeLinearWorkout(distanceMeters: 2_200, stepMeters: 20)
        let b = makeNoisyWorkout(from: a, noiseMeters: 5)
        let first = try aligner.align(
            primary: a, comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        let second = try aligner.align(
            primary: a, comparison: b,
            primaryContext: WorkoutAnalysisContext(workout: a),
            comparisonContext: WorkoutAnalysisContext(workout: b),
            policy: policy
        )
        XCTAssertEqual(first.totalAlignedDistanceMeters, second.totalAlignedDistanceMeters, accuracy: 1e-9)
        XCTAssertEqual(first.blocks.count, second.blocks.count)
        XCTAssertEqual(first.diagnostics.primarySampleCount, second.diagnostics.primarySampleCount)
    }

    func testCancellationDoesNotPublishAvailableResult() throws {
        let workout = makeLinearWorkout(distanceMeters: 5_000, stepMeters: 10)
        let snapshot = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: WorkoutAnalysisContext(workout: workout),
            comparisonContext: WorkoutAnalysisContext(workout: workout),
            policy: policy,
            isCancelled: { true }
        )
        guard case .unavailable(let reason) = snapshot.availability else {
            return XCTFail("Expected cancelled unavailability")
        }
        XCTAssertEqual(reason, .cancelled)
    }

    func testDenseRawPointsStayWithinSampleBudget() throws {
        // Simulate dense GPS (~1 m) over 4 km without exploding samples.
        let dense = makeLinearWorkout(distanceMeters: 4_000, stepMeters: 1)
        XCTAssertGreaterThan(dense.routePoints.count, 3_000)
        let snapshot = try aligner.align(
            primary: dense,
            comparison: dense,
            primaryContext: WorkoutAnalysisContext(workout: dense),
            comparisonContext: WorkoutAnalysisContext(workout: dense),
            policy: policy
        )
        XCTAssertLessThanOrEqual(snapshot.diagnostics.primarySampleCount, policy.maximumSamplesPerRoute)
        XCTAssertTrue(snapshot.availability.isAvailable || snapshot.availability.unavailableReason != nil)
    }

    // MARK: - End-to-end pre-migration snapshot parity
    //
    // These compare the migrated production aligner against
    // `PreMigrationRouteAlignerOracle`, a transcription of the complete
    // pre-migration Swift aligner whose dynamic-programming solve is delegated
    // to `SwiftConstrainedDtwPathOracle`. Every fixture is deterministic: fixed
    // geometry or seeded SplitMix64 noise, never wall-clock or system
    // randomness.

    func testSnapshotParityForIdenticalRoutes() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 25)
        let snapshot = try assertSnapshotParity(
            "identical",
            primary: workout,
            comparison: workout
        )
        XCTAssertTrue(snapshot.availability.isAvailable)
        XCTAssertFalse(snapshot.blocks.isEmpty)
    }

    func testSnapshotParityForDenseAndSparseSampleRates() throws {
        let dense = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 10)
        let sparse = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 40)
        let forward = try assertSnapshotParity("dense-vs-sparse", primary: dense, comparison: sparse)
        XCTAssertTrue(forward.availability.isAvailable)
        try assertSnapshotParity("sparse-vs-dense", primary: sparse, comparison: dense)
    }

    func testSnapshotParityForGPSNoise() throws {
        let clean = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let alternating = makeNoisyWorkout(from: clean, noiseMeters: 4)
        let noisy = try assertSnapshotParity("alternating-noise", primary: clean, comparison: alternating)
        XCTAssertTrue(noisy.availability.isAvailable)

        for (seed, amplitude) in [(UInt64(1), 3.0), (UInt64(2), 12.0), (UInt64(3), 45.0)] {
            try assertSnapshotParity(
                "seeded-noise-\(seed)",
                primary: clean,
                comparison: makeSeededNoisyWorkout(from: clean, noiseMeters: amplitude, seed: seed)
            )
        }
    }

    func testSnapshotParityForModestPrefixOffset() throws {
        for offset in [40.0, 80.0, 250.0] {
            let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
            let shifted = makeLinearWorkout(
                distanceMeters: 3_000,
                stepMeters: 20,
                startOffsetMeters: offset
            )
            try assertSnapshotParity("prefix-offset-\(offset)", primary: base, comparison: shifted)
        }
    }

    func testSnapshotParityForOppositeDirection() throws {
        let forward = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20)
        let reverse = reverseWorkout(forward)
        let snapshot = try assertSnapshotParity("opposite", primary: forward, comparison: reverse)
        XCTAssertEqual(snapshot.availability.unavailableReason, .oppositeDirection)
        XCTAssertEqual(snapshot.diagnostics.detectedDirection, .opposite)
    }

    func testSnapshotParityForUnrelatedRoutes() throws {
        // Far enough apart that the shared local projection is rejected.
        let west = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 37.77, lon: -122.42)
        let east = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 40.71, lon: -74.00)
        let continental = try assertSnapshotParity("continental", primary: west, comparison: east)
        XCTAssertEqual(continental.availability.unavailableReason, .unsupportedGeographicExtent)

        // Same city, parallel streets: rejected by separation, not by extent.
        for offset in [200.0, 1_000.0, 5_000.0] {
            let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
            let parallel = makeParallelWorkout(
                distanceMeters: 3_000,
                stepMeters: 20,
                lateralOffsetMeters: offset
            )
            let snapshot = try assertSnapshotParity("parallel-\(offset)", primary: base, comparison: parallel)
            XCTAssertEqual(snapshot.availability.unavailableReason, .routesTooFarApart)
        }
    }

    func testSnapshotParityForRecordingGapsProducingMultipleBlocks() throws {
        let twoSegments = makeGappedWorkout(segmentDistances: [1_500, 1_500])
        let paired = try assertSnapshotParity(
            "gapped-vs-gapped",
            primary: twoSegments,
            comparison: twoSegments
        )
        XCTAssertEqual(paired.blocks.count, 2)
        XCTAssertEqual(paired.diagnostics.matchedBlockCount, 2)

        let continuous = makeLinearWorkout(distanceMeters: 3_050, stepMeters: 20)
        let mixed = try assertSnapshotParity(
            "gapped-vs-continuous",
            primary: continuous,
            comparison: twoSegments
        )
        XCTAssertGreaterThanOrEqual(mixed.blocks.count, 2)

        let threeSegments = makeGappedWorkout(
            segmentDistances: [1_200, 900, 1_100],
            gapMeters: 120
        )
        let triple = try assertSnapshotParity(
            "three-segments",
            primary: threeSegments,
            comparison: threeSegments
        )
        XCTAssertEqual(triple.blocks.count, 3)
    }

    func testSnapshotParityForAmbiguousDirection() throws {
        let loop = makeSquareLoopWorkout(sideMeters: 500, stepMeters: 20, startFraction: 0)

        // Default policy: ambiguous geometry that never becomes available.
        for rotation in [0.25, 0.75] {
            let rotated = makeSquareLoopWorkout(
                sideMeters: 500,
                stepMeters: 20,
                startFraction: rotation
            )
            let snapshot = try assertSnapshotParity(
                "ambiguous-loop-\(rotation)",
                primary: loop,
                comparison: rotated
            )
            XCTAssertEqual(snapshot.diagnostics.detectedDirection, .ambiguous)
            XCTAssertFalse(snapshot.availability.isAvailable)
        }

        // Permissive policy: ambiguous geometry that survives classification and
        // therefore carries the ambiguity warning.
        let permissive = RouteAlignmentPolicy(
            bandWidthFraction: 0.5,
            maximumUnmatchedPrefixSuffixMeters: 2_000,
            maximumUnmatchedPrefixSuffixFraction: 0.5,
            maximumConsecutiveWarpSteps: 400,
            minimumCoverageFraction: 0.4,
            goodMedianSeparationMeters: 800,
            acceptableMedianSeparationMeters: 1_000,
            goodP90SeparationMeters: 4_000,
            maximumAcceptedP90SeparationMeters: 5_000,
            goodCoverageFraction: 0.4,
            maximumAcceptedWarpFraction: 0.95
        )
        for rotation in [0.2, 0.25, 0.75] {
            let rotated = makeSquareLoopWorkout(
                sideMeters: 500,
                stepMeters: 20,
                startFraction: rotation
            )
            let snapshot = try assertSnapshotParity(
                "ambiguous-available-loop-\(rotation)",
                primary: loop,
                comparison: rotated,
                policy: permissive
            )
            XCTAssertEqual(snapshot.diagnostics.detectedDirection, .ambiguous)
            XCTAssertTrue(snapshot.availability.isAvailable)
            XCTAssertEqual(
                snapshot.diagnostics.warnings,
                ["Route geometry is somewhat ambiguous; treat local deltas cautiously."]
            )
        }
    }

    func testSnapshotParityForResourceLimits() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)

        // Tiny budget: the sample builder refuses before any solve.
        for cells in [0, 8, 64, 512] {
            let snapshot = try assertSnapshotParity(
                "builder-band-cells-\(cells)",
                primary: workout,
                comparison: workout,
                policy: RouteAlignmentPolicy(maximumBandCells: cells)
            )
            XCTAssertEqual(snapshot.availability.unavailableReason, .resourceLimit)
            XCTAssertEqual(snapshot.diagnostics.primarySampleCount, 0)
        }

        // Budget tuned so the builder estimate passes and the wide open-ended
        // band inside the solve is what exceeds it.
        let solverLimited = try assertSnapshotParity(
            "solver-band-cells",
            primary: workout,
            comparison: workout,
            policy: RouteAlignmentPolicy(
                maximumUnmatchedPrefixSuffixMeters: 2_000,
                maximumUnmatchedPrefixSuffixFraction: 0.5,
                maximumBandCells: 10_000
            )
        )
        XCTAssertEqual(solverLimited.availability.unavailableReason, .resourceLimit)
        XCTAssertGreaterThan(solverLimited.diagnostics.primarySampleCount, 0)
    }

    func testSnapshotParityIsIdenticalWhenRepeated() throws {
        let base = makeLinearWorkout(distanceMeters: 2_200, stepMeters: 20)
        let noisy = makeSeededNoisyWorkout(from: base, noiseMeters: 6, seed: 99)
        let first = try assertSnapshotParity("repeat-1", primary: base, comparison: noisy)
        let second = try assertSnapshotParity("repeat-2", primary: base, comparison: noisy)
        XCTAssertEqual(first, second, "repeated production alignment must be identical")
    }

    func testSnapshotParityWhenCancelledBeforeAnyWork() throws {
        let workout = makeLinearWorkout(distanceMeters: 5_000, stepMeters: 10)
        let snapshot = try assertSnapshotParity(
            "always-cancelled",
            primary: workout,
            comparison: workout,
            isCancelled: { true }
        )
        XCTAssertEqual(snapshot.availability.unavailableReason, .cancelled)
        XCTAssertTrue(snapshot.blocks.isEmpty)
    }

    /// Production-only: cancellation call counts legitimately differ between the
    /// migrated aligner and the pre-migration one, because the dynamic
    /// programming no longer polls per cell. What must hold is that flipping the
    /// token at *any* observation point — including the one immediately after the
    /// native solve returns — yields `.unavailable(.cancelled)` and never an
    /// available snapshot.
    func testCancellationAfterNativeWorkNeverPublishesAnAvailableResult() throws {
        let workout = makeLinearWorkout(distanceMeters: 1_400, stepMeters: 20)
        let context = WorkoutAnalysisContext(workout: workout)

        let probe = CancellationProbe(cancelAfter: Int.max)
        let uncancelled = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: context,
            comparisonContext: context,
            policy: policy,
            isCancelled: { probe.observe() }
        )
        XCTAssertTrue(uncancelled.availability.isAvailable, "baseline must complete")
        let totalObservations = probe.observationCount
        // Guards against the sweep silently shrinking to a couple of call sites.
        XCTAssertGreaterThan(totalObservations, 50, "cancellation observation points")

        for threshold in 0..<totalObservations {
            let counted = CancellationProbe(cancelAfter: threshold)
            let snapshot = try aligner.align(
                primary: workout,
                comparison: workout,
                primaryContext: context,
                comparisonContext: context,
                policy: policy,
                isCancelled: { counted.observe() }
            )
            XCTAssertEqual(
                snapshot.availability,
                .unavailable(.cancelled),
                "cancelling at observation \(threshold) of \(totalObservations)"
            )
            XCTAssertTrue(snapshot.blocks.isEmpty, "cancelled snapshot must expose no blocks")
        }

        // Never cancelling reproduces the baseline exactly.
        let neverCancelled = CancellationProbe(cancelAfter: totalObservations)
        let repeated = try aligner.align(
            primary: workout,
            comparison: workout,
            primaryContext: context,
            comparisonContext: context,
            policy: policy,
            isCancelled: { neverCancelled.observe() }
        )
        XCTAssertEqual(repeated, uncancelled)
    }

    func testSnapshotParityAtMaximumSampleCount() throws {
        // 39,980 m at the 20 m preferred interval resamples to exactly
        // `maximumSamplesPerRoute` alignment samples on each route.
        let dense = makeLinearWorkout(distanceMeters: 39_980, stepMeters: 20)
        let snapshot = try assertSnapshotParity("maximum-samples", primary: dense, comparison: dense)
        XCTAssertEqual(snapshot.diagnostics.primarySampleCount, policy.maximumSamplesPerRoute)
        XCTAssertEqual(snapshot.diagnostics.comparisonSampleCount, policy.maximumSamplesPerRoute)
        XCTAssertTrue(snapshot.availability.isAvailable)
    }

    func testSnapshotParityAcrossCustomPolicies() throws {
        let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let shifted = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 25, startOffsetMeters: 12)
        let noisy = makeSeededNoisyWorkout(from: base, noiseMeters: 9, seed: 7)

        let policies: [(String, RouteAlignmentPolicy)] = [
            ("band-0.001", RouteAlignmentPolicy(bandWidthFraction: 0.001)),
            ("band-0.05", RouteAlignmentPolicy(bandWidthFraction: 0.05)),
            ("band-0.45", RouteAlignmentPolicy(bandWidthFraction: 0.45)),
            ("band-1.0", RouteAlignmentPolicy(bandWidthFraction: 1.0)),
            ("warp-0", RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 0)),
            ("warp-1", RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 1)),
            ("warp-3", RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 3)),
            ("warp-64", RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 64)),
            ("warp-400", RouteAlignmentPolicy(maximumConsecutiveWarpSteps: 400)),
            ("penalty-negative", RouteAlignmentPolicy(nonDiagonalStepPenalty: -0.5)),
            ("penalty-zero", RouteAlignmentPolicy(nonDiagonalStepPenalty: 0)),
            ("penalty-high", RouteAlignmentPolicy(nonDiagonalStepPenalty: 5)),
            ("closed-ends", RouteAlignmentPolicy(
                maximumUnmatchedPrefixSuffixMeters: 0,
                maximumUnmatchedPrefixSuffixFraction: 0
            )),
            ("narrow-ends", RouteAlignmentPolicy(
                maximumUnmatchedPrefixSuffixMeters: 200,
                maximumUnmatchedPrefixSuffixFraction: 0.02
            )),
            ("wide-ends", RouteAlignmentPolicy(
                maximumUnmatchedPrefixSuffixMeters: 2_000,
                maximumUnmatchedPrefixSuffixFraction: 0.5
            )),
            ("min-aligned-zero", RouteAlignmentPolicy(minimumAlignedDistanceMeters: 0)),
            ("min-aligned-2500", RouteAlignmentPolicy(minimumAlignedDistanceMeters: 2_500)),
            ("min-aligned-huge", RouteAlignmentPolicy(minimumAlignedDistanceMeters: 100_000)),
        ]

        var availableOutcomes = 0
        var unavailableOutcomes = 0
        for (name, custom) in policies {
            for (label, comparison) in [("shifted", shifted), ("noisy", noisy)] {
                let snapshot = try assertSnapshotParity(
                    "\(name)/\(label)",
                    primary: base,
                    comparison: comparison,
                    policy: custom
                )
                if snapshot.availability.isAvailable {
                    availableOutcomes += 1
                } else {
                    unavailableOutcomes += 1
                }
            }
        }
        // The sweep must keep reaching both outcomes, or it silently stops
        // covering half of the classification code.
        XCTAssertGreaterThan(availableOutcomes, 0)
        XCTAssertGreaterThan(unavailableOutcomes, 0)
    }

    // MARK: - Parity assertion

    /// Runs the production aligner and the pre-migration oracle over the same
    /// inputs and compares every public field of the resulting snapshots.
    @discardableResult
    private func assertSnapshotParity(
        _ name: String,
        primary: RunWorkout,
        comparison: RunWorkout,
        policy customPolicy: RouteAlignmentPolicy? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RouteAlignmentSnapshot {
        let effectivePolicy = customPolicy ?? policy
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)

        let produced = try aligner.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            policy: effectivePolicy,
            isCancelled: isCancelled
        )
        let expected = try preMigrationOracle.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            policy: effectivePolicy,
            isCancelled: isCancelled
        )

        assertSnapshotsMatch(name, produced, expected, file: file, line: line)
        return produced
    }

    private func assertSnapshotsMatch(
        _ name: String,
        _ actual: RouteAlignmentSnapshot,
        _ expected: RouteAlignmentSnapshot,
        file: StaticString,
        line: UInt
    ) {
        // Availability: quality when available, structured reason when not.
        XCTAssertEqual(
            actual.availability, expected.availability,
            "\(name): availability", file: file, line: line
        )
        XCTAssertEqual(
            actual.availability.quality, expected.availability.quality,
            "\(name): quality", file: file, line: line
        )
        XCTAssertEqual(
            actual.availability.unavailableReason, expected.availability.unavailableReason,
            "\(name): unavailable reason", file: file, line: line
        )
        XCTAssertEqual(
            actual.policyVersion, expected.policyVersion,
            "\(name): policyVersion", file: file, line: line
        )
        assertDoubleParity(
            actual.totalAlignedDistanceMeters, expected.totalAlignedDistanceMeters,
            "\(name): totalAlignedDistanceMeters", file: file, line: line
        )

        // Blocks and every anchor inside them.
        XCTAssertEqual(
            actual.blocks.count, expected.blocks.count,
            "\(name): blocks.count", file: file, line: line
        )
        for index in 0..<min(actual.blocks.count, expected.blocks.count) {
            let actualBlock = actual.blocks[index]
            let expectedBlock = expected.blocks[index]
            XCTAssertEqual(
                actualBlock.id, expectedBlock.id,
                "\(name): block \(index) id", file: file, line: line
            )
            assertDoubleParity(
                actualBlock.alignedStartMeters, expectedBlock.alignedStartMeters,
                "\(name): block \(index) alignedStartMeters", file: file, line: line
            )
            assertDoubleParity(
                actualBlock.alignedEndMeters, expectedBlock.alignedEndMeters,
                "\(name): block \(index) alignedEndMeters", file: file, line: line
            )
            XCTAssertEqual(
                actualBlock.anchors.count, expectedBlock.anchors.count,
                "\(name): block \(index) anchors.count", file: file, line: line
            )
            for anchorIndex in 0..<min(actualBlock.anchors.count, expectedBlock.anchors.count) {
                let actualAnchor = actualBlock.anchors[anchorIndex]
                let expectedAnchor = expectedBlock.anchors[anchorIndex]
                let label = "\(name): block \(index) anchor \(anchorIndex)"
                assertDoubleParity(
                    actualAnchor.alignedProgressMeters, expectedAnchor.alignedProgressMeters,
                    "\(label) alignedProgressMeters", file: file, line: line
                )
                assertDoubleParity(
                    actualAnchor.primaryDistanceMeters, expectedAnchor.primaryDistanceMeters,
                    "\(label) primaryDistanceMeters", file: file, line: line
                )
                assertDoubleParity(
                    actualAnchor.comparisonDistanceMeters, expectedAnchor.comparisonDistanceMeters,
                    "\(label) comparisonDistanceMeters", file: file, line: line
                )
                assertDoubleParity(
                    actualAnchor.spatialSeparationMeters, expectedAnchor.spatialSeparationMeters,
                    "\(label) spatialSeparationMeters", file: file, line: line
                )
                XCTAssertEqual(
                    actualAnchor.primarySegmentIndex, expectedAnchor.primarySegmentIndex,
                    "\(label) primarySegmentIndex", file: file, line: line
                )
                XCTAssertEqual(
                    actualAnchor.comparisonSegmentIndex, expectedAnchor.comparisonSegmentIndex,
                    "\(label) comparisonSegmentIndex", file: file, line: line
                )
            }
        }

        assertDiagnosticsMatch(name, actual.diagnostics, expected.diagnostics, file: file, line: line)

        // The delegated path is bit-identical and the surrounding Swift code is
        // unchanged, so the whole value must compare equal, not merely close.
        XCTAssertTrue(
            actual == expected,
            "\(name): snapshots differ beyond the field comparisons above",
            file: file, line: line
        )
    }

    private func assertDiagnosticsMatch(
        _ name: String,
        _ actual: RouteAlignmentDiagnostics,
        _ expected: RouteAlignmentDiagnostics,
        file: StaticString,
        line: UInt
    ) {
        let doubleFields: [(String, KeyPath<RouteAlignmentDiagnostics, Double>)] = [
            ("primaryRouteDistanceMeters", \.primaryRouteDistanceMeters),
            ("comparisonRouteDistanceMeters", \.comparisonRouteDistanceMeters),
            ("effectiveSampleIntervalMeters", \.effectiveSampleIntervalMeters),
            ("alignedDistanceMeters", \.alignedDistanceMeters),
            ("primaryCoverageFraction", \.primaryCoverageFraction),
            ("comparisonCoverageFraction", \.comparisonCoverageFraction),
            ("meanSpatialSeparationMeters", \.meanSpatialSeparationMeters),
            ("medianSpatialSeparationMeters", \.medianSpatialSeparationMeters),
            ("p90SpatialSeparationMeters", \.p90SpatialSeparationMeters),
            ("maximumSpatialSeparationMeters", \.maximumSpatialSeparationMeters),
            ("primaryUnmatchedPrefixMeters", \.primaryUnmatchedPrefixMeters),
            ("primaryUnmatchedSuffixMeters", \.primaryUnmatchedSuffixMeters),
            ("comparisonUnmatchedPrefixMeters", \.comparisonUnmatchedPrefixMeters),
            ("comparisonUnmatchedSuffixMeters", \.comparisonUnmatchedSuffixMeters),
        ]
        for (label, keyPath) in doubleFields {
            assertDoubleParity(
                actual[keyPath: keyPath], expected[keyPath: keyPath],
                "\(name): diagnostics.\(label)", file: file, line: line
            )
        }

        let integerFields: [(String, KeyPath<RouteAlignmentDiagnostics, Int>)] = [
            ("primarySampleCount", \.primarySampleCount),
            ("comparisonSampleCount", \.comparisonSampleCount),
            ("matchedBlockCount", \.matchedBlockCount),
            ("diagonalStepCount", \.diagonalStepCount),
            ("primaryOnlyWarpStepCount", \.primaryOnlyWarpStepCount),
            ("comparisonOnlyWarpStepCount", \.comparisonOnlyWarpStepCount),
            ("maximumConsecutiveWarpRun", \.maximumConsecutiveWarpRun),
            ("algorithmVersion", \.algorithmVersion),
        ]
        for (label, keyPath) in integerFields {
            XCTAssertEqual(
                actual[keyPath: keyPath], expected[keyPath: keyPath],
                "\(name): diagnostics.\(label)", file: file, line: line
            )
        }

        XCTAssertEqual(
            actual.detectedDirection, expected.detectedDirection,
            "\(name): diagnostics.detectedDirection", file: file, line: line
        )
        XCTAssertEqual(
            actual.warnings, expected.warnings,
            "\(name): diagnostics.warnings", file: file, line: line
        )
        XCTAssertEqual(
            actual.compactStatusLabel, expected.compactStatusLabel,
            "\(name): diagnostics.compactStatusLabel", file: file, line: line
        )
    }

    /// Absolute 1e-9, widened only in proportion to magnitude so kilometre-scale
    /// distances are still held to roughly twelve significant digits.
    private func assertDoubleParity(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(
            actual, expected,
            accuracy: max(1e-9, abs(expected) * 1e-12),
            label, file: file, line: line
        )
    }

    // MARK: - Helpers

    private func assertMonotonic(_ snapshot: RouteAlignmentSnapshot) {
        for block in snapshot.blocks {
            var lastP = -1.0
            var lastC = -1.0
            var lastA = -1.0
            for anchor in block.anchors {
                XCTAssertGreaterThanOrEqual(anchor.primaryDistanceMeters, lastP - 1e-6)
                XCTAssertGreaterThanOrEqual(anchor.comparisonDistanceMeters, lastC - 1e-6)
                XCTAssertGreaterThanOrEqual(anchor.alignedProgressMeters, lastA - 1e-6)
                lastP = anchor.primaryDistanceMeters
                lastC = anchor.comparisonDistanceMeters
                lastA = anchor.alignedProgressMeters
            }
        }
    }

    private func assertFiniteDiagnostics(_ d: RouteAlignmentDiagnostics) {
        XCTAssertTrue(d.alignedDistanceMeters.isFinite)
        XCTAssertTrue(d.medianSpatialSeparationMeters.isFinite)
        XCTAssertTrue(d.p90SpatialSeparationMeters.isFinite)
        XCTAssertTrue(d.primaryCoverageFraction.isFinite)
        XCTAssertTrue(d.comparisonCoverageFraction.isFinite)
        XCTAssertGreaterThanOrEqual(d.primaryCoverageFraction, 0)
        XCTAssertLessThanOrEqual(d.primaryCoverageFraction, 1)
    }

    /// Fixed timestamp origin so every fixture is reproducible run to run.
    /// Route geometry never depends on it; alignment cost is geometry-only.
    private static let fixtureEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeLinearWorkout(
        distanceMeters: Double,
        stepMeters: Double,
        startOffsetMeters: Double = 0,
        lat: Double = 37.7749,
        lon: Double = -122.4194
    ) -> RunWorkout {
        let start = Self.fixtureEpoch
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            let along = d + startOffsetMeters
            let latitude = lat + (along / 111_000)
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: latitude,
                longitude: lon,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + stepMeters)
        }
        return RunWorkout(routePoints: points)
    }

    private func makeNoisyWorkout(from workout: RunWorkout, noiseMeters: Double) -> RunWorkout {
        let points = workout.routePoints.enumerated().map { index, point in
            let sign = index % 2 == 0 ? 1.0 : -1.0
            let latNoise = (noiseMeters * sign) / 111_000
            return RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + latNoise,
                longitude: point.longitude,
                altitudeMeters: point.altitudeMeters,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        return RunWorkout(routePoints: points)
    }

    private func reverseWorkout(_ workout: RunWorkout) -> RunWorkout {
        let total = workout.routePoints.last?.distanceFromStartMeters ?? 0
        let totalElapsed = workout.routePoints.last?.elapsedSeconds ?? 0
        let reversed = workout.routePoints.reversed().enumerated().map { index, point in
            RoutePoint(
                timestamp: workout.routePoints[0].timestamp.addingTimeInterval(Double(index)),
                latitude: point.latitude,
                longitude: point.longitude,
                distanceFromStartMeters: total - point.distanceFromStartMeters,
                elapsedSeconds: totalElapsed - point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: 0
            )
        }
        // Re-sort by increasing distance after reverse mapping.
        let ordered = reversed.sorted { $0.distanceFromStartMeters < $1.distanceFromStartMeters }
        return RunWorkout(routePoints: ordered)
    }

    private func makeGappedWorkout(
        segmentDistances: [Double],
        stepMeters: Double = 20,
        gapMeters: Double = 50
    ) -> RunWorkout {
        let start = Self.fixtureEpoch
        var points: [RoutePoint] = []
        var distance = 0.0
        var elapsed = 0.0
        for (segment, length) in segmentDistances.enumerated() {
            var local = 0.0
            while local <= length {
                let lat = 37.7749 + (distance / 111_000)
                points.append(RoutePoint(
                    timestamp: start.addingTimeInterval(elapsed),
                    latitude: lat,
                    longitude: -122.4194,
                    distanceFromStartMeters: distance,
                    elapsedSeconds: elapsed,
                    paceSecondsPerKilometer: 300,
                    routeSegmentIndex: segment
                ))
                if local >= length { break }
                local += stepMeters
                distance += stepMeters
                elapsed += stepMeters / 3
            }
            // Gap in time/distance bookkeeping: jump distance slightly without geometry bridge.
            distance += gapMeters
            elapsed += 30
        }
        return RunWorkout(routePoints: points)
    }

    /// Straight line displaced sideways by a fixed number of metres, so the two
    /// routes stay inside the supported projected extent while being far apart.
    private func makeParallelWorkout(
        distanceMeters: Double,
        stepMeters: Double,
        lateralOffsetMeters: Double,
        lat: Double = 37.7749,
        lon: Double = -122.4194
    ) -> RunWorkout {
        let metersPerDegreeLongitude = 111_000 * cos(lat * .pi / 180)
        return makeLinearWorkout(
            distanceMeters: distanceMeters,
            stepMeters: stepMeters,
            lat: lat,
            lon: lon + lateralOffsetMeters / metersPerDegreeLongitude
        )
    }

    /// Closed square loop, optionally started part-way around the perimeter.
    /// Rotated starts are what make the direction probe report `.ambiguous`.
    private func makeSquareLoopWorkout(
        sideMeters: Double,
        stepMeters: Double,
        startFraction: Double,
        lat: Double = 37.7749,
        lon: Double = -122.4194
    ) -> RunWorkout {
        let perimeter = sideMeters * 4
        let metersPerDegreeLatitude = 111_000.0
        let metersPerDegreeLongitude = 111_000 * cos(lat * .pi / 180)
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= perimeter {
            let position = (travelled + startFraction * perimeter)
                .truncatingRemainder(dividingBy: perimeter)
            let east: Double
            let north: Double
            switch position {
            case ..<sideMeters:
                east = position
                north = 0
            case ..<(2 * sideMeters):
                east = sideMeters
                north = position - sideMeters
            case ..<(3 * sideMeters):
                east = sideMeters - (position - 2 * sideMeters)
                north = sideMeters
            default:
                east = 0
                north = sideMeters - (position - 3 * sideMeters)
            }
            points.append(RoutePoint(
                timestamp: Self.fixtureEpoch.addingTimeInterval(travelled / 3),
                latitude: lat + north / metersPerDegreeLatitude,
                longitude: lon + east / metersPerDegreeLongitude,
                distanceFromStartMeters: travelled,
                elapsedSeconds: travelled / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if travelled >= perimeter { break }
            travelled = min(perimeter, travelled + stepMeters)
        }
        return RunWorkout(routePoints: points)
    }

    /// Seeded SplitMix64 jitter in both axes. Deterministic for a given seed;
    /// no system randomness and no wall-clock input.
    private func makeSeededNoisyWorkout(
        from workout: RunWorkout,
        noiseMeters: Double,
        seed: UInt64
    ) -> RunWorkout {
        var generator = SplitMix64(seed: seed)
        let points = workout.routePoints.map { point in
            let latitudeNoise = generator.symmetric(noiseMeters) / 111_000
            let metersPerDegreeLongitude = 111_000 * cos(point.latitude * .pi / 180)
            let longitudeNoise = generator.symmetric(noiseMeters) / metersPerDegreeLongitude
            return RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + latitudeNoise,
                longitude: point.longitude + longitudeNoise,
                altitudeMeters: point.altitudeMeters,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        return RunWorkout(routePoints: points)
    }
}

/// Deterministic pseudo-random source for fixture jitter.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in `-magnitude ... magnitude`.
    mutating func symmetric(_ magnitude: Double) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return (unit * 2 - 1) * magnitude
    }
}

/// Counts cancellation observations and flips the token permanently once the
/// configured number of observations has been made.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var observations = 0

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    func observe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cancelled = observations >= cancelAfter
        observations += 1
        return cancelled
    }

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}
