import XCTest
import Foundation
@testable import RunPlayCore

// MARK: - Deterministic LCG

private struct ProfilingLCG {
    private var state: UInt64
    static let multiplier: UInt64 = 6_364_136_223_846_793_005
    static let increment: UInt64 = 1_442_695_040_888_963_407

    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* Self.multiplier &+ Self.increment
        return state
    }
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
    mutating func symmetric(_ magnitude: Double) -> Double {
        (unit() * 2 - 1) * magnitude
    }
}

// MARK: - Timing Helpers

#if canImport(Darwin)
import Darwin
private func physicalMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) { p in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return info.resident_size
}
#else
private func physicalMemoryBytes() -> UInt64 { 0 }
#endif

private func measureBlock(_ block: () -> Void) -> (seconds: Double, memDelta: UInt64) {
    let memBefore = physicalMemoryBytes()
    let start = Date().timeIntervalSinceReferenceDate
    block()
    let elapsed = Date().timeIntervalSinceReferenceDate - start
    let memAfter = physicalMemoryBytes()
    return (elapsed, memAfter > memBefore ? memAfter - memBefore : 0)
}

// MARK: - Synthetic Fixtures

private func makeSyntheticRoutePoints(
    pointCount: Int, lcg: inout ProfilingLCG,
    baseLat: Double = 35.0, baseLon: Double = 135.0,
    stepMetres: Double = 10.0
) -> [RoutePoint] {
    let cosLat = cos(baseLat * .pi / 180.0)
    let metresPerDegLat = 111_320.0
    let metresPerDegLon = 111_320.0 * cosLat
    let now = Date()
    var points: [RoutePoint] = []
    points.reserveCapacity(pointCount)
    var x: Double = 0
    for i in 0..<pointCount {
        let wiggle = lcg.symmetric(3.0)
        let lat = baseLat + wiggle / metresPerDegLat
        let lon = baseLon + (x + wiggle * 0.5) / metresPerDegLon
        let hr = 120.0 + lcg.unit() * 40.0
        let alt = 100.0 + lcg.symmetric(50.0)
        points.append(RoutePoint(
            timestamp: now.addingTimeInterval(Double(i)),
            latitude: lat,
            longitude: lon,
            altitudeMeters: alt,
            distanceFromStartMeters: x,
            elapsedSeconds: Double(i),
            heartRateBPM: hr,
            routeSegmentIndex: 0
        ))
        x += stepMetres
    }
    return points
}

private func makeSyntheticRunWorkout(pointCount: Int, seed: UInt64) -> RunWorkout {
    var lcg = ProfilingLCG(seed: seed)
    let pts = makeSyntheticRoutePoints(pointCount: pointCount, lcg: &lcg)
    return RunWorkout(
        metadata: WorkoutMetadata(name: "synthetic-\(pointCount)", startDate: pts.first?.timestamp),
        routePoints: pts
    )
}

// MARK: - Format Helpers

private func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }
private func pct(_ part: Double, _ whole: Double) -> String {
    String(format: "%.1f", whole > 0 ? part / whole * 100 : 0)
}

private func printPhase(_ label: String, _ time: Double, _ wall: Double) {
    print("| \(label) | \(ms(time)) | \(pct(time, wall))% |")
}

private func wallRow(_ label: String, _ time: Double) {
    print("| \(label) | \(ms(time)) | — |")
}

// MARK: - Profile Runner

final class RemainingCoreHotspotProfile: XCTestCase {

