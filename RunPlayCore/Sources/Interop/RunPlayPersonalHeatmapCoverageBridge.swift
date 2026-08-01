import Foundation

internal import CxxStdlib
internal import RunPlayEngineCpp

/// Pure-Swift summary of one native per-workout coverage operation.
struct RunPlayPersonalHeatmapCoverageMetadata: Equatable, Sendable {
    let cellCount: Int
    let validProjectedPointCount: Int
    let effectiveSegmentCount: Int
    let invalidIntervalCount: Int
}

/// Pure-Swift coverage result for a single workout at a given cell size.
struct RunPlayPersonalHeatmapWorkoutCoverage: Sendable {
    let cells: [PersonalHeatmapCellID]
    let validProjectedPointCount: Int
    let effectiveSegmentCount: Int
    let invalidIntervalCount: Int
}

/// Errors raised by the personal heatmap coverage C++ bridge.
enum RunPlayPersonalHeatmapCoverageBridgeError: Error, Equatable {
    case invalidConfiguration
    case allocationFailure
    case engineContractViolation
}

/// Pure-Swift timing decomposition of **one** coverage bridge call.
///
/// Exists so the profiling harness can separate native C++ execution from the
/// Swift-side costs the bridge pays around it (caller-owned output allocation,
/// capacity renegotiation, and C++-to-Swift cell translation). The production
/// `coverage(...)` entry point never collects these timings; only
/// `profiledCoverage(...)` does, and only tests call that.
///
/// Contains no imported C++ type, so it can cross into test code freely.
struct RunPlayPersonalHeatmapCoverageProfile: Sendable {
    /// De-duplicated cell count the engine reported for this workout.
    let requiredCellCount: Int
    /// Native invocations performed (1 normally, 2 after a capacity retry).
    let nativeCallCount: Int
    /// Times the initial output capacity was too small.
    let capacityRetryCount: Int
    /// Time spent allocating caller-owned output buffers.
    let outputAllocationNanoseconds: UInt64
    /// Time spent inside `compute_personal_heatmap_workout_coverage`.
    let nativeNanoseconds: UInt64
    /// Time spent converting native cell indexes into `PersonalHeatmapCellID`.
    let translationNanoseconds: UInt64
}

/// Pure-Swift timing decomposition of one direct accumulation bridge call.
///
/// Like `RunPlayPersonalHeatmapCoverageProfile`, this is diagnostic-only. The
/// production accumulation entry point reads no profiling clock.
struct RunPlayPersonalHeatmapAccumulationProfile: Sendable {
    /// De-duplicated cell count the engine reported for this workout.
    let cellCount: Int
    /// Native invocations performed (1 normally, 2 after a capacity retry).
    let nativeCallCount: Int
    /// Times the initial output capacity was too small.
    let capacityRetryCount: Int
    /// Time spent allocating caller-owned output buffers.
    let outputAllocationNanoseconds: UInt64
    /// Time spent inside `compute_personal_heatmap_workout_coverage`.
    let nativeNanoseconds: UInt64
    /// Time spent consuming native cells and updating the Swift dictionary.
    let directCellConsumptionAndCountingNanoseconds: UInt64
}

private struct RunPlayPersonalHeatmapNativeCoverageProfile {
    let nativeCallCount: Int
    let capacityRetryCount: Int
    let outputAllocationNanoseconds: UInt64
    let nativeNanoseconds: UInt64
}

/// Monotonic nanosecond accounting for the profiling path.
///
/// Uses `ContinuousClock` rather than `DispatchTime` so `RunPlayCore` sources
/// stay on the Swift standard library and remain valid on Linux.
private enum RunPlayCoverageProfileClock {
    @inline(__always)
    static func nanoseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return nanoseconds > 0 ? UInt64(nanoseconds) : 0
    }
}

