import XCTest
import Foundation
@testable import RunPlayCore

/// Release-mode remaining-core hotspot profiler.
///
/// Skipped unless `RUNPLAY_CORE_HOTSPOT_PROFILE=1`. Each family is an independent
/// XCTest method so filtering works without double execution. There is no
/// `testAllFamilies` aggregator.
final class RemainingCoreHotspotProfile: XCTestCase {

    private static let maxUnaccountedFraction = 0.05
    private static let maxOverheadRatio = 1.15

    // MARK: - Family A

    func testFamilyA_AnalysisProfile() throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard ProfileFamily.selected.contains(.analysis) else { return }
        ProfileFamilyInvocationCounter.record(.analysis)
        XCTAssertEqual(
            ProfileFamilyInvocationCounter.count(for: .analysis),
            1,
            "analysis family must execute exactly once"
        )

        print("\n<!-- BEGIN RUNPLAY CORE HOTSPOT PROFILE FAMILY A -->")
        print("\n# Family A — Workout analysis\n")

        try profileAnalyzeFixture(label: "A1 ordinary 5k", workout: HotspotProfilingFixtures.a1(), size: .standard)
        try profileAnalyzeFixture(label: "A2 long dense", workout: HotspotProfilingFixtures.a2(), size: .large)
        try profileAnalyzeFixture(label: "A3 many segments", workout: HotspotProfilingFixtures.a3(), size: .large)
        try profileAnalyzeFixture(label: "A4 intermittent", workout: HotspotProfilingFixtures.a4(), size: .standard)
        try profileAnalyzeFixture(label: "A5 altitude-heavy", workout: HotspotProfilingFixtures.a5(), size: .standard)
        try profileAnalyzeFixture(label: "A6 recorded-lap-heavy", workout: HotspotProfilingFixtures.a6(), size: .standard)

        if profileProductLimitEnabled {
            try profileAnalyzeFixture(
                label: "A7 product limit",
                workout: HotspotProfilingFixtures.a7(),
                size: .productLimit,
                memory: true
            )
        } else {
            print("\n_A7 product-limit probe skipped (set RUNPLAY_PROFILE_PRODUCT_LIMIT=1)._\n")
        }

