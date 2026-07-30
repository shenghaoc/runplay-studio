import Foundation

/// Errors produced by personal heatmap aggregation (excluding cancellation).
public enum PersonalHeatmapError: Error, Sendable, Equatable {
    case invalidConfiguration
}

/// Bounded allocation hints for the Swift cross-workout counts dictionary.
///
/// These values influence reservation only. They never constrain aggregation,
/// rendered output, or any public product limit.
enum PersonalHeatmapAggregationCapacityPolicy {
    static let minimumHint = 64
    static let maximumHint = 262_144
    static let renderedCellScale = 64

    static func cappedRoutePointCount(in workouts: [RunWorkout]) -> Int {
        cappedRoutePointCount(
            routePointCounts: workouts.lazy.map { $0.routePoints.count }
        )
    }

    static func cappedRoutePointCount<Counts: Sequence>(
        routePointCounts: Counts
    ) -> Int where Counts.Element == Int {
        var total = 0
        for count in routePointCounts {
            let nonnegativeCount = max(0, count)
            let remaining = maximumHint - total
            if nonnegativeCount >= remaining {
                return maximumHint
            }
            total += nonnegativeCount
        }
        return total
    }

    static func renderedBudgetBound(maximumRenderedCellCount: Int) -> Int {
        guard maximumRenderedCellCount > 0 else {
            return minimumHint
        }
        if maximumRenderedCellCount >= maximumHint / renderedCellScale {
            return maximumHint
        }
        return max(minimumHint, maximumRenderedCellCount * renderedCellScale)
    }

    static func initialHint(
        cappedTotalRoutePointCount: Int,
        maximumRenderedCellCount: Int
    ) -> Int {
        boundedHint(
            candidate: max(0, cappedTotalRoutePointCount),
            maximumRenderedCellCount: maximumRenderedCellCount
        )
    }

    static func laterPassHint(
        previousAggregatedCellCount: Int,
        maximumRenderedCellCount: Int
    ) -> Int {
        let nonnegativeCount = max(0, previousAggregatedCellCount)
        let roundedUpHalf = nonnegativeCount / 2 + nonnegativeCount % 2
        return boundedHint(
            candidate: roundedUpHalf,
            maximumRenderedCellCount: maximumRenderedCellCount
        )
    }

    private static func boundedHint(
        candidate: Int,
        maximumRenderedCellCount: Int
    ) -> Int {
        let budgetBound = renderedBudgetBound(
            maximumRenderedCellCount: maximumRenderedCellCount
        )
        return min(maximumHint, max(minimumHint, min(candidate, budgetBound)))
    }
}

/// Platform-neutral builder that aggregates distinct-workout route coverage
/// into a personal heatmap snapshot.
///
/// ## Intensity semantics
///
/// Primary heat for each cell is the number of **distinct included workouts**
/// whose route traverses that cell. Within one workout, revisiting a cell
/// (loops, traffic lights, dense GPS) contributes at most once.
///
/// ## Gap safety
///
/// Intervals are rasterized only between adjacent points that share the same
/// `routeSegmentIndex`. Recording pauses, track boundaries, and inferred gaps
/// never create a fake hot corridor.
///
/// ## Adaptive resolution
///
/// When the number of rendered cells (after the minimum-repeat filter) exceeds
/// `maximumRenderedCellCount`, the builder doubles the cell size and retries
/// until the budget is met or a hard iteration limit is reached. All included
/// workouts are preserved; cells are never randomly dropped.
public struct PersonalHeatmapBuilder: Sendable {

    public init() {}

