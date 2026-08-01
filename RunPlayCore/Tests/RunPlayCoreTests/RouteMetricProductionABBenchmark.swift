import Foundation
import XCTest
@testable import RunPlayCore

/// Same-machine production A/B benchmark for route-metric profile work.
///
/// Uses only APIs that exist on both `origin/main` and the PR head so the
/// identical source file can be copied into a detached main worktree and run
/// with the same release command. It does **not** reference the C++ bridge,
/// native types, or benchmark-only native APIs.
///
/// Enable with `RUNPLAY_PRODUCTION_AB=1`. Product-limit fixtures additionally
/// require `RUNPLAY_PRODUCTION_AB_PRODUCT_LIMIT=1`.
final class RouteMetricProductionABBenchmark: XCTestCase {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUNPLAY_PRODUCTION_AB"] == "1"
    }

    private var includeProductLimit: Bool {
        ProcessInfo.processInfo.environment["RUNPLAY_PRODUCTION_AB_PRODUCT_LIMIT"] == "1"
    }

    func testProductionAB() throws {
        try XCTSkipUnless(enabled, "Set RUNPLAY_PRODUCTION_AB=1")

        let memoryBefore = processMemorySnapshot()
        let builder = RouteMetricProfileBuilder()
        let label = ProcessInfo.processInfo.environment["RUNPLAY_PRODUCTION_AB_LABEL"]
            ?? "unlabeled"

        print("\n<!-- BEGIN RUNPLAY ROUTE METRIC PRODUCTION A/B -->")
        print("\n# Route metric production A/B — \(label)\n")
        print("Head: \(gitHeadHint())")
        print("| Fixture | Median ms | p90 ms | Min ms | Max ms | Warmups | Iters |")
        print("|---|---:|---:|---:|---:|---:|---:|")

        // A1 ordinary 1k pace
        try measureBuild(
            label: "A1 ordinary 1k pace",
            warmups: 5,
            iterations: 20,
            builder: builder,
            workout: fixture(pointCount: 1_001, seed: 97_001),
            mode: .pace
        )

        // A2 100k pace
        try measureBuild(
            label: "A2 100k pace",
            warmups: 2,
            iterations: 5,
            builder: builder,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace
        )

        // A3 100k HR with gaps
        try measureBuild(
            label: "A3 100k HR with gaps",
            warmups: 2,
            iterations: 5,
            builder: builder,
            workout: HotspotProfilingFixtures.c2(),
            mode: .heartRate
        )

        // A4 100k corrected elevation
        try measureBuild(
            label: "A4 100k corrected elevation",
            warmups: 2,
            iterations: 5,
            builder: builder,
            workout: fixture(pointCount: 100_001, seed: 97_004, altitudeHeavy: true),
            mode: .correctedElevation
        )

        // A5 100k forced no-scale
        try measureBuild(
            label: "A5 100k forced no-scale",
            warmups: 2,
            iterations: 5,
            builder: builder,
            workout: HotspotProfilingFixtures.c1(),
            mode: .pace,
            policy: RouteMetricColorPolicy(minimumValidIntervalCount: 200_000)
        )

        // A6 100k all-missing HR
        try measureBuild(
            label: "A6 100k all-missing HR",
            warmups: 2,
            iterations: 5,
            builder: builder,
            workout: HotspotProfilingFixtures.makeWorkout(options: .init(
                pointCount: 100_001,
                includeHR: false,
                seed: 97_006,
                name: "ab-no-hr"
            )),
            mode: .heartRate
        )

        if includeProductLimit {
            let product = HotspotProfilingFixtures.c5()

            // A7 1M pace
            try measureBuild(
                label: "A7 1M pace",
                warmups: 1,
                iterations: 3,
                builder: builder,
                workout: product,
                mode: .pace
            )

            // A8 1M forced no-scale
            try measureBuild(
                label: "A8 1M forced no-scale",
                warmups: 1,
                iterations: 3,
                builder: builder,
                workout: product,
                mode: .pace,
                policy: RouteMetricColorPolicy(minimumValidIntervalCount: 2_000_000)
            )

            // A9 1M three-mode probe
            try measureProbe(
                label: "A9 1M three-mode probe",
                warmups: 1,
                iterations: 3,
                builder: builder,
                workout: product
            )

            // A10 1M probe with HR/elevation unavailable
            try measureProbe(
                label: "A10 1M probe HR/elev unavailable",
                warmups: 1,
                iterations: 3,
                builder: builder,
                workout: HotspotProfilingFixtures.makeWorkout(options: .init(
                    pointCount: 1_000_001,
                    includeHR: false,
                    includeAltitude: false,
                    seed: 97_010,
                    name: "ab-product-sparse"
                ))
            )
        } else {
            print("\n_A7–A10 skipped; set RUNPLAY_PRODUCTION_AB_PRODUCT_LIMIT=1._")
        }

        let memoryAfter = processMemorySnapshot()
        print("\nResident before/after: \(memoryBefore.residentBytes) / \(memoryAfter.residentBytes)")
        print(
            "High-water before/after: \(memoryBefore.highWaterResidentBytes) / \(memoryAfter.highWaterResidentBytes)"
        )
        print("\n<!-- END RUNPLAY ROUTE METRIC PRODUCTION A/B -->\n")
    }

    // MARK: - Measurement

    private func measureBuild(
        label: String,
        warmups: Int,
        iterations: Int,
        builder: RouteMetricProfileBuilder,
        workout: RunWorkout,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy = .runningDefault
    ) throws {
        let context = WorkoutAnalysisContext(workout: workout)
        for _ in 0..<warmups {
            _ = try builder.build(
                workout: workout,
                context: context,
                mode: mode,
                policy: policy
            )
        }
        let samples = try timings(iterations: iterations) {
            _ = try builder.build(
                workout: workout,
                context: context,
                mode: mode,
                policy: policy
            )
        }
        printRow(label: label, samples: samples, warmups: warmups, iterations: iterations)
    }

    private func measureProbe(
        label: String,
        warmups: Int,
        iterations: Int,
        builder: RouteMetricProfileBuilder,
        workout: RunWorkout,
        policy: RouteMetricColorPolicy = .runningDefault
    ) throws {
        let context = WorkoutAnalysisContext(workout: workout)
        for _ in 0..<warmups {
            _ = try builder.probe(
                routePoints: workout.routePoints,
                context: context,
                policy: policy
            )
        }
        let samples = try timings(iterations: iterations) {
            _ = try builder.probe(
                routePoints: workout.routePoints,
                context: context,
                policy: policy
            )
        }
        printRow(label: label, samples: samples, warmups: warmups, iterations: iterations)
    }

    private func printRow(
        label: String,
        samples: [Double],
        warmups: Int,
        iterations: Int
    ) {
        print(
            "| \(label) | \(format(median(samples))) | \(format(percentile(samples, 0.90))) | \(format(samples.min() ?? 0)) | \(format(samples.max() ?? 0)) | \(warmups) | \(iterations) |"
        )
    }

    private func timings(iterations: Int, operation: () throws -> Void) rethrows -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation()
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return values
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(1, max(0, p))
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * clamped).rounded()))
        return sorted[index]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func fixture(
        pointCount: Int,
        seed: UInt64,
        altitudeHeavy: Bool = false
    ) -> RunWorkout {
        HotspotProfilingFixtures.makeWorkout(options: .init(
            pointCount: pointCount,
            altitudeHeavy: altitudeHeavy,
            seed: seed,
            name: "route-metric-ab"
        ))
    }

    private func gitHeadHint() -> String {
        // Best-effort label only; never fail the benchmark when git is absent.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        } catch {}
        return "unknown"
    }
}