    var family: String { ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_FAMILY"] ?? "all" }
    var useProductLimit: Bool { ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_PRODUCT_LIMIT"] == "1" }

    override func setUp() {
        continueAfterFailure = true
    }

    // ── Family A: Analysis ──
    func testFamilyA_AnalysisProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
                          "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard family == "all" || family == "analysis" else { return }
        print("\n# Family A: Analysis Pipeline Profile\n")
        profileAnalysis(at: 10_000, label: "10 kpts")
        profileAnalysis(at: 100_000, label: "100 kpts")
        profileAnalysis(at: useProductLimit ? 1_000_000 : 500_000,
                        label: useProductLimit ? "1 Mpts" : "500 kpts")
    }

    private func profileAnalysis(at pointCount: Int, label: String) {
        let workout = makeSyntheticRunWorkout(pointCount: pointCount, seed: 42)

        // Mode A: production
        var wA = workout
        let (wallA, _) = measureBlock { WorkoutAnalyzer().analyze(&wA) }

        // Mode B: decomposed
        let (tTimeline, _) = measureBlock {
            _ = WorkoutTimeline(routePoints: workout.routePoints)
        }
        let (tElevation, _) = measureBlock {
            _ = ElevationProfile(routePoints: workout.routePoints)
        }
        let (tMovement, _) = measureBlock {
            let timeline = WorkoutTimeline(routePoints: workout.routePoints)
            _ = try! MovementProfile(routePoints: workout.routePoints, timeline: timeline)
        }
        let (tSplits, _) = measureBlock {
            _ = SplitCalculator.calculateSplits(from: workout)
        }
        let (tSegments, _) = measureBlock {
            _ = SegmentDetector.detectSegments(from: workout)
        }

        // Parity: Mode A produced valid output
        XCTAssertGreaterThan(wA.summary.totalDistanceMeters, 0, "distance > 0")
        XCTAssertFalse(wA.splits.isEmpty, "has splits")
        XCTAssertFalse(wA.segments.isEmpty, "has segments")

        let sum = tTimeline + tElevation + tMovement + tSplits + tSegments
        let accounted = sum / max(wallA, 0.001) * 100

        print("\n## Analysis \(label) (\(pointCount) pts)")
        print("| Phase | Time (ms) | % Wall |")
        print("|-------|-----------|--------|")
        printPhase("Timeline", tTimeline, wallA)
        printPhase("Elevation", tElevation, wallA)
        printPhase("Movement", tMovement, wallA)
        printPhase("Splits (1 km)", tSplits, wallA)
        printPhase("Segments", tSegments, wallA)
        printPhase("**Sum**", sum, wallA)
        let unaccounted = wallA - sum
        printPhase("Unaccounted", unaccounted, wallA)
        wallRow("**Wall clock**", wallA)
        wallRow("**Accounting**", 0)
        print("| _Accounted %_ | **\(String(format: "%.1f", accounted))%** | |")
        print()
    }

    // ── Family B: Alignment ──
    func testFamilyB_AlignmentProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
                          "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard family == "all" || family == "alignment" else { return }
        print("\n# Family B: Route Alignment Profile\n")
        profileAlignment(at: 2_000, label: "2 kpts (align limit)")
        profileAlignment(at: 10_000, label: "10 kpts")
    }

    private func profileAlignment(at pointCount: Int, label: String) {
        let primary = makeSyntheticRunWorkout(pointCount: pointCount, seed: 101)
        let comparison = makeSyntheticRunWorkout(pointCount: pointCount, seed: 202)
        let builder = RouteAlignmentSampleBuilder()

        let (wallA, _) = measureBlock {
            _ = try? builder.build(primary: primary, comparison: comparison)
        }

        print("\n## Alignment \(label)")
        print("| Phase | Time (ms) | % Wall |")
        print("|-------|-----------|--------|")
        printPhase("Build Samples", wallA, wallA)
        print()
    }

