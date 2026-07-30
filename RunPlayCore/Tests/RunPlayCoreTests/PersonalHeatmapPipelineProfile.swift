import XCTest
@testable import RunPlayCore

/// Phase-level profiler for the Personal Heatmap build pipeline.
///
/// ## Why this exists
///
/// `PersonalHeatmapCoverageBenchmark` establishes the authoritative
/// production-versus-Swift-oracle comparison, but its extra subtimings are
/// independent diagnostics: input conversion is measured on a separately
/// prepared batch, and the native coverage total is measured once at the final
/// effective cell size rather than across every adaptive pass. Those numbers
/// cannot be added to explain a production total.
///
/// This profiler replaces that breakdown with an additive decomposition taken
/// from **one** production-equivalent orchestration.
///
/// ## Two modes
///
/// * **Mode A** times the unmodified public
///   `PersonalHeatmapBuilder.build(workouts:configuration:isCancelled:)`. That
///   is the authoritative end-to-end value. The public builder gains no timing
///   hooks.
/// * **Mode B** is a test-only reconstruction of the same orchestration that
///   records phase timings. It is asserted exactly equal to both the public
///   builder and `SwiftPersonalHeatmapBuilderOracle`, and its own overhead
///   versus Mode A is reported so phase percentages can be read honestly.
///
/// Skipped unless `RUNPLAY_HEATMAP_PROFILE=1`; run it through
/// `scripts/run-personal-heatmap-profile.sh`, never in ordinary CI.
final class PersonalHeatmapPipelineProfile: XCTestCase {

    /// Requirement 2.4: phase attribution tables are only published when the
    /// unaccounted residue is at most this percentage of the profiled wall clock.
    private static let maximumUnaccountedPercent: Double = 5

    // MARK: - Entry point

    func testPersonalHeatmapPipelineProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_HEATMAP_PROFILE"] == "1",
            "Set RUNPLAY_HEATMAP_PROFILE=1 to run the release pipeline profile."
        )

        var report: [String] = []
        report.append("<!-- BEGIN RUNPLAY HEATMAP PROFILE -->")
        report.append("")
        report.append("## RunPlay Personal Heatmap pipeline profile")
        report.append("")
        report.append("Mode A is the unmodified public `PersonalHeatmapBuilder.build`.")
        report.append("Mode B is the test-only profiled reconstruction of the same orchestration.")
        report.append("Every Mode B snapshot is asserted exactly equal to both Mode A and the Swift oracle.")
        report.append("")

        var fixtureRows: [String] = []
        var phaseMillisecondRows: [String] = []
        var phasePercentRows: [String] = []
        var primaryDetail: [String] = []

        for fixture in Self.fixtures() {
            let outcome = try runFixture(fixture)
            fixtureRows.append(outcome.matrixRow)
            phaseMillisecondRows.append(outcome.phaseMillisecondRow)
            phasePercentRows.append(outcome.phasePercentRow)
            if fixture.isPrimary {
                primaryDetail = outcome.detailSection
            }
        }

        report.append("### Fixture matrix")
        report.append("")
        report.append("| Fixture | Workouts | Points | Cell size | Retries | Effective cell | Aggregated | Rendered | Mode A median | Mode B median | Overhead | Unaccounted |")
        report.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        report.append(contentsOf: fixtureRows)
        report.append("")

        report.append("### Phase breakdown across every fixture (ms, last measured Mode B iteration)")
        report.append("")
        report.append("`Native`, `Alloc`, and `Xlate` are nested inside `Coverage` and are not summed again.")
        report.append("")
        report.append("| Fixture | Date | Prep | Coverage | ⤷ Native | ⤷ Alloc | ⤷ Xlate | Counting | Filter | Decision | Sort | Cells | Assemble | Unacc. | Total |")
        report.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        report.append(contentsOf: phaseMillisecondRows)
        report.append("")

        report.append("### Phase breakdown across every fixture (percent of profiled wall clock)")
        report.append("")
        report.append("| Fixture | Date | Prep | Coverage | ⤷ Native | ⤷ Alloc | ⤷ Xlate | Counting | Filter | Decision | Sort | Cells | Assemble | Unacc. |")
        report.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        report.append(contentsOf: phasePercentRows)
        report.append("")

        if !primaryDetail.isEmpty {
            report.append(contentsOf: primaryDetail)
        }

        report.append("<!-- END RUNPLAY HEATMAP PROFILE -->")

        print(report.joined(separator: "\n"))
    }

    // MARK: - Per-fixture driver

    private struct FixtureOutcome {
        let matrixRow: String
        let phaseMillisecondRow: String
        let phasePercentRow: String
        let detailSection: [String]
    }

    private func runFixture(_ fixture: Fixture) throws -> FixtureOutcome {
        let workouts = library(for: fixture)
        let configuration = fixture.configuration
        let builder = PersonalHeatmapBuilder()
        let oracle = SwiftPersonalHeatmapBuilderOracle()

        // Parity reference computed once; snapshots are deterministic, so every
        // measured Mode B iteration is compared against it.
        let oracleSnapshot = try oracle.build(workouts: workouts, configuration: configuration)
        let productionReference = try builder.build(workouts: workouts, configuration: configuration)
        XCTAssertEqual(
            productionReference,
            oracleSnapshot,
            "\(fixture.key): production builder diverged from the Swift oracle"
        )

        var productionSamples: [Double] = []
        var reconstructionSamples: [Double] = []
        var oracleSamples: [Double] = []
        var lastMeasurement: ReconstructionMeasurement?

        let totalIterations = fixture.warmups + fixture.iterations
        for iteration in 0..<totalIterations {
            let productionElapsed = try Self.milliseconds {
                _ = try builder.build(
                    workouts: workouts,
                    configuration: configuration,
                    isCancelled: { false }
                )
            }

            let measurement = try Self.profiledBuild(
                workouts: workouts,
                configuration: configuration
            )

            XCTAssertEqual(
                measurement.snapshot,
                productionReference,
                "\(fixture.key): profiled reconstruction diverged from PersonalHeatmapBuilder"
            )
            XCTAssertEqual(
                measurement.snapshot,
                oracleSnapshot,
                "\(fixture.key): profiled reconstruction diverged from SwiftPersonalHeatmapBuilderOracle"
            )

            let oracleElapsed = fixture.isPrimary
                ? try Self.milliseconds {
                    _ = try oracle.build(workouts: workouts, configuration: configuration)
                }
                : 0

            guard iteration >= fixture.warmups else { continue }
            productionSamples.append(productionElapsed)
            reconstructionSamples.append(Self.ms(measurement.wallClockNanoseconds))
            if fixture.isPrimary { oracleSamples.append(oracleElapsed) }
            lastMeasurement = measurement
        }

        guard let measurement = lastMeasurement else {
            XCTFail("\(fixture.key): no measured iteration recorded")
            return FixtureOutcome(
                matrixRow: "",
                phaseMillisecondRow: "",
                phasePercentRow: "",
                detailSection: []
            )
        }

        let productionMedian = Self.median(productionSamples)
        let reconstructionMedian = Self.median(reconstructionSamples)
        let overheadRatio = reconstructionMedian / max(productionMedian, 1e-12)
        let accounted = measurement.accountedNanoseconds
        let unaccounted = Double(measurement.wallClockNanoseconds) - Double(accounted)
        let unaccountedPercent = 100 * unaccounted / max(Double(measurement.wallClockNanoseconds), 1)
        // Requirement 2.4: phase attribution is only trustworthy when the
        // unaccounted residue is within 5% of the profiled wall clock.
        let attributionIsTrustworthy = unaccountedPercent <= Self.maximumUnaccountedPercent

        let matrixRow = "| \(fixture.key) \(fixture.name) "
            + "| \(measurement.inputWorkoutCount) "
            + "| \(measurement.totalRoutePointCount) "
            + "| \(Self.format(configuration.cellSizeMeters)) m "
            + "| \(measurement.snapshot.diagnostics.adaptiveResolutionRetries) "
            + "| \(Self.format(measurement.snapshot.diagnostics.effectiveCellSizeMeters)) m "
            + "| \(measurement.snapshot.diagnostics.aggregatedCellCount) "
            + "| \(measurement.snapshot.diagnostics.renderedCellCount) "
            + "| \(Self.format(productionMedian)) ms "
            + "| \(Self.format(reconstructionMedian)) ms "
            + "| \(String(format: "%.2f", overheadRatio))× "
            + "| \(String(format: "%.2f", unaccountedPercent))% |"

        let wall = Double(measurement.wallClockNanoseconds)
        let phaseNanoseconds: [UInt64] = [
            measurement.dateFilterNanoseconds,
            measurement.preparationNanoseconds,
            measurement.totalCoverageBridgeNanoseconds,
            measurement.totalNativeNanoseconds,
            measurement.totalAllocationNanoseconds,
            measurement.totalTranslationNanoseconds,
            measurement.totalCountInsertionNanoseconds,
            measurement.totalFilterNanoseconds,
            measurement.totalAdaptiveDecisionNanoseconds,
            measurement.sortNanoseconds,
            measurement.materializationNanoseconds,
            measurement.snapshotAssemblyNanoseconds
        ]

        // Publish phase tables only when attribution is trustworthy. Mode A/B
        // medians, parity, and the unaccounted percentage still always report.
        let phaseMillisecondRow: String
        let phasePercentRow: String
        if attributionIsTrustworthy {
            phaseMillisecondRow = "| \(fixture.key) "
                + phaseNanoseconds.map { "| \(Self.format(Self.ms($0))) " }.joined()
                + "| \(Self.format(unaccounted / 1_000_000)) "
                + "| \(Self.format(Self.ms(measurement.wallClockNanoseconds))) |"
            phasePercentRow = "| \(fixture.key) "
                + phaseNanoseconds
                    .map { "| \(String(format: "%.2f", 100 * Double($0) / max(wall, 1))) " }
                    .joined()
                + "| \(String(format: "%.2f", unaccountedPercent)) |"
        } else {
            phaseMillisecondRow = "| \(fixture.key) | — | — | — | — | — | — | — | — | — | — | — | — | attribution suppressed (unaccounted \(String(format: "%.2f", unaccountedPercent))% > \(Self.format(Self.maximumUnaccountedPercent))%) | — |"
            phasePercentRow = "| \(fixture.key) | — | — | — | — | — | — | — | — | — | — | — | — | attribution suppressed |"
            XCTFail(
                "\(fixture.key): unaccounted phase residue is \(String(format: "%.2f", unaccountedPercent))% of the profiled wall clock (limit \(Self.format(Self.maximumUnaccountedPercent))%). Phase attribution tables are suppressed."
            )
        }

        var detail: [String] = []
        detail.append("### Primary fixture detail — \(fixture.key) \(fixture.name)")
        detail.append("")
        detail.append("- input workouts: `\(measurement.inputWorkoutCount)`")
        detail.append("- route points: `\(measurement.totalRoutePointCount)`")
        detail.append("- native samples prepared: `\(measurement.nativeSampleCount)`")
        detail.append("- eligible workouts: `\(measurement.eligibleWorkoutCount)`")
        detail.append("- excluded undated: `\(measurement.excludedUndatedCount)`")
        detail.append("- adaptive retries: `\(measurement.snapshot.diagnostics.adaptiveResolutionRetries)`")
        detail.append("- effective cell size: `\(Self.format(measurement.snapshot.diagnostics.effectiveCellSizeMeters))` m")
        detail.append("- aggregated cells (final pass): `\(measurement.snapshot.diagnostics.aggregatedCellCount)`")
        detail.append("- rendered cells: `\(measurement.snapshot.diagnostics.renderedCellCount)`")
        detail.append("")
        detail.append("#### Authoritative totals (\(fixture.warmups) warm-ups + \(fixture.iterations) measured)")
        detail.append("")
        detail.append("| Measurement | Median | Min | p90 | Max |")
        detail.append("|---|---:|---:|---:|---:|")
        detail.append(Self.statsRow("Mode A production builder", productionSamples))
        if !oracleSamples.isEmpty {
            detail.append(Self.statsRow("Swift builder oracle", oracleSamples))
        }
        detail.append(Self.statsRow("Mode B profiled reconstruction", reconstructionSamples))
        detail.append("")
        detail.append("- profiling overhead (Mode B / Mode A): `\(String(format: "%.3f", overheadRatio))×` (target ≤ 1.15×)")
        detail.append("")
        detail.append("- sum of measured phases: `\(Self.format(Self.ms(accounted)))` ms")
        detail.append("- profiled wall-clock total: `\(Self.format(Self.ms(measurement.wallClockNanoseconds)))` ms")
        detail.append("- difference: `\(Self.format(unaccounted / 1_000_000))` ms (`\(String(format: "%.2f", unaccountedPercent))%`, limit \(Self.format(Self.maximumUnaccountedPercent))%)")
        detail.append("")

        if attributionIsTrustworthy {
            detail.append("#### Additive phase breakdown (last measured Mode B iteration)")
            detail.append("")
            detail.append("Rows marked *of which* are nested inside the coverage bridge row and are not summed again.")
            detail.append("")
            detail.append("| Phase | Median | Percent |")
            detail.append("|---|---:|---:|")

            func phaseRow(_ label: String, _ nanos: UInt64) -> String {
                let ms = Self.ms(nanos)
                let percent = 100 * Double(nanos) / max(wall, 1)
                return "| \(label) | \(Self.format(ms)) ms | \(String(format: "%.2f", percent))% |"
            }

            detail.append(phaseRow("Date filtering", measurement.dateFilterNanoseconds))
            detail.append(phaseRow("Native preparation", measurement.preparationNanoseconds))
            detail.append(phaseRow("Coverage bridge across all passes", measurement.totalCoverageBridgeNanoseconds))
            detail.append(phaseRow("— of which native C++ execution", measurement.totalNativeNanoseconds))
            detail.append(phaseRow("— of which output allocation / retries", measurement.totalAllocationNanoseconds))
            detail.append(phaseRow("— of which C++ → Swift cell translation", measurement.totalTranslationNanoseconds))
            detail.append(phaseRow("Cross-workout counting", measurement.totalCountInsertionNanoseconds))
            detail.append(phaseRow("Minimum-repeat filtering", measurement.totalFilterNanoseconds))
            detail.append(phaseRow("Adaptive decision", measurement.totalAdaptiveDecisionNanoseconds))
            detail.append(phaseRow("Sorting", measurement.sortNanoseconds))
            detail.append(phaseRow("Bounds / intensity / cells", measurement.materializationNanoseconds))
            detail.append(phaseRow("Snapshot assembly", measurement.snapshotAssemblyNanoseconds))
            detail.append("| Unaccounted | \(Self.format(unaccounted / 1_000_000)) ms | \(String(format: "%.2f", unaccountedPercent))% |")
            detail.append("| **Profiled wall-clock total** | **\(Self.format(Self.ms(measurement.wallClockNanoseconds))) ms** | **100.00%** |")
            detail.append("")
            detail.append("#### Per adaptive pass")
            detail.append("")
            detail.append("| Pass | Cell size | Eligible | With coverage | Without | Cells returned | Invalid intervals | Aggregated | Passing filter | Dict updates | Coverage bridge | Native | Alloc | Translate | Counting | Filter | Decision | Pass total | Capacity retries |")
            detail.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
            for pass in measurement.passes {
                detail.append(
                    "| \(pass.index) "
                    + "| \(Self.format(pass.cellSizeMeters)) m "
                    + "| \(pass.eligibleWorkouts) "
                    + "| \(pass.workoutsWithCoverage) "
                    + "| \(pass.workoutsWithoutCoverage) "
                    + "| \(pass.coverageCellsReturned) "
                    + "| \(pass.invalidIntervals) "
                    + "| \(pass.aggregatedUniqueCells) "
                    + "| \(pass.cellsPassingMinimumFilter) "
                    + "| \(pass.dictionaryUpdates) "
                    + "| \(Self.format(Self.ms(pass.coverageBridgeNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.nativeNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.allocationNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.translationNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.countInsertionNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.filterNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.adaptiveDecisionNanoseconds))) "
                    + "| \(Self.format(Self.ms(pass.totalNanoseconds))) "
                    + "| \(pass.capacityRetries) |"
                )
            }
            detail.append("")
            detail.append("All milliseconds. Native / Alloc / Translate are nested inside Coverage bridge.")
            detail.append("")
        } else {
            detail.append("#### Additive phase breakdown")
            detail.append("")
            detail.append("**Suppressed.** Unaccounted residue exceeded \(Self.format(Self.maximumUnaccountedPercent))% of the profiled wall clock, so phase attribution tables are not published (requirement 2.4).")
            detail.append("")
        }

        detail.append("#### Memory")
        detail.append("")
        detail.append("- peak resident (task max): `\(Self.bytes(measurement.peakResidentBytes))`")
        detail.append("- resident after native preparation: `\(Self.bytes(measurement.residentAfterPreparation))`")
        detail.append("- resident after largest adaptive pass: `\(Self.bytes(measurement.residentAfterLargestPass))`")
        detail.append("- resident after final snapshot: `\(Self.bytes(measurement.residentAfterSnapshot))`")
        detail.append("- largest prepared native batch: `\(measurement.nativeSampleCount)` samples ≈ `\(measurement.nativeBatchBytes)` bytes")
        detail.append("- largest aggregated dictionary: `\(measurement.largestAggregatedCellCount)` entries")
        detail.append("- largest rendered-cell array: `\(measurement.snapshot.cells.count)` cells")
        detail.append("- cell-bound inverse-projection failures: `\(measurement.boundsFailures)`")
        detail.append("")

        return FixtureOutcome(
            matrixRow: matrixRow,
            phaseMillisecondRow: phaseMillisecondRow,
            phasePercentRow: phasePercentRow,
            detailSection: detail
        )
    }

    // MARK: - Mode B: profiled reconstruction

    /// Per-adaptive-pass measurements.
    private struct PassMeasurement {
        let index: Int
        let cellSizeMeters: Double
        let eligibleWorkouts: Int
        let workoutsWithCoverage: Int
        let workoutsWithoutCoverage: Int
        let coverageCellsReturned: Int
        let invalidIntervals: Int
        let aggregatedUniqueCells: Int
        let cellsPassingMinimumFilter: Int
        let dictionaryUpdates: Int
        let coverageBridgeNanoseconds: UInt64
        let nativeNanoseconds: UInt64
        let allocationNanoseconds: UInt64
        let translationNanoseconds: UInt64
        let countInsertionNanoseconds: UInt64
        let filterNanoseconds: UInt64
        let adaptiveDecisionNanoseconds: UInt64
        let totalNanoseconds: UInt64
        let capacityRetries: Int
        let residentBytesAfterPass: UInt64?
    }

    private struct ReconstructionMeasurement {
        let snapshot: PersonalHeatmapSnapshot
        let wallClockNanoseconds: UInt64

        let dateFilterNanoseconds: UInt64
        let inputWorkoutCount: Int
        let eligibleWorkoutCount: Int
        let excludedUndatedCount: Int

        let preparationNanoseconds: UInt64
        let totalRoutePointCount: Int
        let nativeSampleCount: Int
        let residentAfterPreparation: UInt64?

        let passes: [PassMeasurement]

        let sortNanoseconds: UInt64
        let materializationNanoseconds: UInt64
        let boundsFailures: Int
        let snapshotAssemblyNanoseconds: UInt64

        let residentAfterSnapshot: UInt64?
        let peakResidentBytes: UInt64?
        let largestAggregatedCellCount: Int
        let nativeBatchBytes: Int

        var totalCoverageBridgeNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.coverageBridgeNanoseconds } }
        var totalNativeNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.nativeNanoseconds } }
        var totalAllocationNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.allocationNanoseconds } }
        var totalTranslationNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.translationNanoseconds } }
        var totalCountInsertionNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.countInsertionNanoseconds } }
        var totalFilterNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.filterNanoseconds } }
        var totalAdaptiveDecisionNanoseconds: UInt64 { passes.reduce(0) { $0 + $1.adaptiveDecisionNanoseconds } }

        /// Sum of the additive top-level phases. Intra-pass loop overhead and
        /// configuration validation fall outside this and land in `Unaccounted`.
        var accountedNanoseconds: UInt64 {
            dateFilterNanoseconds
                + preparationNanoseconds
                + totalCoverageBridgeNanoseconds
                + totalCountInsertionNanoseconds
                + totalFilterNanoseconds
                + totalAdaptiveDecisionNanoseconds
                + sortNanoseconds
                + materializationNanoseconds
                + snapshotAssemblyNanoseconds
        }

        var residentAfterLargestPass: UInt64? {
            passes
                .compactMap(\.residentBytesAfterPass)
                .max()
        }
    }

    /// Test-only reconstruction of `PersonalHeatmapBuilder.build`.
    ///
    /// Mirrors production semantics statement for statement: one date filter,
    /// one prepared native batch reused across every adaptive pass, per-workout
    /// coverage, unfiltered global counts, the minimum-repeat filter, the
    /// coarsening decision, then sort / materialize / assemble exactly once.
    private static func profiledBuild(
        workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration
    ) throws -> ReconstructionMeasurement {
        let wallStart = ContinuousClock.now

        guard configuration.cellSizeMeters.isFinite,
              configuration.cellSizeMeters > 0,
              configuration.minimumWorkoutCount >= 1,
              configuration.maximumRenderedCellCount >= 1,
              configuration.maximumIntervalMeters.isFinite,
              configuration.maximumIntervalMeters > 0 else {
            throw PersonalHeatmapError.invalidConfiguration
        }

        // Phase 1: date filtering.
        let dateFilterStart = ContinuousClock.now
        var eligible: [RunWorkout] = []
        eligible.reserveCapacity(workouts.count)
        var excludedUndated = 0
        for workout in workouts {
            let date = workout.metadata.startDate ?? workout.routePoints.first?.timestamp
            switch configuration.dateFilter {
            case .allTime:
                break
            case .range(let start, let end):
                guard let date else {
                    excludedUndated += 1
                    continue
                }
                if date < start || date > end { continue }
            }
            eligible.append(workout)
        }
        let dateFilterNanoseconds = nanoseconds(from: dateFilterStart, to: ContinuousClock.now)

        // Phase 2: native route preparation (exactly one batch).
        let routes = eligible.map { $0.routePoints }
        let totalRoutePointCount = routes.reduce(0) { $0 + $1.count }
        let preparationStart = ContinuousClock.now
        let preparedBatch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: routes,
            isCancelled: { false }
        )
        let preparationNanoseconds = nanoseconds(from: preparationStart, to: ContinuousClock.now)
        let residentAfterPreparation = currentResidentBytes()

        // Phase 3: adaptive resolution passes.
        var passes: [PassMeasurement] = []
        var cellSize = configuration.cellSizeMeters
        var adaptiveRetries = 0
        let maxRetries = 16
        var largestAggregatedCellCount = 0

        var finalCounts: [PersonalHeatmapCellID: Int] = [:]
        var finalFilteredCounts: [PersonalHeatmapCellID: Int] = [:]
        var finalIncludedWorkoutCount = 0
        var finalTotalDistanceMeters = 0.0
        var finalInvalidIntervals = 0

        while true {
            let passStart = ContinuousClock.now
            var counts: [PersonalHeatmapCellID: Int] = [:]
            var invalidIntervals = 0
            var includedWorkoutCount = 0
            var totalDistanceMeters = 0.0

            var coverageBridgeNanoseconds: UInt64 = 0
            var countInsertionNanoseconds: UInt64 = 0
            var nativeNanoseconds: UInt64 = 0
            var allocationNanoseconds: UInt64 = 0
            var translationNanoseconds: UInt64 = 0
            var capacityRetries = 0
            var coverageCellsReturned = 0
            var dictionaryUpdates = 0
            var workoutsWithoutCoverage = 0

            for (index, workout) in eligible.enumerated() {
                let coverageStart = ContinuousClock.now
                let result = try preparedBatch.profiledCoverage(
                    workoutIndex: index,
                    cellSizeMeters: cellSize,
                    maximumIntervalMeters: configuration.maximumIntervalMeters,
                    maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                    isCancelled: { false }
                )
                coverageBridgeNanoseconds += nanoseconds(from: coverageStart, to: ContinuousClock.now)

                nativeNanoseconds += result.profile.nativeNanoseconds
                allocationNanoseconds += result.profile.outputAllocationNanoseconds
                translationNanoseconds += result.profile.translationNanoseconds
                capacityRetries += result.profile.capacityRetryCount

                let coverage = result.coverage
                if coverage.cells.isEmpty {
                    workoutsWithoutCoverage += 1
                    continue
                }

                includedWorkoutCount += 1
                let distance = workout.summary.totalDistanceMeters
                totalDistanceMeters += (distance.isFinite && distance >= 0 ? distance : 0)
                invalidIntervals += coverage.invalidIntervalCount
                coverageCellsReturned += coverage.cells.count

                // Phase 6: cross-workout counting, isolated from the bridge call.
                let countStart = ContinuousClock.now
                for cell in coverage.cells {
                    counts[cell, default: 0] += 1
                }
                countInsertionNanoseconds += nanoseconds(from: countStart, to: ContinuousClock.now)
                dictionaryUpdates += coverage.cells.count
            }

            // Phase 7: minimum-repeat filtering.
            let filterStart = ContinuousClock.now
            let filteredCounts = counts.filter { $0.value >= configuration.minimumWorkoutCount }
            let filterNanoseconds = nanoseconds(from: filterStart, to: ContinuousClock.now)

            let decisionStart = ContinuousClock.now
            let budgetSatisfied = filteredCounts.count <= configuration.maximumRenderedCellCount
                || adaptiveRetries >= maxRetries
            let adaptiveDecisionNanoseconds = nanoseconds(from: decisionStart, to: ContinuousClock.now)

            let passTotalNanoseconds = nanoseconds(from: passStart, to: ContinuousClock.now)
            largestAggregatedCellCount = max(largestAggregatedCellCount, counts.count)

            passes.append(PassMeasurement(
                index: passes.count,
                cellSizeMeters: cellSize,
                eligibleWorkouts: eligible.count,
                workoutsWithCoverage: includedWorkoutCount,
                workoutsWithoutCoverage: workoutsWithoutCoverage,
                coverageCellsReturned: coverageCellsReturned,
                invalidIntervals: invalidIntervals,
                aggregatedUniqueCells: counts.count,
                cellsPassingMinimumFilter: filteredCounts.count,
                dictionaryUpdates: dictionaryUpdates,
                coverageBridgeNanoseconds: coverageBridgeNanoseconds,
                nativeNanoseconds: nativeNanoseconds,
                allocationNanoseconds: allocationNanoseconds,
                translationNanoseconds: translationNanoseconds,
                countInsertionNanoseconds: countInsertionNanoseconds,
                filterNanoseconds: filterNanoseconds,
                adaptiveDecisionNanoseconds: adaptiveDecisionNanoseconds,
                totalNanoseconds: passTotalNanoseconds,
                capacityRetries: capacityRetries,
                residentBytesAfterPass: currentResidentBytes()
            ))

            if budgetSatisfied {
                finalCounts = counts
                finalFilteredCounts = filteredCounts
                finalIncludedWorkoutCount = includedWorkoutCount
                finalTotalDistanceMeters = totalDistanceMeters
                finalInvalidIntervals = invalidIntervals
                break
            }

            adaptiveRetries += 1
            cellSize *= 2
        }

        // Phase 8: deterministic sorting.
        let sortStart = ContinuousClock.now
        let sortedIDs = finalFilteredCounts.keys.sorted()
        let sortNanoseconds = nanoseconds(from: sortStart, to: ContinuousClock.now)

        // Phase 9: cell materialization (max overlap, bounds, intensity, cells).
        let materializationStart = ContinuousClock.now
        let maximumOverlap = finalCounts.values.max() ?? 0
        let intensityDenominator = log1p(Double(max(maximumOverlap, 1)))

        var cells: [PersonalHeatmapCell] = []
        cells.reserveCapacity(finalFilteredCounts.count)
        var boundsFailures = 0

        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity

        for id in sortedIDs {
            guard let workoutCount = finalFilteredCounts[id],
                  let bounds = PersonalHeatmapProjection.cellBounds(id: id, cellSizeMeters: cellSize) else {
                boundsFailures += 1
                continue
            }
            let intensity: Double
            if maximumOverlap <= 0 {
                intensity = 0
            } else {
                intensity = log1p(Double(workoutCount)) / intensityDenominator
            }
            let clampedIntensity = min(max(intensity, 0), 1)

            cells.append(PersonalHeatmapCell(
                id: id,
                workoutCount: workoutCount,
                normalizedIntensity: clampedIntensity,
                bounds: bounds
            ))

            minLat = min(minLat, bounds.minLatitude)
            maxLat = max(maxLat, bounds.maxLatitude)
            minLon = min(minLon, bounds.minLongitude)
            maxLon = max(maxLon, bounds.maxLongitude)
        }

        let heatmapBounds: PersonalHeatmapBounds? = cells.isEmpty
            ? nil
            : PersonalHeatmapBounds(
                minLatitude: minLat,
                maxLatitude: maxLat,
                minLongitude: minLon,
                maxLongitude: maxLon
            )
        let materializationNanoseconds = nanoseconds(from: materializationStart, to: ContinuousClock.now)

        // Phase 10: statistics, diagnostics, effective configuration, snapshot.
        let assemblyStart = ContinuousClock.now
        let effectiveConfiguration = PersonalHeatmapConfiguration(
            dateFilter: configuration.dateFilter,
            cellSizeMeters: cellSize,
            minimumWorkoutCount: configuration.minimumWorkoutCount,
            maximumRenderedCellCount: configuration.maximumRenderedCellCount,
            maximumIntervalMeters: configuration.maximumIntervalMeters
        )

        let statistics = PersonalHeatmapStatistics(
            includedWorkoutCount: finalIncludedWorkoutCount,
            totalDistanceMeters: finalTotalDistanceMeters,
            maximumOverlap: maximumOverlap,
            requestedCellSizeMeters: configuration.cellSizeMeters,
            effectiveCellSizeMeters: cellSize,
            resolutionWasAdjusted: adaptiveRetries > 0,
            excludedUndatedWorkoutCount: excludedUndated,
            excludedNoRouteWorkoutCount: eligible.count - finalIncludedWorkoutCount
        )

        let diagnostics = PersonalHeatmapDiagnostics(
            totalCandidateWorkouts: workouts.count,
            includedWorkouts: finalIncludedWorkoutCount,
            excludedUndatedWorkouts: excludedUndated,
            excludedNoRouteWorkouts: eligible.count - finalIncludedWorkoutCount,
            invalidRouteIntervalsSkipped: finalInvalidIntervals,
            adaptiveResolutionRetries: adaptiveRetries,
            requestedCellSizeMeters: configuration.cellSizeMeters,
            effectiveCellSizeMeters: cellSize,
            aggregatedCellCount: finalCounts.count,
            renderedCellCount: cells.count
        )

        let snapshot = PersonalHeatmapSnapshot(
            cells: cells,
            statistics: statistics,
            diagnostics: diagnostics,
            configuration: effectiveConfiguration,
            bounds: heatmapBounds
        )
        let snapshotAssemblyNanoseconds = nanoseconds(from: assemblyStart, to: ContinuousClock.now)

        let wallClockNanoseconds = nanoseconds(from: wallStart, to: ContinuousClock.now)

        return ReconstructionMeasurement(
            snapshot: snapshot,
            wallClockNanoseconds: wallClockNanoseconds,
            dateFilterNanoseconds: dateFilterNanoseconds,
            inputWorkoutCount: workouts.count,
            eligibleWorkoutCount: eligible.count,
            excludedUndatedCount: excludedUndated,
            preparationNanoseconds: preparationNanoseconds,
            totalRoutePointCount: totalRoutePointCount,
            nativeSampleCount: totalRoutePointCount,
            residentAfterPreparation: residentAfterPreparation,
            passes: passes,
            sortNanoseconds: sortNanoseconds,
            materializationNanoseconds: materializationNanoseconds,
            boundsFailures: boundsFailures,
            snapshotAssemblyNanoseconds: snapshotAssemblyNanoseconds,
            residentAfterSnapshot: currentResidentBytes(),
            peakResidentBytes: peakResidentBytes(),
            largestAggregatedCellCount: largestAggregatedCellCount,
            nativeBatchBytes: totalRoutePointCount * 24
        )
    }

    // MARK: - Fixtures

    private enum CorridorStyle {
        /// Benchmark-compatible 10-by-N grid of start points: moderate overlap.
        case moderateOverlap
        /// Nearly every workout on one shared corridor.
        case sharedCorridor
        /// Every workout on a geographically separate corridor.
        case separatedCorridors
    }

    private struct Fixture {
        let key: String
        let name: String
        let workoutCount: Int
        let pointsPerWorkout: Int
        let style: CorridorStyle
        let configuration: PersonalHeatmapConfiguration
        let warmups: Int
        let iterations: Int
        let isPrimary: Bool
    }

    /// Generous budget: never triggers adaptive coarsening for these fixtures.
    private static let unboundedRenderBudget = 100_000_000

    private static func fixtures() -> [Fixture] {
        [
            Fixture(
                key: "A",
                name: "representative adaptive build",
                workoutCount: 250,
                pointsPerWorkout: 1_000,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 5,
                    maximumRenderedCellCount: 500
                ),
                warmups: 5,
                iterations: 20,
                isPrimary: true
            ),
            Fixture(
                key: "B",
                name: "high-overlap library",
                workoutCount: 500,
                pointsPerWorkout: 500,
                style: .sharedCorridor,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 25,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "C",
                name: "low-overlap library",
                workoutCount: 250,
                pointsPerWorkout: 1_000,
                style: .separatedCorridors,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 25,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "D",
                name: "many tiny workouts",
                workoutCount: 5_000,
                pointsPerWorkout: 20,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 25,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "E",
                name: "few large workouts",
                workoutCount: 10,
                pointsPerWorkout: 25_000,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 25,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "F",
                name: "no adaptive retry",
                workoutCount: 250,
                pointsPerWorkout: 1_000,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 200,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "G",
                name: "repeated adaptive coarsening",
                workoutCount: 250,
                pointsPerWorkout: 1_000,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 5,
                    maximumRenderedCellCount: 100
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            ),
            Fixture(
                key: "H",
                name: "higher minimum-repeat filter",
                workoutCount: 250,
                pointsPerWorkout: 1_000,
                style: .moderateOverlap,
                configuration: PersonalHeatmapConfiguration(
                    cellSizeMeters: 25,
                    minimumWorkoutCount: 3,
                    maximumRenderedCellCount: unboundedRenderBudget
                ),
                warmups: 3,
                iterations: 10,
                isPrimary: false
            )
        ]
    }

    /// Libraries are cached by shape so fixtures A, F, G, and H share one
    /// generated library and differ only in configuration. Instance state, not
    /// global state, so Swift 6 concurrency checking stays satisfied.
    private var libraryCache: [String: [RunWorkout]] = [:]

    private func library(for fixture: Fixture) -> [RunWorkout] {
        let key = "\(fixture.workoutCount)-\(fixture.pointsPerWorkout)-\(fixture.style)"
        if let cached = libraryCache[key] { return cached }
        let generated = Self.makeLibrary(
            count: fixture.workoutCount,
            pointsPerWorkout: fixture.pointsPerWorkout,
            style: fixture.style
        )
        libraryCache[key] = generated
        return generated
    }

    /// Deterministic synthetic library. No private data, no `Date()`.
    ///
    /// Anomaly positions are proportional so every fixture shape exercises the
    /// invalid-coordinate, oversized-interval, and rejected-interval paths. At
    /// 1,000 points per workout the positions reduce to the historical
    /// benchmark's 100 / 300 / every-250 layout, keeping fixture A comparable
    /// with `PersonalHeatmapCoverageBenchmark`.
    private static func makeLibrary(
        count: Int,
        pointsPerWorkout: Int,
        style: CorridorStyle
    ) -> [RunWorkout] {
        var workouts: [RunWorkout] = []
        workouts.reserveCapacity(count)

        let baseDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let invalidPointIndex = max(1, pointsPerWorkout / 10)
        let oversizedPointIndex = max(2, pointsPerWorkout * 3 / 10)
        let rejectedPointIndex = max(3, pointsPerWorkout * 6 / 10)
        let segmentStride = max(1, pointsPerWorkout / 4)

        // Oversized-but-still-rasterized jump. Long routes keep the historical
        // benchmark's 0.1° (~11 km) excursion so fixture A stays comparable
        // with it. Short routes scale the jump down: on a 20-point workout a
        // single 11 km teleport rasterizes far more cells than the whole real
        // route and would hide the per-workout call overhead that fixture D
        // exists to measure.
        let oversizedJumpDegrees = pointsPerWorkout >= 100 ? 0.1 : 0.002

        // Excursion long enough (~111 km) to exceed the default 50 km interval
        // ceiling, so the engine's invalid-interval rejection and its
        // diagnostic counter are exercised. The route steps straight back, so
        // this contributes one stray cell rather than a second corridor.
        let rejectedJumpDegrees = 1.0

        for w in 0..<count {
            var points: [RoutePoint] = []
            points.reserveCapacity(pointsPerWorkout)

            var lat: Double
            var lon: Double
            switch style {
            case .moderateOverlap:
                lat = 37.7749 + Double(w % 10) * 0.005
                lon = -122.4194 + Double(w / 10) * 0.005
            case .sharedCorridor:
                lat = 37.7749 + Double(w % 3) * 0.000_05
                lon = -122.4194
            case .separatedCorridors:
                lat = 37.7749 + Double(w) * 0.02
                lon = -122.4194 + Double(w) * 0.02
            }

            var segment = 0
            for p in 0..<pointsPerWorkout {
                if p > 0 && p % segmentStride == 0 {
                    segment += 1
                }

                if p == invalidPointIndex {
                    points.append(RoutePoint(
                        timestamp: baseDate.addingTimeInterval(Double(p)),
                        latitude: 200.0,
                        longitude: lon,
                        routeSegmentIndex: segment
                    ))
                    continue
                }

                if p == oversizedPointIndex {
                    lat += oversizedJumpDegrees
                } else if p == rejectedPointIndex {
                    lat += rejectedJumpDegrees
                } else if p == rejectedPointIndex + 1 {
                    lat -= rejectedJumpDegrees
                } else {
                    lat += 0.00005 * (p % 2 == 0 ? 1.0 : -0.5)
                    lon += 0.00005 * (p % 3 == 0 ? 1.0 : -0.2)
                }

                points.append(RoutePoint(
                    timestamp: baseDate.addingTimeInterval(Double(p)),
                    latitude: lat,
                    longitude: lon,
                    routeSegmentIndex: segment
                ))
            }

            workouts.append(RunWorkout(
                metadata: WorkoutMetadata(startDate: baseDate.addingTimeInterval(Double(w * 3600))),
                routePoints: points,
                summary: RunSummary(totalDistanceMeters: Double(pointsPerWorkout) * 5.0)
            ))
        }

        return workouts
    }

    // MARK: - Timing and formatting helpers

    private static func nanoseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return nanoseconds > 0 ? UInt64(nanoseconds) : 0
    }

    private static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        return ms(nanoseconds(from: start, to: ContinuousClock.now))
    }

    private static func ms(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func statsRow(_ label: String, _ values: [Double]) -> String {
        "| \(label) "
            + "| \(format(median(values))) ms "
            + "| \(format(values.min() ?? 0)) ms "
            + "| \(format(percentile(values, 0.9))) ms "
            + "| \(format(values.max() ?? 0)) ms |"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "unavailable" }
        return "\(value) bytes (\(String(format: "%.1f", Double(value) / 1_048_576)) MiB)"
    }

    // MARK: - Memory helpers

    #if canImport(Darwin)
    private static func taskBasicInfo() -> mach_task_basic_info? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }
    #endif

    private static func currentResidentBytes() -> UInt64? {
        #if canImport(Darwin)
        return taskBasicInfo()?.resident_size
        #else
        return nil
        #endif
    }

    /// Task-wide maximum resident size. Reported, never asserted: RSS is
    /// process-wide and includes the whole test bundle.
    private static func peakResidentBytes() -> UInt64? {
        #if canImport(Darwin)
        return taskBasicInfo()?.resident_size_max
        #else
        return nil
        #endif
    }
}
