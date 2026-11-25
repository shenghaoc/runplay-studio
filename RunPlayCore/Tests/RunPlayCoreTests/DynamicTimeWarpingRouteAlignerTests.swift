import XCTest
@testable import RunPlayCore

final class DynamicTimeWarpingRouteAlignerTests: XCTestCase {
    private let aligner = ConstrainedDynamicTimeWarpingAligner()
    private let policy = RouteAlignmentPolicy.default

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

    // MARK: - End-to-end snapshots
    //
    // These run the production aligner end to end and pin the behaviour of
    // the resulting snapshots. `RouteAlignmentDtwGoldenTests` pins the path
    // solve itself. Every fixture is deterministic: fixed geometry or seeded
    // SplitMix64 noise, never wall-clock or system randomness.

    func testSnapshotForIdenticalRoutes() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 25)
        let snapshot = try alignSnapshot(
            "identical",
            primary: workout,
            comparison: workout
        )
        XCTAssertTrue(snapshot.availability.isAvailable)
        XCTAssertFalse(snapshot.blocks.isEmpty)
    }

    func testSnapshotForDenseAndSparseSampleRates() throws {
        let dense = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 10)
        let sparse = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 40)
        let forward = try alignSnapshot("dense-vs-sparse", primary: dense, comparison: sparse)
        XCTAssertTrue(forward.availability.isAvailable)
        try alignSnapshot("sparse-vs-dense", primary: sparse, comparison: dense)
    }

    func testSnapshotForGPSNoise() throws {
        let clean = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
        let alternating = makeNoisyWorkout(from: clean, noiseMeters: 4)
        let noisy = try alignSnapshot("alternating-noise", primary: clean, comparison: alternating)
        XCTAssertTrue(noisy.availability.isAvailable)
        assertPinnedSnapshot(
            "alternating-noise", noisy,
            quality: .excellent, anchorsPerBlock: [136], totalAlignedDistanceMeters: 2_700,
            digest: 0x2cd2_2847_374b_90c4
        )

        // The seeded fixtures add noise through `cos`, so the inputs, and with
        // them the snapshots, differ by platform libm. Each digest is pinned
        // per platform; the structure is pinned everywhere.
        let seeded: [(seed: UInt64, amplitude: Double, quality: RouteAlignmentQuality,
                      anchors: [Int], total: Double, digest: UInt64?)] = [
            (1, 3, .excellent, [136], 2_700, Self.seededNoiseDigests.0),
            (2, 12, .excellent, [136], 2_700, Self.seededNoiseDigests.1),
            (3, 45, .good, [137], 2_720, Self.seededNoiseDigests.2),
        ]
        for fixture in seeded {
            let name = "seeded-noise-\(fixture.seed)"
            let snapshot = try alignSnapshot(
                name,
                primary: clean,
                comparison: makeSeededNoisyWorkout(
                    from: clean, noiseMeters: fixture.amplitude, seed: fixture.seed
                )
            )
            assertPinnedSnapshot(
                name, snapshot,
                quality: fixture.quality, anchorsPerBlock: fixture.anchors,
                totalAlignedDistanceMeters: fixture.total, digest: fixture.digest
            )
        }
    }

    /// Full-snapshot digests (`ExactValueDigest`) of the seeded GPS-noise
    /// fixtures, taken from the production aligner on each platform once the
    /// golden digests pinned the engine.
    private static var seededNoiseDigests: (UInt64?, UInt64?, UInt64?) {
        #if os(macOS) && arch(arm64)
        // Xcode 27.2 locally and Xcode 26.6 in hosted CI give the same values.
        (0x384b_5a92_edb0_4517, 0x88f8_bfb0_c85f_d0db, 0x8c60_cf1f_777b_1b84)
        #elseif os(Linux) && arch(x86_64)
        // Hosted Linux CI run 45546263205, in the pinned swift:6.3.3 image.
        (0x38b8_c50b_988c_5791, 0x1713_2d10_b097_c80a, 0x9e1d_5cbc_b95a_8f7a)
        #elseif os(Linux) && arch(arm64)
        // The pinned swift:6.3.3 image, Apple container on arm64.
        (0x6715_ad28_6353_41a2, 0xdf7b_894a_ea32_bd62, 0xe5e3_5aa3_a033_bc0d)
        #else
        (nil, nil, nil)
        #endif
    }

    /// Fails when a platform condition leaves `seededNoiseDigests` nil on a
    /// platform that pins it. A nil digest skips only the digest assertion,
    /// so the seeded snapshots would otherwise pass on structure alone.
    func testSeededNoiseDigestsArePinnedOnPinnedPlatforms() {
        let platform = GoldenPlatform.current
        guard platform == .macOSArm64 || platform == .linuxX86_64 || platform == .linuxArm64 else { return }
        let digests = Self.seededNoiseDigests
        XCTAssertTrue(
            digests.0 != nil && digests.1 != nil && digests.2 != nil,
            GoldenPlatform.unpinnedMessage("seededNoiseDigests")
        )
    }

    /// Pins one snapshot. It replaces the comparison with the retired
    /// pre-migration aligner, which compared the whole snapshot exactly: the
    /// availability, block structure and aligned distance are asserted
    /// directly, and the digest covers every remaining field, every anchor
    /// and the diagnostics bit for bit.
    private func assertPinnedSnapshot(
        _ name: String,
        _ snapshot: RouteAlignmentSnapshot,
        quality: RouteAlignmentQuality,
        anchorsPerBlock: [Int],
        totalAlignedDistanceMeters: Double,
        digest: UInt64?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(snapshot.availability, .available(quality), "\(name): availability", file: file, line: line)
        XCTAssertEqual(snapshot.policyVersion, 1, "\(name): policyVersion", file: file, line: line)
        XCTAssertEqual(
            snapshot.blocks.map(\.anchors.count), anchorsPerBlock,
            "\(name): anchors per block", file: file, line: line
        )
        XCTAssertEqual(
            snapshot.totalAlignedDistanceMeters, totalAlignedDistanceMeters,
            "\(name): totalAlignedDistanceMeters", file: file, line: line
        )
        XCTAssertEqual(
            snapshot.diagnostics.matchedBlockCount, anchorsPerBlock.count,
            "\(name): matchedBlockCount", file: file, line: line
        )
        let actualDigest = ExactValueDigest.of(snapshot)
        print("DTW_GPS_NOISE_DIGEST \(name)=\(ExactValueDigest.hex(actualDigest))")
        if let digest {
            XCTAssertEqual(
                ExactValueDigest.hex(actualDigest), ExactValueDigest.hex(digest),
                "\(name): full snapshot digest", file: file, line: line
            )
        }
    }

    func testSnapshotForOppositeDirection() throws {
        let forward = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20)
        let reverse = reverseWorkout(forward)
        let snapshot = try alignSnapshot("opposite", primary: forward, comparison: reverse)
        XCTAssertEqual(snapshot.availability.unavailableReason, .oppositeDirection)
        XCTAssertEqual(snapshot.diagnostics.detectedDirection, .opposite)
    }

    func testSnapshotForUnrelatedRoutes() throws {
        // Far enough apart that the shared local projection is rejected.
        let west = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 37.77, lon: -122.42)
        let east = makeLinearWorkout(distanceMeters: 2_500, stepMeters: 20, lat: 40.71, lon: -74.00)
        let continental = try alignSnapshot("continental", primary: west, comparison: east)
        XCTAssertEqual(continental.availability.unavailableReason, .unsupportedGeographicExtent)

        // Same city, parallel streets: rejected by separation, not by extent.
        for offset in [200.0, 1_000.0, 5_000.0] {
            let base = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)
            let parallel = makeParallelWorkout(
                distanceMeters: 3_000,
                stepMeters: 20,
                lateralOffsetMeters: offset
            )
            let snapshot = try alignSnapshot("parallel-\(offset)", primary: base, comparison: parallel)
            XCTAssertEqual(snapshot.availability.unavailableReason, .routesTooFarApart)
        }
    }

    func testSnapshotForRecordingGapsProducingMultipleBlocks() throws {
        let twoSegments = makeGappedWorkout(segmentDistances: [1_500, 1_500])
        let paired = try alignSnapshot(
            "gapped-vs-gapped",
            primary: twoSegments,
            comparison: twoSegments
        )
        XCTAssertEqual(paired.blocks.count, 2)
        XCTAssertEqual(paired.diagnostics.matchedBlockCount, 2)

        let continuous = makeLinearWorkout(distanceMeters: 3_050, stepMeters: 20)
        let mixed = try alignSnapshot(
            "gapped-vs-continuous",
            primary: continuous,
            comparison: twoSegments
        )
        XCTAssertGreaterThanOrEqual(mixed.blocks.count, 2)

        let threeSegments = makeGappedWorkout(
            segmentDistances: [1_200, 900, 1_100],
            gapMeters: 120
        )
        let triple = try alignSnapshot(
            "three-segments",
            primary: threeSegments,
            comparison: threeSegments
        )
        XCTAssertEqual(triple.blocks.count, 3)
    }

    func testSnapshotForAmbiguousDirection() throws {
        let loop = makeSquareLoopWorkout(sideMeters: 500, stepMeters: 20, startFraction: 0)

        // Default policy: ambiguous geometry that never becomes available.
        for rotation in [0.25, 0.75] {
            let rotated = makeSquareLoopWorkout(
                sideMeters: 500,
                stepMeters: 20,
                startFraction: rotation
            )
            let snapshot = try alignSnapshot(
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
            let snapshot = try alignSnapshot(
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

    func testSnapshotForResourceLimits() throws {
        let workout = makeLinearWorkout(distanceMeters: 3_000, stepMeters: 20)

        // Tiny budget: the sample builder refuses before any solve.
        for cells in [0, 8, 64, 512] {
            let snapshot = try alignSnapshot(
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
        let solverLimited = try alignSnapshot(
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

    func testSnapshotIsIdenticalWhenRepeated() throws {
        let base = makeLinearWorkout(distanceMeters: 2_200, stepMeters: 20)
        let noisy = makeSeededNoisyWorkout(from: base, noiseMeters: 6, seed: 99)
        let first = try alignSnapshot("repeat-1", primary: base, comparison: noisy)
        let second = try alignSnapshot("repeat-2", primary: base, comparison: noisy)
        XCTAssertEqual(first, second, "repeated production alignment must be identical")
    }

    func testSnapshotWhenCancelledBeforeAnyWork() throws {
        let workout = makeLinearWorkout(distanceMeters: 5_000, stepMeters: 10)
        let snapshot = try alignSnapshot(
            "always-cancelled",
            primary: workout,
            comparison: workout,
            isCancelled: { true }
        )
        XCTAssertEqual(snapshot.availability.unavailableReason, .cancelled)
        XCTAssertTrue(snapshot.blocks.isEmpty)
    }

    /// The aligner does not poll cancellation per dynamic-programming cell.
    /// What must hold is that flipping the
    /// token at *any* observation point — including the one immediately after the
    /// engine solve returns — yields `.unavailable(.cancelled)` and never an
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

    func testSnapshotAtMaximumSampleCount() throws {
        // 39,980 m at the 20 m preferred interval resamples to exactly
        // `maximumSamplesPerRoute` alignment samples on each route.
        let dense = makeLinearWorkout(distanceMeters: 39_980, stepMeters: 20)
        let snapshot = try alignSnapshot("maximum-samples", primary: dense, comparison: dense)
        XCTAssertEqual(snapshot.diagnostics.primarySampleCount, policy.maximumSamplesPerRoute)
        XCTAssertEqual(snapshot.diagnostics.comparisonSampleCount, policy.maximumSamplesPerRoute)
        XCTAssertTrue(snapshot.availability.isAvailable)
    }

    func testSnapshotAcrossCustomPolicies() throws {
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
                let snapshot = try alignSnapshot(
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

    // MARK: - Alignment helper

    /// Runs the production aligner over the inputs with fresh analysis
    /// contexts and returns its snapshot. `name` labels the case at the call
    /// site.
    @discardableResult
    private func alignSnapshot(
        _ name: String,
        primary: RunWorkout,
        comparison: RunWorkout,
        policy customPolicy: RouteAlignmentPolicy? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> RouteAlignmentSnapshot {
        let effectivePolicy = customPolicy ?? policy
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)

        return try aligner.align(
            primary: primary,
            comparison: comparison,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext,
            policy: effectivePolicy,
            isCancelled: isCancelled
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
