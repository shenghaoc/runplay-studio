import Foundation
import Testing
@testable import RunPlayCore

/// Release-mode elevation profile benchmarks.
///
/// Skipped unless `RUNPLAY_BENCHMARK=1`. Always intended to run in release.
@Suite(
    "ElevationProfile benchmarks",
    .serialized,
    .disabled(if: ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] != "1")
)
struct ElevationProfileBenchmark {

    @Test("E1 ordinary 1,000-point workout")
    func e1Ordinary() throws {
        try runSuite(name: "E1", count: 1_000, warmups: 5, measurements: 20)
    }

    @Test("E2 100,000 dense altitude points")
    func e2Dense() throws {
        try runSuite(name: "E2", count: 100_000, warmups: 2, measurements: 5)
    }

    @Test("E7 1,000,000-point product limit")
    func e7ProductLimit() throws {
        try runSuite(name: "E7", count: 1_000_000, warmups: 1, measurements: 3)
    }

    private func runSuite(
        name: String,
        count: Int,
        warmups: Int,
        measurements: Int
    ) throws {
        let points = makeClimb(count: count)
        let policy = RouteQualityPolicy.runningDefault
        let memoryBefore = processMemorySnapshot()

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        func measure(_ body: () throws -> Void) rethrows -> Double {
            for _ in 0..<warmups {
                try body()
            }
            var samples: [Double] = []
            samples.reserveCapacity(measurements)
            for _ in 0..<measurements {
                let start = DispatchTime.now().uptimeNanoseconds
                try body()
                let end = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(end - start) / 1_000_000.0)
            }
            return median(samples)
        }

        let oracleMs = measure {
            _ = SwiftElevationProfileOracle.build(routePoints: points, policy: policy)
        }
        let bridgeMs = try measure {
            _ = try RunPlayElevationProfileBridge.build(
                routePoints: points,
                policy: policy,
                isCancelled: { false }
            )
        }
        let productionMs = try measure {
            _ = try ElevationProfile.build(
                routePoints: points,
                policy: policy,
                isCancelled: { false }
            )
        }

        var inputConversionSamples: [Double] = []
        var outputAllocationSamples: [Double] = []
        var nativeKernelSamples: [Double] = []
        var outputTranslationSamples: [Double] = []
        inputConversionSamples.reserveCapacity(measurements)
        outputAllocationSamples.reserveCapacity(measurements)
        nativeKernelSamples.reserveCapacity(measurements)
        outputTranslationSamples.reserveCapacity(measurements)

        for iteration in 0..<(warmups + measurements) {
            let report = try RunPlayElevationProfileBridge.buildCollectingBenchmarkReport(
                routePoints: points,
                policy: policy,
                isCancelled: { false }
            )
            guard iteration >= warmups else { continue }
            inputConversionSamples.append(report.inputConversionMilliseconds)
            outputAllocationSamples.append(report.outputAllocationMilliseconds)
            nativeKernelSamples.append(report.nativeKernelMilliseconds)
            outputTranslationSamples.append(report.outputTranslationMilliseconds)
        }

        let inputConversionMs = median(inputConversionSamples)
        let outputAllocationMs = median(outputAllocationSamples)
        let nativeKernelMs = median(nativeKernelSamples)
        let outputTranslationMs = median(outputTranslationSamples)
        let nativeMaximumMs = nativeKernelSamples.max() ?? 0
        let memoryAfter = processMemorySnapshot()
        let residentChange = Int64(memoryAfter.residentBytes) - Int64(memoryBefore.residentBytes)

        let ratio = oracleMs > 0 ? bridgeMs / oracleMs : 0
        print(
            """
            ElevationProfileBenchmark \(name):
              oracle_ms=\(String(format: "%.3f", oracleMs))
              bridge_ms=\(String(format: "%.3f", bridgeMs))
              native_kernel_ms=\(String(format: "%.3f", nativeKernelMs))
              production_ms=\(String(format: "%.3f", productionMs))
              bridge_over_oracle=\(String(format: "%.3f", ratio))
              input_conversion_ms=\(String(format: "%.3f", inputConversionMs))
              output_allocation_ms=\(String(format: "%.3f", outputAllocationMs))
              output_translation_ms=\(String(format: "%.3f", outputTranslationMs))
              native_maximum_ms=\(String(format: "%.3f", nativeMaximumMs))
              resident_before_bytes=\(memoryBefore.residentBytes)
              resident_after_bytes=\(memoryAfter.residentBytes)
              resident_change_bytes=\(residentChange)
              process_high_water_resident_bytes=\(memoryAfter.highWaterResidentBytes)
            """
        )

        #expect(bridgeMs > 0)
        #expect(productionMs > 0)
        if count >= 100_000 {
            #expect(bridgeMs <= oracleMs * 1.05)
        }
    }

    private func makeClimb(count: Int) -> [RoutePoint] {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let value = Double(index)
            let altitude = 100 + Double(index % 500) * 0.02

            points.append(RoutePoint(
                timestamp: base.addingTimeInterval(value),
                latitude: 37 + value * 0.000001,
                longitude: -122,
                altitudeMeters: altitude,
                distanceFromStartMeters: value,
                elapsedSeconds: value,
                routeSegmentIndex: 0
            ))
        }

        return points
    }
}