    // ── Family C: Metrics ──
    func testFamilyC_MetricsProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
                          "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard family == "all" || family == "metrics" else { return }
        print("\n# Family C: Route Metrics Profile\n")
        profileMetrics(at: 10_000, label: "10 kpts")
        profileMetrics(at: 100_000, label: "100 kpts")
    }

    private func profileMetrics(at pointCount: Int, label: String) {
        let workout = makeSyntheticRunWorkout(pointCount: pointCount, seed: 77)
        let pts = workout.routePoints

        let (tPace, _) = measureBlock { _ = MetricSmoother.smoothPace(from: pts) }
        let (tHR, _)   = measureBlock { _ = MetricSmoother.smoothHeartRate(from: pts) }

        print("\n## Route Metrics \(label)")
        print("| Phase | Time (ms) | |")
        print("|-------|-----------|--------|")
        printPhase("Smooth Pace", tPace, 0)
        printPhase("Smooth HR", tHR, 0)
        print("| **Total** | \(ms(tPace + tHR)) | |")
        print()
    }

    // ── Family D: Import ──
    func testFamilyD_ImportProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
                          "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard family == "all" || family == "import" else { return }
        print("\n# Family D: Import Profile\n")

        for n in [1_000, 10_000, 100_000] {
            profileJSONImport(pointCount: n)
        }
    }

    private func syntheticJSONData(pointCount: Int, seed: UInt64) -> Data {
        var lcg = ProfilingLCG(seed: seed)
        let now = Date()
        var json = """
        {"metadata":{"name":"synth-\(pointCount)","startDate":\(now.timeIntervalSince1970)},"routePoints":[
        """
        var x: Double = 0
        for i in 0..<pointCount {
            if i > 0 { json += "," }
            let wiggle = lcg.symmetric(3.0)
            let lat = 35.0 + wiggle / 111_320.0
            let lng = 135.0 + x / (111_320.0 * cos(35.0 * .pi / 180.0))
            let alt = 100.0 + lcg.symmetric(50.0)
            let hr = 120.0 + lcg.unit() * 40.0
            json += """
            {"timestamp":\(now.addingTimeInterval(Double(i)).timeIntervalSince1970),"latitude":\(lat),"longitude":\(lng),"altitudeMeters":\(alt),"heartRateBPM":\(hr),"distanceFromStartMeters":\(x),"elapsedSeconds":\(Double(i)),"routeSegmentIndex":0}
            """
            x += 10.0
        }
        json += "]}"
        return json.data(using: .utf8)!
    }

    private func profileJSONImport(pointCount: Int) {
        let data = syntheticJSONData(pointCount: pointCount, seed: 42)
        let importer = JSONWorkoutImporter()

        let (wallA, _) = measureBlock { _ = try? importer.importWorkout(from: data) }

        print("\n## JSON Import \(pointCount) pts")
        print("| Phase | Time (ms) | pts/s |")
        print("|-------|-----------|-------|")
        let ptsPerSec = wallA > 0.000_001 ? Double(pointCount) / wallA : 0
        print("| Full Import | \(ms(wallA)) | \(String(format: "%.0f", ptsPerSec)) |")
        print()
    }

    // ── Family E: Comparison ──
    func testFamilyE_ComparisonProfile() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
                          "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1")
        guard family == "all" || family == "comparison" else { return }
        print("\n# Family E: Workout Comparison Profile\n")

        let w1 = makeSyntheticRunWorkout(pointCount: 10_000, seed: 1)
        let w2 = makeSyntheticRunWorkout(pointCount: 10_000, seed: 2)
        let service = WorkoutComparisonService()

        let (wallA, _) = measureBlock { _ = service.compare(primary: w1, comparison: w2) }

        print("\n## Workout Comparison (2 × 10 kpts)")
        print("| Phase | Time (ms) |")
        print("|-------|-----------|")
        print("| Compare | \(ms(wallA)) |")
        print()
    }

    // ── All ──
    func testAllFamilies() throws {
        try testFamilyA_AnalysisProfile()
        try testFamilyB_AlignmentProfile()
        try testFamilyC_MetricsProfile()
        if family == "all" || family == "import"        { try testFamilyD_ImportProfile() }
        if family == "all" || family == "comparison"     { try testFamilyE_ComparisonProfile() }
        print("\n## Profiling complete.\n")
    }
}