    /// Build a heatmap snapshot from the current library snapshot.
    ///
    /// - Parameters:
    ///   - workouts: Library workouts (not modified).
    ///   - configuration: Requested filters and resolution.
    ///   - isCancelled: Cooperative cancellation checked between workouts and
    ///     during long rasterization / adaptive retries.
    /// - Throws: `CancellationError` when cancelled; never wraps cancellation
    ///   as a generic failure.
    public func build(
        workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> PersonalHeatmapSnapshot {
        guard configuration.cellSizeMeters.isFinite,
              configuration.cellSizeMeters > 0,
              configuration.minimumWorkoutCount >= 1,
              configuration.maximumRenderedCellCount >= 1,
              configuration.maximumIntervalMeters.isFinite,
              configuration.maximumIntervalMeters > 0 else {
            throw PersonalHeatmapError.invalidConfiguration
        }

        if isCancelled() { throw CancellationError() }

        // Pre-filter date policy once so adaptive retries do not re-evaluate date policy.
        let dateFiltered = try filterDateEligibleWorkouts(
            workouts,
            configuration: configuration,
            isCancelled: isCancelled
        )

        let preparedBatch = try RunPlayPersonalHeatmapCoverageBridge.prepare(
            workoutRoutes: dateFiltered.workouts.map { $0.routePoints },
            isCancelled: isCancelled
        )

        var cellSize = configuration.cellSizeMeters
        var adaptiveRetries = 0
        let maxRetries = 16
        var capacityHint = PersonalHeatmapAggregationCapacityPolicy.initialHint(
            cappedTotalRoutePointCount: PersonalHeatmapAggregationCapacityPolicy.cappedRoutePointCount(
                in: dateFiltered.workouts
            ),
            maximumRenderedCellCount: configuration.maximumRenderedCellCount
        )

        while true {
            if isCancelled() { throw CancellationError() }

            let pass = try aggregatePass(
                workouts: dateFiltered.workouts,
                preparedBatch: preparedBatch,
                cellSizeMeters: cellSize,
                maximumIntervalMeters: configuration.maximumIntervalMeters,
                capacityHint: capacityHint,
                isCancelled: isCancelled
            )

            let filteredCounts = pass.counts.filter { $0.value >= configuration.minimumWorkoutCount }

            if filteredCounts.count <= configuration.maximumRenderedCellCount || adaptiveRetries >= maxRetries {
                return finalizeSnapshot(
                    counts: pass.counts,
                    filteredCounts: filteredCounts,
                    totalCandidates: workouts.count,
                    includedWorkouts: pass.includedWorkoutCount,
                    totalDistanceMeters: pass.totalDistanceMeters,
                    excludedUndated: dateFiltered.excludedUndated,
                    excludedNoRoute: dateFiltered.workouts.count - pass.includedWorkoutCount,
                    requestedCellSize: configuration.cellSizeMeters,
                    effectiveCellSize: cellSize,
                    adaptiveRetries: adaptiveRetries,
                    invalidIntervals: pass.invalidIntervals,
                    configuration: configuration
                )
            }

            // Coarsen: double cell size and retry. Preserve all workouts.
            adaptiveRetries += 1
            capacityHint = PersonalHeatmapAggregationCapacityPolicy.laterPassHint(
                previousAggregatedCellCount: pass.counts.count,
                maximumRenderedCellCount: configuration.maximumRenderedCellCount
            )
            cellSize *= 2
        }
    }

    // MARK: - Preparation

    private struct DateFilterResult: Sendable {
        let workouts: [RunWorkout]
        let excludedUndated: Int
    }

    private func filterDateEligibleWorkouts(
        _ workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration,
        isCancelled: @Sendable () -> Bool
    ) throws -> DateFilterResult {
        var eligible: [RunWorkout] = []
        eligible.reserveCapacity(workouts.count)
        var excludedUndated = 0

        for (index, workout) in workouts.enumerated() {
            if index % 32 == 0, isCancelled() {
                throw CancellationError()
            }

            // Date policy.
            let date = trustworthyDate(for: workout)
            switch configuration.dateFilter {
            case .allTime:
                break
            case .range(let start, let end):
                guard let date else {
                    excludedUndated += 1
                    continue
                }
                if date < start || date > end {
                    continue
                }
            }

            eligible.append(workout)
        }

        return DateFilterResult(
            workouts: eligible,
            excludedUndated: excludedUndated
        )
    }

    /// Prefer metadata.startDate; fall back to first route-point timestamp.
    /// Returns nil when neither is trustworthy (missing / distant epoch sentinel).
    private func trustworthyDate(for workout: RunWorkout) -> Date? {
        if let start = workout.metadata.startDate {
            return start
        }
        return workout.routePoints.first?.timestamp
    }

    // MARK: - Aggregation

    private struct AggregatePassResult: Sendable {
        let counts: [PersonalHeatmapCellID: Int]
        let includedWorkoutCount: Int
        let totalDistanceMeters: Double
        let invalidIntervals: Int
    }

    private func aggregatePass(
        workouts: [RunWorkout],
        preparedBatch: RunPlayPersonalHeatmapPreparedBatch,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        capacityHint: Int,
        isCancelled: @Sendable () -> Bool
    ) throws -> AggregatePassResult {
        var counts: [PersonalHeatmapCellID: Int] = [:]
        counts.reserveCapacity(capacityHint)
        var invalidIntervals = 0
        var includedWorkoutCount = 0
        var totalDistanceMeters = 0.0

        for (index, workout) in workouts.enumerated() {
            if isCancelled() { throw CancellationError() }

            let metadata = try preparedBatch.accumulateCoverage(
                workoutIndex: index,
                cellSizeMeters: cellSizeMeters,
                maximumIntervalMeters: maximumIntervalMeters,
                maximumCellsPerInterval: PersonalHeatmapGridTraversal.defaultMaximumCellsPerInterval,
                into: &counts,
                isCancelled: isCancelled
            )

            if metadata.cellCount == 0 {
                continue
            }

            includedWorkoutCount += 1
            let distance = workout.summary.totalDistanceMeters
            totalDistanceMeters += (distance.isFinite && distance >= 0 ? distance : 0)
            invalidIntervals += metadata.invalidIntervalCount
        }

        return AggregatePassResult(
            counts: counts,
            includedWorkoutCount: includedWorkoutCount,
            totalDistanceMeters: totalDistanceMeters,
            invalidIntervals: invalidIntervals
        )
    }

    // MARK: - Finalize

    private func finalizeSnapshot(
        counts: [PersonalHeatmapCellID: Int],
        filteredCounts: [PersonalHeatmapCellID: Int],
        totalCandidates: Int,
        includedWorkouts: Int,
        totalDistanceMeters: Double,
        excludedUndated: Int,
        excludedNoRoute: Int,
        requestedCellSize: Double,
        effectiveCellSize: Double,
        adaptiveRetries: Int,
        invalidIntervals: Int,
        configuration: PersonalHeatmapConfiguration
    ) -> PersonalHeatmapSnapshot {
        let maximumOverlap = counts.values.max() ?? 0
        let intensityDenominator = log1p(Double(max(maximumOverlap, 1)))

        var cells: [PersonalHeatmapCell] = []
        cells.reserveCapacity(filteredCounts.count)

        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity

        // Deterministic order by cell ID.
        let sortedIDs = filteredCounts.keys.sorted()
        for id in sortedIDs {
            guard let workoutCount = filteredCounts[id],
                  let bounds = PersonalHeatmapProjection.cellBounds(id: id, cellSizeMeters: effectiveCellSize) else {
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

        let heatmapBounds: PersonalHeatmapBounds?
        if cells.isEmpty {
            heatmapBounds = nil
        } else {
            heatmapBounds = PersonalHeatmapBounds(
                minLatitude: minLat,
                maxLatitude: maxLat,
                minLongitude: minLon,
                maxLongitude: maxLon
            )
        }

        let effectiveConfiguration = PersonalHeatmapConfiguration(
            dateFilter: configuration.dateFilter,
            cellSizeMeters: effectiveCellSize,
            minimumWorkoutCount: configuration.minimumWorkoutCount,
            maximumRenderedCellCount: configuration.maximumRenderedCellCount,
            maximumIntervalMeters: configuration.maximumIntervalMeters
        )

        let statistics = PersonalHeatmapStatistics(
            includedWorkoutCount: includedWorkouts,
            totalDistanceMeters: totalDistanceMeters,
            maximumOverlap: maximumOverlap,
            requestedCellSizeMeters: requestedCellSize,
            effectiveCellSizeMeters: effectiveCellSize,
            resolutionWasAdjusted: adaptiveRetries > 0,
            excludedUndatedWorkoutCount: excludedUndated,
            excludedNoRouteWorkoutCount: excludedNoRoute
        )

        let diagnostics = PersonalHeatmapDiagnostics(
            totalCandidateWorkouts: totalCandidates,
            includedWorkouts: includedWorkouts,
            excludedUndatedWorkouts: excludedUndated,
            excludedNoRouteWorkouts: excludedNoRoute,
            invalidRouteIntervalsSkipped: invalidIntervals,
            adaptiveResolutionRetries: adaptiveRetries,
            requestedCellSizeMeters: requestedCellSize,
            effectiveCellSizeMeters: effectiveCellSize,
            aggregatedCellCount: counts.count,
            renderedCellCount: cells.count
        )

        return PersonalHeatmapSnapshot(
            cells: cells,
            statistics: statistics,
            diagnostics: diagnostics,
            configuration: effectiveConfiguration,
            bounds: heatmapBounds
        )
    }
}