/// Cached native route samples and output capacity hints for a set of workouts.
///
/// Created once per date-eligible workout batch to avoid re-converting Swift
/// `RoutePoint` values into C++ `PersonalHeatmapRouteSample` structures during
/// adaptive resolution retries.
final class RunPlayPersonalHeatmapPreparedBatch: @unchecked Sendable {
    private let nativeSamples: ContiguousArray<runplay.PersonalHeatmapRouteSample>
    private let workoutRanges: [Range<Int>]
    private var capacityHints: [Int]
    private let lock = NSLock()

    init(
        nativeSamples: ContiguousArray<runplay.PersonalHeatmapRouteSample>,
        workoutRanges: [Range<Int>]
    ) {
        self.nativeSamples = nativeSamples
        self.workoutRanges = workoutRanges
        self.capacityHints = workoutRanges.map { range in
            Self.minimumInitialCapacity(for: range.count)
        }
    }

    var workoutCount: Int {
        workoutRanges.count
    }

    /// Production compatibility call. Collects no timing and materializes the
    /// cell array only for test-focused callers.
    func coverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapWorkoutCoverage {
        try computeCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            collectProfile: false,
            isCancelled: isCancelled
        ).coverage
    }

    /// Production aggregation call. Native cells are consumed while the
    /// caller-owned output buffer is alive; no per-workout Swift cell array is
    /// created.
    func accumulateCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        into counts: inout [PersonalHeatmapCellID: Int],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapCoverageMetadata {
        try computeAccumulatedCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            into: &counts,
            collectProfile: false,
            isCancelled: isCancelled
        ).metadata
    }

    /// Diagnostic array-materializing call used only by test profiling.
    func profiledCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> (
        coverage: RunPlayPersonalHeatmapWorkoutCoverage,
        profile: RunPlayPersonalHeatmapCoverageProfile
    ) {
        let result = try computeCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            collectProfile: true,
            isCancelled: isCancelled
        )
        guard let profile = result.profile else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
        return (result.coverage, profile)
    }

    /// Diagnostic direct-accumulation call used only by test profiling.
    func profiledAccumulateCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        into counts: inout [PersonalHeatmapCellID: Int],
        isCancelled: @Sendable () -> Bool
    ) throws -> (
        metadata: RunPlayPersonalHeatmapCoverageMetadata,
        profile: RunPlayPersonalHeatmapAccumulationProfile
    ) {
        let result = try computeAccumulatedCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            into: &counts,
            collectProfile: true,
            isCancelled: isCancelled
        )
        guard let profile = result.profile else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
        return (result.metadata, profile)
    }

    private func computeCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        collectProfile: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws -> (
        coverage: RunPlayPersonalHeatmapWorkoutCoverage,
        profile: RunPlayPersonalHeatmapCoverageProfile?
    ) {
        var translationNanoseconds: UInt64 = 0
        let operation = try withNativeCoverageOutput(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            collectProfile: collectProfile,
            isCancelled: isCancelled
        ) { output, metadata in
            let translationStart = collectProfile ? ContinuousClock.now : nil
            let cells = try translateNativeCells(
                output,
                isCancelled: isCancelled
            )
            if let translationStart {
                translationNanoseconds = RunPlayCoverageProfileClock.nanoseconds(
                    from: translationStart,
                    to: ContinuousClock.now
                )
            }

            return RunPlayPersonalHeatmapWorkoutCoverage(
                cells: cells,
                validProjectedPointCount: metadata.validProjectedPointCount,
                effectiveSegmentCount: metadata.effectiveSegmentCount,
                invalidIntervalCount: metadata.invalidIntervalCount
            )
        }

        let profile = operation.profile.map {
            RunPlayPersonalHeatmapCoverageProfile(
                requiredCellCount: operation.result.cells.count,
                nativeCallCount: $0.nativeCallCount,
                capacityRetryCount: $0.capacityRetryCount,
                outputAllocationNanoseconds: $0.outputAllocationNanoseconds,
                nativeNanoseconds: $0.nativeNanoseconds,
                translationNanoseconds: translationNanoseconds
            )
        }
        return (operation.result, profile)
    }

    private func computeAccumulatedCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        into counts: inout [PersonalHeatmapCellID: Int],
        collectProfile: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws -> (
        metadata: RunPlayPersonalHeatmapCoverageMetadata,
        profile: RunPlayPersonalHeatmapAccumulationProfile?
    ) {
        var consumptionNanoseconds: UInt64 = 0
        let operation = try withNativeCoverageOutput(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            collectProfile: collectProfile,
            isCancelled: isCancelled
        ) { output, metadata in
            let consumptionStart = collectProfile ? ContinuousClock.now : nil
            try accumulateNativeCells(
                output,
                into: &counts,
                isCancelled: isCancelled
            )
            if let consumptionStart {
                consumptionNanoseconds = RunPlayCoverageProfileClock.nanoseconds(
                    from: consumptionStart,
                    to: ContinuousClock.now
                )
            }
            return metadata
        }

        let profile = operation.profile.map {
            RunPlayPersonalHeatmapAccumulationProfile(
                cellCount: operation.result.cellCount,
                nativeCallCount: $0.nativeCallCount,
                capacityRetryCount: $0.capacityRetryCount,
                outputAllocationNanoseconds: $0.outputAllocationNanoseconds,
                nativeNanoseconds: $0.nativeNanoseconds,
                directCellConsumptionAndCountingNanoseconds: consumptionNanoseconds
            )
        }
        return (operation.result, profile)
    }

    @inline(__always)
    private func translateNativeCells(
        _ output: UnsafeBufferPointer<runplay.PersonalHeatmapCellIndex>,
        isCancelled: @Sendable () -> Bool
    ) throws -> [PersonalHeatmapCellID] {
        var cells: [PersonalHeatmapCellID] = []
        cells.reserveCapacity(output.count)
        guard var pointer = output.baseAddress else {
            return cells
        }

        var index = 0
        while index < output.count {
            if isCancelled() {
                throw CancellationError()
            }
            let remaining = output.count - index
            let chunkCount = min(2_048, remaining)
            for _ in 0..<chunkCount {
                let nativeCell = pointer.pointee
                cells.append(PersonalHeatmapCellID(x: nativeCell.x, y: nativeCell.y))
                pointer = pointer.advanced(by: 1)
            }
            index += chunkCount
        }
        return cells
    }

    @inline(__always)
    private func accumulateNativeCells(
        _ output: UnsafeBufferPointer<runplay.PersonalHeatmapCellIndex>,
        into counts: inout [PersonalHeatmapCellID: Int],
        isCancelled: @Sendable () -> Bool
    ) throws {
        guard var pointer = output.baseAddress else {
            return
        }

        var index = 0
        while index < output.count {
            if isCancelled() {
                throw CancellationError()
            }
            let remaining = output.count - index
            let chunkCount = min(2_048, remaining)
            for _ in 0..<chunkCount {
                let nativeCell = pointer.pointee
                let id = PersonalHeatmapCellID(x: nativeCell.x, y: nativeCell.y)
                counts[id, default: 0] += 1
                pointer = pointer.advanced(by: 1)
            }
            index += chunkCount
        }
    }

    /// Owns the caller-allocated output for one native operation and exposes a
    /// read-only view only to the nonescaping body. No pointer or native value
    /// leaves Interop.
    private func withNativeCoverageOutput<Result>(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        collectProfile: Bool,
        isCancelled: @Sendable () -> Bool,
        _ body: (
            UnsafeBufferPointer<runplay.PersonalHeatmapCellIndex>,
            RunPlayPersonalHeatmapCoverageMetadata
        ) throws -> Result
    ) throws -> (
        result: Result,
        profile: RunPlayPersonalHeatmapNativeCoverageProfile?
    ) {
        guard workoutIndex >= 0 && workoutIndex < workoutRanges.count else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
        if isCancelled() {
            throw CancellationError()
        }

        let range = workoutRanges[workoutIndex]
        if range.isEmpty {
            let metadata = RunPlayPersonalHeatmapCoverageMetadata(
                cellCount: 0,
                validProjectedPointCount: 0,
                effectiveSegmentCount: 0,
                invalidIntervalCount: 0
            )
            let empty = UnsafeBufferPointer<runplay.PersonalHeatmapCellIndex>(
                start: nil,
                count: 0
            )
            let result = try body(empty, metadata)
            let profile = collectProfile
                ? RunPlayPersonalHeatmapNativeCoverageProfile(
                    nativeCallCount: 0,
                    capacityRetryCount: 0,
                    outputAllocationNanoseconds: 0,
                    nativeNanoseconds: 0
                )
                : nil
            return (result, profile)
        }

        lock.lock()
        let cachedHint = capacityHints[workoutIndex]
        lock.unlock()

        let initialCapacity = max(
            cachedHint,
            Self.minimumInitialCapacity(for: range.count)
        )
        var allocationNanoseconds: UInt64 = 0
        var nativeNanoseconds: UInt64 = 0
        var nativeCallCount = 0
        var capacityRetryCount = 0

        let allocationStart = collectProfile ? ContinuousClock.now : nil
        var outputBuffer = ContiguousArray<runplay.PersonalHeatmapCellIndex>(
            repeating: runplay.PersonalHeatmapCellIndex(),
            count: initialCapacity
        )
        if let allocationStart {
            allocationNanoseconds += RunPlayCoverageProfileClock.nanoseconds(
                from: allocationStart,
                to: ContinuousClock.now
            )
        }

        let nativeStart = collectProfile ? ContinuousClock.now : nil
        var summary = invokeNativeCoverage(
            range: range,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            outputBuffer: &outputBuffer,
            capacity: initialCapacity
        )
        if let nativeStart {
            nativeNanoseconds += RunPlayCoverageProfileClock.nanoseconds(
                from: nativeStart,
                to: ContinuousClock.now
            )
        }
        nativeCallCount += 1

        if summary.status == .insufficient_output_capacity {
            capacityRetryCount += 1
            guard let requiredCapacity = Int(exactly: summary.required_cell_count),
                  requiredCapacity > 0 else {
                throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
            }

            let retryAllocationStart = collectProfile ? ContinuousClock.now : nil
            outputBuffer = ContiguousArray<runplay.PersonalHeatmapCellIndex>(
                repeating: runplay.PersonalHeatmapCellIndex(),
                count: requiredCapacity
            )
            if let retryAllocationStart {
                allocationNanoseconds += RunPlayCoverageProfileClock.nanoseconds(
                    from: retryAllocationStart,
                    to: ContinuousClock.now
                )
            }

            let retryNativeStart = collectProfile ? ContinuousClock.now : nil
            summary = invokeNativeCoverage(
                range: range,
                cellSizeMeters: cellSizeMeters,
                maximumIntervalMeters: maximumIntervalMeters,
                maximumCellsPerInterval: maximumCellsPerInterval,
                outputBuffer: &outputBuffer,
                capacity: requiredCapacity
            )
            if let retryNativeStart {
                nativeNanoseconds += RunPlayCoverageProfileClock.nanoseconds(
                    from: retryNativeStart,
                    to: ContinuousClock.now
                )
            }
            nativeCallCount += 1

            guard summary.status == .success else {
                throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
            }
        }

        if isCancelled() {
            throw CancellationError()
        }
        try validateSuccessfulStatus(summary.status)

        guard let cellCount = Int(exactly: summary.written_cell_count),
              let requiredCellCount = Int(exactly: summary.required_cell_count),
              let validProjectedPointCount = Int(exactly: summary.valid_projected_point_count),
              let effectiveSegmentCount = Int(exactly: summary.effective_segment_count),
              let invalidIntervalCount = Int(exactly: summary.invalid_interval_count),
              cellCount == requiredCellCount,
              cellCount >= 0,
              cellCount <= outputBuffer.count else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }

        lock.lock()
        capacityHints[workoutIndex] = cellCount
        lock.unlock()

        let metadata = RunPlayPersonalHeatmapCoverageMetadata(
            cellCount: cellCount,
            validProjectedPointCount: validProjectedPointCount,
            effectiveSegmentCount: effectiveSegmentCount,
            invalidIntervalCount: invalidIntervalCount
        )
        let result = try outputBuffer.withUnsafeBufferPointer { output in
            let writtenOutput = UnsafeBufferPointer(
                rebasing: output.prefix(cellCount)
            )
            return try body(writtenOutput, metadata)
        }
        let profile = collectProfile
            ? RunPlayPersonalHeatmapNativeCoverageProfile(
                nativeCallCount: nativeCallCount,
                capacityRetryCount: capacityRetryCount,
                outputAllocationNanoseconds: allocationNanoseconds,
                nativeNanoseconds: nativeNanoseconds
            )
            : nil
        return (result, profile)
    }

    private func validateSuccessfulStatus(
        _ status: runplay.PersonalHeatmapCoverageStatus
    ) throws {
        switch status {
        case .success:
            break
        case .invalid_configuration:
            throw RunPlayPersonalHeatmapCoverageBridgeError.invalidConfiguration
        case .allocation_failure:
            throw RunPlayPersonalHeatmapCoverageBridgeError.allocationFailure
        case .invalid_input_buffer,
             .invalid_output_buffer,
             .insufficient_output_capacity,
             .invalid_input_contract,
             .internal_failure:
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        @unknown default:
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
    }

    private static func minimumInitialCapacity(for inputCount: Int) -> Int {
        let cappedInputCount = min(max(0, inputCount), 131_072)
        return max(64, min(262_144, cappedInputCount * 2))
    }

    private func invokeNativeCoverage(
        range: Range<Int>,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        outputBuffer: inout ContiguousArray<runplay.PersonalHeatmapCellIndex>,
        capacity: Int
    ) -> runplay.PersonalHeatmapCoverageSummary {
        RunPlayPersonalHeatmapCoverageBridge.recordNativeInvocation()
        return nativeSamples.withUnsafeBufferPointer { sampleBuffer in
            outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                let basePtr = sampleBuffer.baseAddress?.advanced(by: range.lowerBound)
                return runplay.compute_personal_heatmap_workout_coverage(
                    basePtr,
                    range.count,
                    cellSizeMeters,
                    maximumIntervalMeters,
                    maximumCellsPerInterval,
                    outBuf.baseAddress,
                    capacity
                )
            }
        }
    }
}

