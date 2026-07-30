import Foundation

internal import CxxStdlib
internal import RunPlayEngineCpp

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
            max(64, min(262_144, range.count * 2))
        }
    }

    var workoutCount: Int {
        workoutRanges.count
    }

    /// Production coverage call. Collects no timing.
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

    /// Diagnostic coverage call used only by the profiling harness.
    ///
    /// Runs the same implementation as `coverage(...)` — there is no second
    /// boundary implementation — and additionally reports how the call's time
    /// split between output allocation, native execution, and cell translation.
    ///
    /// `scripts/validate-cpp-boundaries.sh` enforces that no production source
    /// references this method or `RunPlayPersonalHeatmapCoverageProfile`.
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

    /// Single shared implementation of the coverage boundary.
    ///
    /// When `collectProfile` is `false` no clock is read, so ordinary
    /// production calls pay nothing beyond one branch per timed region.
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
        var allocationNanoseconds: UInt64 = 0
        var nativeNanoseconds: UInt64 = 0
        var translationNanoseconds: UInt64 = 0
        var nativeCallCount = 0
        var capacityRetryCount = 0

        guard workoutIndex >= 0 && workoutIndex < workoutRanges.count else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }

        if isCancelled() {
            throw CancellationError()
        }

        let range = workoutRanges[workoutIndex]
        if range.isEmpty {
            return (
                RunPlayPersonalHeatmapWorkoutCoverage(
                    cells: [],
                    validProjectedPointCount: 0,
                    effectiveSegmentCount: 0,
                    invalidIntervalCount: 0
                ),
                collectProfile
                    ? RunPlayPersonalHeatmapCoverageProfile(
                        requiredCellCount: 0,
                        nativeCallCount: 0,
                        capacityRetryCount: 0,
                        outputAllocationNanoseconds: 0,
                        nativeNanoseconds: 0,
                        translationNanoseconds: 0
                    )
                    : nil
            )
        }

        lock.lock()
        let initialHint = capacityHints[workoutIndex]
        lock.unlock()

        let initialCapacity = max(initialHint, max(64, min(262_144, range.count * 2)))

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
            let requiredCapacity = Int(summary.required_cell_count)
            guard requiredCapacity > 0 else {
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

            if summary.status != .success {
                throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
            }
        }

        if isCancelled() {
            throw CancellationError()
        }

        switch summary.status {
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

        let cellCount = Int(summary.written_cell_count)
        guard cellCount == Int(summary.required_cell_count) else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }

        lock.lock()
        capacityHints[workoutIndex] = cellCount
        lock.unlock()

        let translationStart = collectProfile ? ContinuousClock.now : nil
        var cells: [PersonalHeatmapCellID] = []
        cells.reserveCapacity(cellCount)

        for i in 0..<cellCount {
            if i.isMultiple(of: 2_048), isCancelled() {
                throw CancellationError()
            }
            let nativeCell = outputBuffer[i]
            cells.append(PersonalHeatmapCellID(x: nativeCell.x, y: nativeCell.y))
        }
        if let translationStart {
            translationNanoseconds += RunPlayCoverageProfileClock.nanoseconds(
                from: translationStart,
                to: ContinuousClock.now
            )
        }

        return (
            RunPlayPersonalHeatmapWorkoutCoverage(
                cells: cells,
                validProjectedPointCount: Int(summary.valid_projected_point_count),
                effectiveSegmentCount: Int(summary.effective_segment_count),
                invalidIntervalCount: Int(summary.invalid_interval_count)
            ),
            collectProfile
                ? RunPlayPersonalHeatmapCoverageProfile(
                    requiredCellCount: cellCount,
                    nativeCallCount: nativeCallCount,
                    capacityRetryCount: capacityRetryCount,
                    outputAllocationNanoseconds: allocationNanoseconds,
                    nativeNanoseconds: nativeNanoseconds,
                    translationNanoseconds: translationNanoseconds
                )
                : nil
        )
    }

    private func invokeNativeCoverage(
        range: Range<Int>,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        outputBuffer: inout ContiguousArray<runplay.PersonalHeatmapCellIndex>,
        capacity: Int
    ) -> runplay.PersonalHeatmapCoverageSummary {
        nativeSamples.withUnsafeBufferPointer { sampleBuffer in
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
