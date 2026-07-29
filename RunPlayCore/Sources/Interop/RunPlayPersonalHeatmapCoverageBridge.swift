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

    func coverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapWorkoutCoverage {
        guard workoutIndex >= 0 && workoutIndex < workoutRanges.count else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }

        if isCancelled() {
            throw CancellationError()
        }

        let range = workoutRanges[workoutIndex]
        if range.isEmpty {
            return RunPlayPersonalHeatmapWorkoutCoverage(
                cells: [],
                validProjectedPointCount: 0,
                effectiveSegmentCount: 0,
                invalidIntervalCount: 0
            )
        }

        lock.lock()
        let initialHint = capacityHints[workoutIndex]
        lock.unlock()

        let initialCapacity = max(initialHint, max(64, min(262_144, range.count * 2)))
        var outputBuffer = ContiguousArray<runplay.PersonalHeatmapCellIndex>(
            repeating: runplay.PersonalHeatmapCellIndex(),
            count: initialCapacity
        )

        var summary = invokeNativeCoverage(
            range: range,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            outputBuffer: &outputBuffer,
            capacity: initialCapacity
        )

        if summary.status == .insufficient_output_capacity {
            let requiredCapacity = Int(summary.required_cell_count)
            guard requiredCapacity > 0 else {
                throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
            }
            outputBuffer = ContiguousArray<runplay.PersonalHeatmapCellIndex>(
                repeating: runplay.PersonalHeatmapCellIndex(),
                count: requiredCapacity
            )
            summary = invokeNativeCoverage(
                range: range,
                cellSizeMeters: cellSizeMeters,
                maximumIntervalMeters: maximumIntervalMeters,
                maximumCellsPerInterval: maximumCellsPerInterval,
                outputBuffer: &outputBuffer,
                capacity: requiredCapacity
            )
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

        var cells: [PersonalHeatmapCellID] = []
        cells.reserveCapacity(cellCount)

        for i in 0..<cellCount {
            if i.isMultiple(of: 2_048), isCancelled() {
                throw CancellationError()
            }
            let nativeCell = outputBuffer[i]
            cells.append(PersonalHeatmapCellID(x: nativeCell.x, y: nativeCell.y))
        }

        return RunPlayPersonalHeatmapWorkoutCoverage(
            cells: cells,
            validProjectedPointCount: Int(summary.valid_projected_point_count),
            effectiveSegmentCount: Int(summary.effective_segment_count),
            invalidIntervalCount: Int(summary.invalid_interval_count)
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
