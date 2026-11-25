import Foundation

internal import RunPlayEngine

/// Pure-Swift summary of one per-workout coverage operation.
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

/// Errors raised by the personal heatmap coverage adapter.
enum RunPlayPersonalHeatmapCoverageBridgeError: Error, Equatable {
    case invalidConfiguration
    case allocationFailure
    case engineContractViolation
}

/// Engine route samples for a set of workouts, converted once.
///
/// Created once per date-eligible workout batch so adaptive resolution retries
/// do not convert Swift `RoutePoint` values again. Immutable after creation.
final class RunPlayPersonalHeatmapPreparedBatch: Sendable {
    private let samples: [PersonalHeatmapRouteSample]
    private let workoutRanges: [Range<Int>]

    init(samples: [PersonalHeatmapRouteSample], workoutRanges: [Range<Int>]) {
        self.samples = samples
        self.workoutRanges = workoutRanges
    }

    var workoutCount: Int {
        workoutRanges.count
    }

    /// Whether a workout has no samples, so its coverage makes no engine call.
    func workoutRangeIsEmpty(_ workoutIndex: Int) -> Bool {
        workoutRanges[workoutIndex].isEmpty
    }

    /// Materializes the cell array for callers that need it (tests and the
    /// compatibility surface). Production aggregation uses `accumulateCoverage`.
    func coverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapWorkoutCoverage {
        let result = try engineCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            isCancelled: isCancelled
        )
        var cells: [PersonalHeatmapCellID] = []
        cells.reserveCapacity(result.cells.count)
        try Self.forEachChunk(of: result.cells, isCancelled: isCancelled) { cell in
            cells.append(PersonalHeatmapCellID(x: cell.x, y: cell.y))
        }
        return RunPlayPersonalHeatmapWorkoutCoverage(
            cells: cells,
            validProjectedPointCount: Int(result.validProjectedPointCount),
            effectiveSegmentCount: Int(result.effectiveSegmentCount),
            invalidIntervalCount: Int(result.invalidIntervalCount)
        )
    }

    /// Production aggregation call. The engine's cells increment the caller's
    /// cross-workout dictionary directly; no per-workout `PersonalHeatmapCellID`
    /// array is created.
    func accumulateCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        into counts: inout [PersonalHeatmapCellID: Int],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapCoverageMetadata {
        let result = try engineCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            isCancelled: isCancelled
        )
        try Self.forEachChunk(of: result.cells, isCancelled: isCancelled) { cell in
            counts[PersonalHeatmapCellID(x: cell.x, y: cell.y), default: 0] += 1
        }
        return RunPlayPersonalHeatmapCoverageMetadata(
            cellCount: result.cells.count,
            validProjectedPointCount: Int(result.validProjectedPointCount),
            effectiveSegmentCount: Int(result.effectiveSegmentCount),
            invalidIntervalCount: Int(result.invalidIntervalCount)
        )
    }

    /// One engine call for one workout. An empty workout makes no call.
    func engineCoverage(
        workoutIndex: Int,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        maximumCellsPerInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> PersonalHeatmapCoverageResult {
        guard workoutIndex >= 0 && workoutIndex < workoutRanges.count else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
        if isCancelled() { throw CancellationError() }

        let range = workoutRanges[workoutIndex]
        if range.isEmpty { return PersonalHeatmapCoverageResult() }

        NativeCallObserver.record(.personalHeatmapCoverage)
        let workoutSamples = samples[range]
        let result: PersonalHeatmapCoverageResult
        do {
            // `size_t` in the C++ signature: a negative Int keeps its two's-complement meaning.
            result = try PersonalHeatmapCoverage.compute(
                samples: workoutSamples.span,
                cellSizeMeters: cellSizeMeters,
                maximumIntervalMeters: maximumIntervalMeters,
                maximumCellsPerInterval: UInt(bitPattern: maximumCellsPerInterval)
            )
        } catch {
            switch error {
            case .invalidConfiguration: throw RunPlayPersonalHeatmapCoverageBridgeError.invalidConfiguration
            case .invalidInputContract, .internalFailure:
                throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
            }
        }
        if isCancelled() { throw CancellationError() }
        guard Int(exactly: result.validProjectedPointCount) != nil,
              Int(exactly: result.effectiveSegmentCount) != nil,
              Int(exactly: result.invalidIntervalCount) != nil
        else {
            throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
        }
        return result
    }

    /// Visits cells in chunks, checking cancellation between chunks.
    @inline(__always)
    private static func forEachChunk(
        of cells: [PersonalHeatmapCellIndex],
        isCancelled: @Sendable () -> Bool,
        _ body: (PersonalHeatmapCellIndex) -> Void
    ) throws {
        var index = 0
        while index < cells.count {
            if isCancelled() { throw CancellationError() }
            let end = min(cells.count, index + 2_048)
            while index < end {
                body(cells[index])
                index += 1
            }
        }
    }
}

/// Production adapter for per-workout personal heatmap coverage.
enum RunPlayPersonalHeatmapCoverageBridge {
    static func prepare(
        workoutRoutes: [[RoutePoint]],
        isCancelled: @Sendable () -> Bool
    ) throws -> RunPlayPersonalHeatmapPreparedBatch {
        if isCancelled() { throw CancellationError() }

        var totalPoints = 0
        for route in workoutRoutes { totalPoints += route.count }

        var samples = [PersonalHeatmapRouteSample]()
        samples.reserveCapacity(totalPoints)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(workoutRoutes.count)

        var pointCounter = 0
        for route in workoutRoutes {
            let start = samples.count
            for point in route {
                pointCounter += 1
                if pointCounter.isMultiple(of: 2_048), isCancelled() { throw CancellationError() }

                guard let segmentIndex = Int64(exactly: point.routeSegmentIndex) else {
                    throw RunPlayPersonalHeatmapCoverageBridgeError.engineContractViolation
                }
                samples.append(PersonalHeatmapRouteSample(
                    latitude: point.latitude, longitude: point.longitude, routeSegmentIndex: segmentIndex
                ))
            }
            ranges.append(start..<samples.count)
        }

        return RunPlayPersonalHeatmapPreparedBatch(samples: samples, workoutRanges: ranges)
    }
}