/// Production bridge for per-workout personal heatmap coverage.
enum RunPlayPersonalHeatmapCoverageBridge {
    /// Test-only invocation counter for native per-workout coverage calls.
    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private static let invocationCounter = InvocationCounter()

    static var nativeInvocationCount: Int {
        invocationCounter.value
    }

    static func resetNativeInvocationCountForTests() {
        invocationCounter.reset()
    }

    fileprivate static func recordNativeInvocation() {
        invocationCounter.increment()
    }

    static func prepare(
        workoutRoutes: [[RoutePoint]],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapPreparedBatch {
        if isCancelled() {
            throw CancellationError()
        }

        var totalPoints = 0
        for route in workoutRoutes {
            totalPoints += route.count
        }

        var samples = ContiguousArray<runplay.PersonalHeatmapRouteSample>()
        samples.reserveCapacity(totalPoints)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(workoutRoutes.count)

        var pointCounter = 0
        for route in workoutRoutes {
            let start = samples.count
            for point in route {
                pointCounter += 1
                if pointCounter.isMultiple(of: 2_048), isCancelled() {
                    throw CancellationError()
                }

                guard let segIndex = Int64(exactly: point.routeSegmentIndex) else {
                    throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
                }

                samples.append(runplay.PersonalHeatmapRouteSample(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    route_segment_index: segIndex
                ))
            }
            let end = samples.count
            ranges.append(start..<end)
        }

        return RunPlayPersonalHeatmapPreparedBatch(
            nativeSamples: samples,
            workoutRanges: ranges
        )
    }
}
