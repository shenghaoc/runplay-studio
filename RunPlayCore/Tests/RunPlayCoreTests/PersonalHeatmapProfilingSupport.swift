import Foundation
@testable import RunPlayCore

/// Timing decomposition of one direct accumulation call. Diagnostic only: the
/// production `accumulateCoverage` reads no clock. It lives in tests so no
/// profiling type ships in Core.
struct RunPlayPersonalHeatmapAccumulationProfile: Sendable {
    /// De-duplicated cell count the engine reported for this workout.
    let cellCount: Int
    /// Engine calls performed: 1 for a workout with samples, 0 for an empty one.
    let engineCallCount: Int
    /// Time spent inside the engine call.
    let engineNanoseconds: UInt64
    /// Time spent consuming the engine's cells and updating the Swift dictionary.
    let directCellConsumptionAndCountingNanoseconds: UInt64
}

extension RunPlayPersonalHeatmapPreparedBatch {
    /// Test-only mirror of `accumulateCoverage` that times its two stages.
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
        let engineStart = ContinuousClock.now
        let result = try engineCoverage(
            workoutIndex: workoutIndex,
            cellSizeMeters: cellSizeMeters,
            maximumIntervalMeters: maximumIntervalMeters,
            maximumCellsPerInterval: maximumCellsPerInterval,
            isCancelled: isCancelled
        )
        let engineEnd = ContinuousClock.now

        for cell in result.cells {
            counts[PersonalHeatmapCellID(x: cell.x, y: cell.y), default: 0] += 1
        }
        let consumptionEnd = ContinuousClock.now

        let metadata = RunPlayPersonalHeatmapCoverageMetadata(
            cellCount: result.cells.count,
            validProjectedPointCount: Int(result.validProjectedPointCount),
            effectiveSegmentCount: Int(result.effectiveSegmentCount),
            invalidIntervalCount: Int(result.invalidIntervalCount)
        )
        let profile = RunPlayPersonalHeatmapAccumulationProfile(
            cellCount: result.cells.count,
            engineCallCount: workoutRangeIsEmpty(workoutIndex) ? 0 : 1,
            engineNanoseconds: Self.nanoseconds(from: engineStart, to: engineEnd),
            directCellConsumptionAndCountingNanoseconds: Self.nanoseconds(from: engineEnd, to: consumptionEnd)
        )
        return (metadata, profile)
    }

    private static func nanoseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> UInt64 {
        let components = start.duration(to: end).components
        let value = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return value > 0 ? UInt64(value) : 0
    }
}