        print("\n<!-- END RUNPLAY CORE HOTSPOT PROFILE FAMILY A -->\n")
    }

    private func profileAnalyzeFixture(
        label: String,
        workout: RunWorkout,
        size: ProfileFixtureSize,
        memory: Bool = false
    ) throws {
        let analyzer = WorkoutAnalyzer()

        // Mode A: production analyze
        let modeA = measureStatisticsWithResult(size: size) {
            var w = workout
            analyzer.analyze(&w)
            return w
        }
        let digestA = HotspotProfilingDigests.workoutDigest(modeA.last)

        // Mode B: profiled shared implementation
        var lastProfile = WorkoutAnalysisPhaseProfile()
        let modeB = measureStatisticsWithResult(size: size) {
            var w = workout
            lastProfile = analyzer.analyzeCollectingProfile(&w)
            return w
        }
        let digestB = HotspotProfilingDigests.workoutDigest(modeB.last)
        XCTAssertEqual(digestA, digestB, "\(label): Mode A/B analyze digest mismatch")

        // normalizeAndAnalyze Mode A/B on a fresh copy of the same route.
        let modeANorm = try measureStatisticsWithResult(size: size) {
            var w = workout
            try analyzer.normalizeAndAnalyze(
                &w,
                distancePolicy: .useSuppliedDistancesWhenValid
            )
            return w
        }
        let digestAN = HotspotProfilingDigests.workoutDigest(modeANorm.last)

        var lastNormProfile = WorkoutAnalysisPhaseProfile()
        let modeBNorm = try measureStatisticsWithResult(size: size) {
            var w = workout
            lastNormProfile = try analyzer.normalizeAndAnalyzeCollectingProfile(
                &w,
                distancePolicy: .useSuppliedDistancesWhenValid
            )
            return w
        }
        let digestBN = HotspotProfilingDigests.workoutDigest(modeBNorm.last)
        XCTAssertEqual(digestAN, digestBN, "\(label): Mode A/B normalizeAndAnalyze digest mismatch")

        let overhead = modeB.stats.medianMilliseconds / max(modeA.stats.medianMilliseconds, 1e-9)
        let accounting = ProfileAccounting.make(
            wallMs: HotspotTestClock.ms(lastProfile.wallNanoseconds),
            measuredMs: HotspotTestClock.ms(lastProfile.accountedNanoseconds)
        )
        let normAccounting = ProfileAccounting.make(
            wallMs: HotspotTestClock.ms(lastNormProfile.wallNanoseconds),
            measuredMs: HotspotTestClock.ms(lastNormProfile.accountedNanoseconds)
        )

        XCTAssertLessThanOrEqual(
            abs(accounting.unaccountedFraction),
            Self.maxUnaccountedFraction,
            "\(label) analyze accounting residue \(accounting.unaccountedFraction)"
        )
        XCTAssertLessThanOrEqual(
            abs(normAccounting.unaccountedFraction),
            Self.maxUnaccountedFraction,
            "\(label) normalizeAndAnalyze accounting residue \(normAccounting.unaccountedFraction)"
        )

        print("\n## \(label) (\(workout.routePoints.count) pts, \(size.warmups) warm / \(size.iterations) meas)\n")
        print("| Entry | Mode A median ms | Mode B median ms | Overhead | Residue | Valid |")
        print("|---|---:|---:|---:|---:|:---:|")
        print(
            "| analyze | \(formatMs(modeA.stats.medianMilliseconds)) | \(formatMs(modeB.stats.medianMilliseconds)) | \(String(format: "%.3f", overhead)) | \(formatPct(accounting.unaccountedMilliseconds, of: accounting.wallMilliseconds))% | \(accounting.isValid ? "yes" : "NO") |"
        )
        let normOverhead = modeBNorm.stats.medianMilliseconds / max(modeANorm.stats.medianMilliseconds, 1e-9)
        print(
            "| normalizeAndAnalyze | \(formatMs(modeANorm.stats.medianMilliseconds)) | \(formatMs(modeBNorm.stats.medianMilliseconds)) | \(String(format: "%.3f", normOverhead)) | \(formatPct(normAccounting.unaccountedMilliseconds, of: normAccounting.wallMilliseconds))% | \(normAccounting.isValid ? "yes" : "NO") |"
        )
        print("\nMode A analyze stats: \(formatStats(modeA.stats))")
        print("Mode A normalizeAndAnalyze stats: \(formatStats(modeANorm.stats))")
        print("Parity digests: analyze ok, normalizeAndAnalyze ok")

        if overhead > Self.maxOverheadRatio {
            print("_Note: analyze Mode B overhead \(String(format: "%.3f", overhead)) exceeds 1.15; phase % approximate._")
        }

        print("\n### analyze phase breakdown (last Mode B, ms)\n")
        print("| Phase | ms | % wall |")
        print("|---|---:|---:|")
        let wall = HotspotTestClock.ms(lastProfile.wallNanoseconds)
        func row(_ name: String, _ ns: UInt64) {
            let ms = HotspotTestClock.ms(ns)
            print("| \(name) | \(formatMs(ms)) | \(formatPct(ms, of: wall))% |")
        }
        row("elevation", lastProfile.elevationNanoseconds)
        row("timeline", lastProfile.timelineNanoseconds)
        row("derived metrics", lastProfile.derivedMetricsNanoseconds)
        row("movement", lastProfile.movementProfileNanoseconds)
        row("context rebind", lastProfile.contextRebindNanoseconds)
        row("summary", lastProfile.summaryNanoseconds)
        row("splits", lastProfile.splitsNanoseconds)
        row("recorded laps", lastProfile.recordedLapsNanoseconds)
        row("segments", lastProfile.segmentsNanoseconds)
        row("warnings", lastProfile.warningsNanoseconds)
        row("**accounted**", lastProfile.accountedNanoseconds)
        row("**wall**", lastProfile.wallNanoseconds)

        print("\n### normalizeAndAnalyze phase breakdown (last Mode B, ms)\n")
        print("| Phase | ms | % wall |")
        print("|---|---:|---:|")
        let nWall = HotspotTestClock.ms(lastNormProfile.wallNanoseconds)
        func nrow(_ name: String, _ ns: UInt64) {
            let ms = HotspotTestClock.ms(ns)
            print("| \(name) | \(formatMs(ms)) | \(formatPct(ms, of: nWall))% |")
        }
        nrow("route quality (+ elev)", lastNormProfile.routeQualityNanoseconds)
        nrow("timeline/context", lastNormProfile.timelineNanoseconds)
        nrow("derived metrics", lastNormProfile.derivedMetricsNanoseconds)
        nrow("movement", lastNormProfile.movementProfileNanoseconds)
        nrow("context rebind", lastNormProfile.contextRebindNanoseconds)
        nrow("summary", lastNormProfile.summaryNanoseconds)
        nrow("splits", lastNormProfile.splitsNanoseconds)
        nrow("recorded laps", lastNormProfile.recordedLapsNanoseconds)
        nrow("segments", lastNormProfile.segmentsNanoseconds)
        nrow("warnings", lastNormProfile.warningsNanoseconds)
        nrow("**accounted**", lastNormProfile.accountedNanoseconds)
        nrow("**wall**", lastNormProfile.wallNanoseconds)

        if memory || profileMemoryEnabled {
            let before = processMemorySnapshot()
            var w = workout
            analyzer.analyze(&w)
            let after = processMemorySnapshot()
            print("\n### Memory (process-wide, not per-op peak unless sampled)\n")
            print("| | bytes |")
            print("|---|---:|")
            print("| resident before | \(before.residentBytes) |")
            print("| resident after | \(after.residentBytes) |")
            print("| process high-water resident | \(after.highWaterResidentBytes) |")
            print("| route points × ~200 B estimate | \(workout.routePoints.count * 200) |")
        }
    }

    // MARK: - Family B

    func testFamilyB_AlignmentProfile() throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard ProfileFamily.selected.contains(.alignment) else { return }
        ProfileFamilyInvocationCounter.record(.alignment)
        XCTAssertEqual(ProfileFamilyInvocationCounter.count(for: .alignment), 1)

        print("\n<!-- BEGIN RUNPLAY CORE HOTSPOT PROFILE FAMILY B -->")
        print("\n# Family B — Route-aware alignment outside DTW\n")

        try profileAlignment(label: "B1 ordinary similar", pair: HotspotProfilingFixtures.b1(), size: .standard)
        try profileAlignment(label: "B2 max samples", pair: HotspotProfilingFixtures.b2(), size: .standard)
        try profileAlignment(label: "B3 dense coarsened", pair: HotspotProfilingFixtures.b3(), size: .large)
        try profileAlignment(label: "B4 many segments", pair: HotspotProfilingFixtures.b4(), size: .standard)
        try profileAlignment(label: "B5 geo noise prefix", pair: HotspotProfilingFixtures.b5(), size: .standard)

        print("\n<!-- END RUNPLAY CORE HOTSPOT PROFILE FAMILY B -->\n")
    }

    private func profileAlignment(
        label: String,
        pair: (RunWorkout, RunWorkout),
        size: ProfileFixtureSize
    ) throws {
        var primary = pair.0
        var comparison = pair.1
        // Analyze so distances/contexts are production-shaped.
        WorkoutAnalyzer().analyze(&primary)
        WorkoutAnalyzer().analyze(&comparison)
        let pCtx = WorkoutAnalysisContext(workout: primary)
        let cCtx = WorkoutAnalysisContext(workout: comparison)
        let aligner = ConstrainedDynamicTimeWarpingAligner()
        let metricsService = RouteAlignmentMetricsService()

        let modeA = try measureStatisticsWithResult(size: size) {
            try aligner.align(
                primary: primary,
                comparison: comparison,
                primaryContext: pCtx,
                comparisonContext: cCtx
            )
        }
        let digestA = HotspotProfilingDigests.alignmentDigest(modeA.last)

        var lastProfile = RouteAlignmentPhaseProfile()
        let modeB = try measureStatisticsWithResult(size: size) {
            let result = try aligner.alignCollectingProfile(
                primary: primary,
                comparison: comparison,
                primaryContext: pCtx,
                comparisonContext: cCtx
            )
            lastProfile = result.profile
            return result.snapshot
        }
        let digestB = HotspotProfilingDigests.alignmentDigest(modeB.last)
        XCTAssertEqual(digestA, digestB, "\(label): alignment snapshot mismatch")

        // Aligned metrics at mid progress.
        let metricsElapsed = HotspotTestClock.milliseconds {
            _ = metricsService.metrics(
                atAlignedProgress: modeA.last.totalAlignedDistanceMeters * 0.5,
                snapshot: modeA.last,
                primary: primary,
                comparison: comparison,
                primaryContext: pCtx,
                comparisonContext: cCtx
            )
        }

        let accounting = ProfileAccounting.make(
            wallMs: HotspotTestClock.ms(lastProfile.wallNanoseconds),
            measuredMs: HotspotTestClock.ms(lastProfile.accountedNanoseconds)
        )
        XCTAssertLessThanOrEqual(
            abs(accounting.unaccountedFraction),
            Self.maxUnaccountedFraction,
            "\(label) alignment accounting residue"
        )
        let overhead = modeB.stats.medianMilliseconds / max(modeA.stats.medianMilliseconds, 1e-9)

        print("\n## \(label)\n")
        print("| Metric | Value |")
        print("|---|---|")
        print("| Mode A median ms | \(formatMs(modeA.stats.medianMilliseconds)) |")
        print("| Mode B median ms | \(formatMs(modeB.stats.medianMilliseconds)) |")
        print("| Overhead | \(String(format: "%.3f", overhead)) |")
        print("| Residue | \(formatPct(accounting.unaccountedMilliseconds, of: accounting.wallMilliseconds))% |")
        print("| Availability | \(String(describing: modeA.last.availability)) |")
        print("| Blocks | \(modeA.last.blocks.count) |")
        print("| Aligned metrics (single call) ms | \(formatMs(metricsElapsed)) |")
        print("| Stats | \(formatStats(modeA.stats)) |")
        print("| Parity | ok |")

        let wall = HotspotTestClock.ms(lastProfile.wallNanoseconds)
        print("\n| Phase | ms | % |")
        print("|---|---:|---:|")
        func row(_ n: String, _ ns: UInt64, nested: Bool = false) {
            let ms = HotspotTestClock.ms(ns)
            let prefix = nested ? "⤷ " : ""
            print("| \(prefix)\(n) | \(formatMs(ms)) | \(formatPct(ms, of: wall))% |")
        }
        row("sample builder", lastProfile.sampleBuilderNanoseconds)
        row("valid filter", lastProfile.sampleBuilderDetail.validPointFilterNanoseconds, nested: true)
        row("shared origin", lastProfile.sampleBuilderDetail.sharedOriginNanoseconds, nested: true)
        row("adaptive interval", lastProfile.sampleBuilderDetail.adaptiveIntervalNanoseconds, nested: true)
        row("primary resample", lastProfile.sampleBuilderDetail.primaryResampleNanoseconds, nested: true)
        row("comparison resample", lastProfile.sampleBuilderDetail.comparisonResampleNanoseconds, nested: true)
        row("extent validation", lastProfile.sampleBuilderDetail.extentValidationNanoseconds, nested: true)
        row("direction", lastProfile.directionDetectionNanoseconds)
        row("native DTW bridge", lastProfile.nativeDTWNanoseconds)
        row("blocks", lastProfile.blockConstructionNanoseconds)
        row("diagnostics", lastProfile.diagnosticsNanoseconds)
        row("**wall**", lastProfile.wallNanoseconds)
    }

    // MARK: - Family C

    func testFamilyC_MetricsProfile() throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard ProfileFamily.selected.contains(.metrics) else { return }
        ProfileFamilyInvocationCounter.record(.metrics)
        XCTAssertEqual(ProfileFamilyInvocationCounter.count(for: .metrics), 1)

        print("\n<!-- BEGIN RUNPLAY CORE HOTSPOT PROFILE FAMILY C -->")
        print("\n# Family C — Route metric profile\n")

        try profileMetrics(label: "C1 pace 100k", workout: HotspotProfilingFixtures.c1(), mode: .pace, size: .large)
        try profileMetrics(label: "C2 HR gaps 100k", workout: HotspotProfilingFixtures.c2(), mode: .heartRate, size: .large)
        try profileMetrics(label: "C3 elevation", workout: HotspotProfilingFixtures.c3(), mode: .correctedElevation, size: .standard)
        try profileMetrics(label: "C4 many segments", workout: HotspotProfilingFixtures.c4(), mode: .pace, size: .large)

        if profileProductLimitEnabled {
            try profileMetrics(
                label: "C5 product limit",
                workout: HotspotProfilingFixtures.c5(),
                mode: .pace,
                size: .productLimit,
                memory: true
            )
        } else {
            print("\n_C5 product-limit probe skipped (set RUNPLAY_PROFILE_PRODUCT_LIMIT=1)._\n")
        }

        print("\n<!-- END RUNPLAY CORE HOTSPOT PROFILE FAMILY C -->\n")
    }

    private func profileMetrics(
        label: String,
        workout: RunWorkout,
        mode: WorkoutRouteColorMode,
        size: ProfileFixtureSize,
        memory: Bool = false
    ) throws {
        var analyzed = workout
        WorkoutAnalyzer().analyze(&analyzed)
        let context = WorkoutAnalysisContext(workout: analyzed)
        let builder = RouteMetricProfileBuilder()

        let modeA = try measureStatisticsWithResult(size: size) {
            try builder.build(
                routePoints: analyzed.routePoints,
                context: context,
                mode: mode
            )
        }
        let digestA = HotspotProfilingDigests.metricProfileDigest(modeA.last)

        var lastPhase = RouteMetricPhaseProfile()
        let modeB = try measureStatisticsWithResult(size: size) {
            let result = try builder.buildCollectingProfile(
                routePoints: analyzed.routePoints,
                context: context,
                mode: mode
            )
            lastPhase = result.phaseProfile
            return result.profile
        }
        let digestB = HotspotProfilingDigests.metricProfileDigest(modeB.last)
        XCTAssertEqual(digestA, digestB, "\(label): metric profile mismatch")

        let accounting = ProfileAccounting.make(
            wallMs: HotspotTestClock.ms(lastPhase.wallNanoseconds),
            measuredMs: HotspotTestClock.ms(lastPhase.accountedNanoseconds)
        )
        // Solid mode has no subphases; only enforce for modes that fill phases.
        if mode != .solid {
            XCTAssertLessThanOrEqual(
                abs(accounting.unaccountedFraction),
                Self.maxUnaccountedFraction,
                "\(label) metrics accounting residue \(accounting.unaccountedFraction)"
            )
        }
        let overhead = modeB.stats.medianMilliseconds / max(modeA.stats.medianMilliseconds, 1e-9)

        print("\n## \(label) (\(analyzed.routePoints.count) pts, mode \(mode.rawValue))\n")
        print("| Metric | Value |")
        print("|---|---|")
        print("| Mode A median ms | \(formatMs(modeA.stats.medianMilliseconds)) |")
        print("| Mode B median ms | \(formatMs(modeB.stats.medianMilliseconds)) |")
        print("| Overhead | \(String(format: "%.3f", overhead)) |")
        print("| Residue | \(formatPct(accounting.unaccountedMilliseconds, of: accounting.wallMilliseconds))% |")
        print("| Intervals | \(modeA.last.intervals.count) |")
        print("| Stats | \(formatStats(modeA.stats)) |")
        print("| Parity | ok |")

        let wall = HotspotTestClock.ms(lastPhase.wallNanoseconds)
        print("\n| Phase | ms | % |")
        print("|---|---:|---:|")
        func row(_ n: String, _ ns: UInt64) {
            let ms = HotspotTestClock.ms(ns)
            print("| \(n) | \(formatMs(ms)) | \(formatPct(ms, of: wall))% |")
        }
        row("input validation", lastPhase.inputValidationNanoseconds)
        row("metric extraction", lastPhase.metricExtractionNanoseconds)
        row("smoothing", lastPhase.smoothingNanoseconds)
        row("scale/buckets", lastPhase.scaleBucketNanoseconds)
        row("**wall**", lastPhase.wallNanoseconds)

        if memory || profileMemoryEnabled {
            let before = processMemorySnapshot()
            _ = try builder.build(routePoints: analyzed.routePoints, context: context, mode: mode)
            let after = processMemorySnapshot()
            print("\nResident before/after: \(before.residentBytes) / \(after.residentBytes); high-water \(after.highWaterResidentBytes)")
        }
    }

    // MARK: - Family D

    func testFamilyD_ImportProfile() throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard ProfileFamily.selected.contains(.importFamily) else { return }
        ProfileFamilyInvocationCounter.record(.importFamily)
        XCTAssertEqual(ProfileFamilyInvocationCounter.count(for: .importFamily), 1)

        print("\n<!-- BEGIN RUNPLAY CORE HOTSPOT PROFILE FAMILY D -->")
        print("\n# Family D — Import pipelines\n")

        try profileJSON()
        try profileGPX()
        try profileTCX()
        try profileFIT()
        try profileMultiSessionFIT()

        print("\n_Strava archive path is covered in RemainingPlatformHotspotProfile (ZIPFoundation)._\n")
        print("\n<!-- END RUNPLAY CORE HOTSPOT PROFILE FAMILY D -->\n")
    }

    private func profileJSON() throws {
        print("\n## JSON import\n")
        print("| Fixture | Parse+build median ms | Normalize+analyze median ms | Total median ms | Parity |")
        print("|---|---:|---:|---:|:---:|")
        for (label, count, size) in [
            ("D1 small", 500, ProfileFixtureSize.standard),
            ("D2 10k", 10_000, ProfileFixtureSize.standard),
            ("D3 100k", 100_000, ProfileFixtureSize.large),
            ("D4 many seg", 10_000, ProfileFixtureSize.standard),
            ("D5 metrics/laps", 5_000, ProfileFixtureSize.standard)
        ] as [(String, Int, ProfileFixtureSize)] {
            let segments = label.contains("many") ? 20 : 1
            let data = HotspotProfilingFixtures.jsonData(pointCount: count, seed: 5_001, segments: segments)
            let importer = JSONWorkoutImporter()
            let analyzer = WorkoutAnalyzer()

            let parseStats = try measureStatisticsWithResult(size: size) {
                try importer.importWorkout(from: data)
            }
            let digestImport = HotspotProfilingDigests.importParityDigest(parseStats.last)

            // Re-import for each analyze measurement to keep Mode A clean.
            let analyzeStats = try measureStatisticsWithResult(size: size) {
                var w = try importer.importWorkout(from: data)
                try analyzer.normalizeAndAnalyze(&w, distancePolicy: .useSuppliedDistancesWhenValid)
                return w
            }
            // Total ≈ import + normalize path from already-imported? Measure end-to-end:
            let totalStats = try measureStatistics(size: size) {
                var w = try importer.importWorkout(from: data)
                try analyzer.normalizeAndAnalyze(&w, distancePolicy: .useSuppliedDistancesWhenValid)
            }
            // Parity: two imports equal (IDs excluded — importers mint new UUIDs)
            let again = try importer.importWorkout(from: data)
            XCTAssertEqual(
                digestImport,
                HotspotProfilingDigests.importParityDigest(again),
                "\(label) JSON import parity"
            )
            let analyzeOnly = max(
                0,
                analyzeStats.stats.medianMilliseconds - parseStats.stats.medianMilliseconds
            )
            print(
                "| \(label) (\(count)) | \(formatMs(parseStats.stats.medianMilliseconds)) | \(formatMs(analyzeOnly)) | \(formatMs(totalStats.medianMilliseconds)) | ok |"
            )
        }

        // D6 malformed
        do {
            _ = try JSONWorkoutImporter().importWorkout(from: Data("{not-json".utf8))
            XCTFail("malformed JSON should throw")
        } catch {
            print("| D6 malformed | — | — | rejected: \(type(of: error)) | ok |")
        }
    }

    private func profileGPX() throws {
        print("\n## GPX import\n")
        print("| Fixture | XML parse+build median ms | Notes |")
        print("|---|---:|---|")
        let importer = GPXImporter()
        for (label, count, segs, size) in [
            ("D1 small", 400, 1, ProfileFixtureSize.standard),
            ("D2 10k", 10_000, 1, ProfileFixtureSize.standard),
            ("D3 100k", 100_000, 1, ProfileFixtureSize.large),
            ("D4 multi trkseg", 5_000, 8, ProfileFixtureSize.standard),
            ("D5 partial ts", 2_000, 2, ProfileFixtureSize.standard)
        ] as [(String, Int, Int, ProfileFixtureSize)] {
            let data = HotspotProfilingFixtures.gpxData(
                pointCount: count,
                seed: 5_101,
                segments: segs,
                partialTimestamps: label.contains("partial")
            )
            let stats = try measureStatisticsWithResult(size: size) {
                try importer.importWorkout(data: data, suggestedName: label)
            }
            let again = try importer.importWorkout(data: data, suggestedName: label)
            XCTAssertEqual(
                HotspotProfilingDigests.importParityDigest(stats.last),
                HotspotProfilingDigests.importParityDigest(again)
            )
            print("| \(label) (\(count)) | \(formatMs(stats.stats.medianMilliseconds)) | pts=\(stats.last.routePoints.count) segs=\(Set(stats.last.routePoints.map(\.routeSegmentIndex)).count) |")
        }
        do {
            _ = try importer.importWorkout(data: Data("<gpx></gpx>".utf8), suggestedName: "empty")
            XCTFail("empty GPX should throw")
        } catch {
            print("| D6 malformed/empty | rejected | \(error.localizedDescription) |")
        }
    }

    private func profileTCX() throws {
        print("\n## TCX import\n")
        print("| Fixture | XML parse+build median ms | Notes |")
        print("|---|---:|---|")
        let importer = TCXImporter()
        for (label, count, laps, size) in [
            ("D1 small", 400, 2, ProfileFixtureSize.standard),
            ("D2 10k", 10_000, 5, ProfileFixtureSize.standard),
            ("D3 100k", 100_000, 10, ProfileFixtureSize.large),
            ("D5 laps+HR", 3_000, 15, ProfileFixtureSize.standard)
        ] as [(String, Int, Int, ProfileFixtureSize)] {
            let data = HotspotProfilingFixtures.tcxData(pointCount: count, seed: 5_201, lapCount: laps)
            let stats = try measureStatisticsWithResult(size: size) {
                try importer.importWorkout(data: data, suggestedName: label)
            }
            let again = try importer.importWorkout(data: data, suggestedName: label)
            XCTAssertEqual(
                HotspotProfilingDigests.importParityDigest(stats.last),
                HotspotProfilingDigests.importParityDigest(again)
            )
            print("| \(label) (\(count)) | \(formatMs(stats.stats.medianMilliseconds)) | laps=\(stats.last.recordedLaps.count) pts=\(stats.last.routePoints.count) |")
        }
        // Multi-activity rejection
        do {
            let multi = HotspotProfilingFixtures.tcxData(pointCount: 50, seed: 5_299, lapCount: 1, multiActivity: true)
            _ = try importer.importWorkout(data: multi, suggestedName: "multi")
            XCTFail("multi-activity TCX should throw")
        } catch {
            print("| D6 multi-activity | rejected | \(error.localizedDescription) |")
        }
    }

    private func profileFIT() throws {
        print("\n## FIT import\n")
        print("| Fixture | Parse+build median ms | Notes |")
        print("|---|---:|---|")
        let importer = FITImporter()
        for (label, count, size) in [
            ("D1 small", 200, ProfileFixtureSize.standard),
            ("D2 10k", 10_000, ProfileFixtureSize.standard),
            ("D3 100k", 100_000, ProfileFixtureSize.large),
            ("D5 pause+laps", 5_000, ProfileFixtureSize.standard)
        ] as [(String, Int, ProfileFixtureSize)] {
            let data = FITProfilingFixtureBuilder.singleSession(
                pointCount: count,
                lapCount: 5,
                includeTimerPause: true
            )
            let stats = try measureStatisticsWithResult(size: size) {
                try importer.importWorkout(data: data, suggestedName: label)
            }
            let again = try importer.importWorkout(data: data, suggestedName: label)
            XCTAssertEqual(
                HotspotProfilingDigests.importParityDigest(stats.last),
                HotspotProfilingDigests.importParityDigest(again)
            )
            print("| \(label) (\(count)) | \(formatMs(stats.stats.medianMilliseconds)) | pts=\(stats.last.routePoints.count) laps=\(stats.last.recordedLaps.count) |")
        }
        do {
            _ = try importer.importWorkout(
                data: FITProfilingFixtureBuilder.malformedCRC(),
                suggestedName: "crc"
            )
            // Some parsers may still accept if CRC optional; record outcome.
            print("| D6 CRC corrupt | accepted or rejected | check product policy |")
        } catch {
            print("| D6 CRC corrupt | rejected | \(error.localizedDescription) |")
        }
        do {
            _ = try importer.importWorkout(
                data: FITProfilingFixtureBuilder.emptyRecords(),
                suggestedName: "empty"
            )
            XCTFail("empty records should throw")
        } catch {
            print("| D6 empty records | rejected | \(error.localizedDescription) |")
        }
    }

    private func profileMultiSessionFIT() throws {
        print("\n## Multi-session FIT\n")
        let data = FITProfilingFixtureBuilder.multiSession(firstCount: 800, secondCount: 800)
        // Direct FITImporter rejects multi-run containers; the production batch
        // path parses once and builds sessions. Profile the parse boundary and
        // the expected single-importer rejection.
        print("| Path | median ms | Notes |")
        print("|---|---:|---|")

        let parseOnly = try measureStatistics(size: .standard) {
            _ = try FITParser.parse(data: data, isCancelled: { false })
        }
        print("| FITParser.parse multi-session container | \(formatMs(parseOnly.medianMilliseconds)) | production shared decode |")

        do {
            _ = try FITImporter().importWorkout(data: data, suggestedName: "multi")
            XCTFail("multi-session FIT must not import through single-session FITImporter")
        } catch {
            print("| FITImporter single-session rejection | — | \(error.localizedDescription) |")
        }

        // Build both sessions via the decoder session index path used by batch import.
        let buildStats = try measureStatisticsWithResult(size: .standard) {
            let decoded = try FITParser.parse(data: data, isCancelled: { false })
            let index = try FITSessionMessageIndex.build(decodedFile: decoded)
            return index.sessionCount
        }
        print("| FITSessionMessageIndex.build | \(formatMs(buildStats.stats.medianMilliseconds)) | sessions=\(buildStats.last) |")
    }

    // MARK: - Family E

    func testFamilyE_ComparisonProfile() async throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard ProfileFamily.selected.contains(.comparison) else { return }
        ProfileFamilyInvocationCounter.record(.comparison)
        XCTAssertEqual(ProfileFamilyInvocationCounter.count(for: .comparison), 1)

        print("\n<!-- BEGIN RUNPLAY CORE HOTSPOT PROFILE FAMILY E -->")
        print("\n# Family E — Comparison and library query\n")

        var w1 = HotspotProfilingFixtures.makeWorkout(options: .init(pointCount: 10_000, seed: 7_001, name: "E1"))
        var w2 = HotspotProfilingFixtures.makeWorkout(options: .init(pointCount: 10_000, seed: 7_002, name: "E2"))
        WorkoutAnalyzer().analyze(&w1)
        WorkoutAnalyzer().analyze(&w2)
        let service = WorkoutComparisonService()

        let compareStats = measureStatisticsWithResult(size: .standard) {
            service.compare(primary: w1, comparison: w2)
        }
        let again = service.compare(primary: w1, comparison: w2)
        XCTAssertEqual(
            HotspotProfilingDigests.comparisonDigest(compareStats.last),
            HotspotProfilingDigests.comparisonDigest(again)
        )

        print("\n## WorkoutComparisonService (2×10k)\n")
        print("| Metric | Value |")
        print("|---|---|")
        print("| median ms | \(formatMs(compareStats.stats.medianMilliseconds)) |")
        print("| stats | \(formatStats(compareStats.stats)) |")
        print("| parity | ok |")

        // Library query scaling
        print("\n## WorkoutLibraryQueryService\n")
        print("| Entries | Query | median ms | filtered |")
        print("|---:|---|---:|---:|")
        let queryService = WorkoutLibraryQueryService()
        let sizes = profileProductLimitEnabled ? [1_000, 10_000, 50_000] : [1_000, 10_000]
        for count in sizes {
            let (entries, documents) = HotspotProfilingFixtures.libraryEntries(count: count)
            let queries: [(String, WorkoutLibraryQuery)] = [
                ("text Run", WorkoutLibraryQuery(searchText: "Run")),
                (
                    "favorites",
                    WorkoutLibraryQuery(filter: WorkoutLibraryFilter(favorite: .favoritesOnly))
                ),
                (
                    "source gpx",
                    WorkoutLibraryQuery(filter: WorkoutLibraryFilter(source: .gpx))
                )
            ]
            let size: ProfileFixtureSize = count >= 10_000 ? .large : .standard
            let total = size.warmups + size.iterations
            for (name, query) in queries {
                var samples: [Double] = []
                var lastFiltered = 0
                for i in 0..<total {
                    let start = ContinuousClock.now
                    let result = try await queryService.execute(
                        entries: entries,
                        documents: documents,
                        query: query
                    )
                    let ms = HotspotTestClock.ms(
                        HotspotTestClock.nanoseconds(from: start, to: ContinuousClock.now)
                    )
                    if i >= size.warmups {
                        samples.append(ms)
                        lastFiltered = result.filteredCount
                    }
                }
                let stats = HotspotTestClock.statistics(from: samples)
                print("| \(count) | \(name) | \(formatMs(stats.medianMilliseconds)) | \(lastFiltered) |")
            }
        }

        print("\n<!-- END RUNPLAY CORE HOTSPOT PROFILE FAMILY E -->\n")
    }

    // MARK: - Duplicate-execution guard

    func testFamilyInvocationCounterNeverDoublesUnderAll() throws {
        try XCTSkipUnless(profileEnabled, "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        // After the suite runs individual family tests, each selected family
        // should have been recorded at most once. This method does not invoke
        // other tests; it only asserts the global counter invariant for families
        // that already ran in this process.
        for family in ProfileFamily.allCases where ProfileFamily.selected.contains(family) {
            let count = ProfileFamilyInvocationCounter.count(for: family)
            XCTAssertLessThanOrEqual(
                count,
                1,
                "family \(family.rawValue) executed \(count) times (must be ≤ 1)"
            )
        }
    }
}
