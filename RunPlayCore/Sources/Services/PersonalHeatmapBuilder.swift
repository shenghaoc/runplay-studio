import Foundation

/// Errors produced by personal heatmap aggregation (excluding cancellation).
public enum PersonalHeatmapError: Error, Sendable, Equatable {
    case invalidConfiguration
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
              configuration.maximumRenderedCellCount >= 1 else {
            throw PersonalHeatmapError.invalidConfiguration
        }

        if isCancelled() { throw CancellationError() }

        // Pre-filter once so adaptive retries do not re-evaluate date policy.
        let prepared = try prepareWorkouts(workouts, configuration: configuration, isCancelled: isCancelled)

        var cellSize = configuration.cellSizeMeters
        var adaptiveRetries = 0
        let maxRetries = 16

        while true {
            if isCancelled() { throw CancellationError() }

            let pass = try aggregate(
                prepared: prepared,
                cellSizeMeters: cellSize,
                maximumIntervalMeters: configuration.maximumIntervalMeters,
                isCancelled: isCancelled
            )

            let filteredCounts = pass.counts.filter { $0.value >= configuration.minimumWorkoutCount }

            if filteredCounts.count <= configuration.maximumRenderedCellCount || adaptiveRetries >= maxRetries {
                return finalizeSnapshot(
                    counts: pass.counts,
                    filteredCounts: filteredCounts,
                    prepared: prepared,
                    requestedCellSize: configuration.cellSizeMeters,
                    effectiveCellSize: cellSize,
                    adaptiveRetries: adaptiveRetries,
                    invalidIntervals: pass.invalidIntervals,
                    configuration: configuration
                )
            }

            // Coarsen: double cell size and retry. Preserve all workouts.
            adaptiveRetries += 1
            cellSize *= 2
        }
    }

    // MARK: - Preparation

    private struct PreparedWorkout: Sendable {
        let id: UUID
        let distanceMeters: Double
        let projectedPoints: [(x: Double, y: Double, segment: Int)]
    }

    private struct PreparationResult: Sendable {
        let workouts: [PreparedWorkout]
        let totalCandidates: Int
        let excludedUndated: Int
        let excludedNoRoute: Int
    }

    private func prepareWorkouts(
        _ workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration,
        isCancelled: @Sendable () -> Bool
    ) throws -> PreparationResult {
        var prepared: [PreparedWorkout] = []
        prepared.reserveCapacity(workouts.count)
        var excludedUndated = 0
        var excludedNoRoute = 0

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

            // Project valid route points; keep segment indexes for gap safety.
            var projected: [(x: Double, y: Double, segment: Int)] = []
            projected.reserveCapacity(workout.routePoints.count)
            for point in workout.routePoints {
                guard GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude),
                      let xy = PersonalHeatmapProjection.project(
                        latitude: point.latitude,
                        longitude: point.longitude
                      ) else {
                    continue
                }
                projected.append((xy.x, xy.y, point.routeSegmentIndex))
            }

            guard !projected.isEmpty else {
                excludedNoRoute += 1
                continue
            }

            let distance = workout.summary.totalDistanceMeters
            let safeDistance = distance.isFinite && distance >= 0 ? distance : 0

            prepared.append(PreparedWorkout(
                id: workout.id,
                distanceMeters: safeDistance,
                projectedPoints: projected
            ))
        }

        return PreparationResult(
            workouts: prepared,
            totalCandidates: workouts.count,
            excludedUndated: excludedUndated,
            excludedNoRoute: excludedNoRoute
        )
    }

    /// Prefer metadata.startDate; fall back to first route-point timestamp.
    /// Returns nil when neither is trustworthy (missing / distant epoch sentinel).
    private func trustworthyDate(for workout: RunWorkout) -> Date? {
        if let start = workout.metadata.startDate {
            return start
        }
        // Fallback: first route point timestamp when present.
        // Empty routes have no date and will be excluded by no-route path first
        // for date-filtered modes that need a date.
        return workout.routePoints.first?.timestamp
    }

    // MARK: - Aggregation

    private struct AggregatePass: Sendable {
        /// Cell ID → distinct workout count.
        let counts: [PersonalHeatmapCellID: Int]
        let invalidIntervals: Int
    }

    private func aggregate(
        prepared: PreparationResult,
        cellSizeMeters: Double,
        maximumIntervalMeters: Double,
        isCancelled: @Sendable () -> Bool
    ) throws -> AggregatePass {
        var counts: [PersonalHeatmapCellID: Int] = [:]
        var invalidIntervals = 0

        for (index, workout) in prepared.workouts.enumerated() {
            if isCancelled() { throw CancellationError() }
            if index % 8 == 0, isCancelled() { throw CancellationError() }

            // Per-workout set: one contribution per cell for this workout.
            var visited = Set<PersonalHeatmapCellID>()
            visited.reserveCapacity(min(workout.projectedPoints.count * 2, 4_096))

            let points = workout.projectedPoints
            if points.count == 1 {
                // One-point workout: single cell, no traversal.
                if let x = PersonalHeatmapProjection.cellIndex(projected: points[0].x, cellSizeMeters: cellSizeMeters),
                   let y = PersonalHeatmapProjection.cellIndex(projected: points[0].y, cellSizeMeters: cellSizeMeters) {
                    visited.insert(PersonalHeatmapCellID(x: x, y: y))
                }
            } else {
                for i in 0..<(points.count - 1) {
                    if i % 512 == 0, isCancelled() { throw CancellationError() }

                    let a = points[i]
                    let b = points[i + 1]

                    // Never bridge route segments.
                    guard a.segment == b.segment else { continue }

                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()

                    // Zero-length: still count the cell (stationary sample).
                    if length == 0 {
                        if let x = PersonalHeatmapProjection.cellIndex(projected: a.x, cellSizeMeters: cellSizeMeters),
                           let y = PersonalHeatmapProjection.cellIndex(projected: a.y, cellSizeMeters: cellSizeMeters) {
                            visited.insert(PersonalHeatmapCellID(x: x, y: y))
                        }
                        continue
                    }

                    // Guard against malformed huge jumps.
                    if length > maximumIntervalMeters {
                        invalidIntervals += 1
                        continue
                    }

                    let intervalCells = try PersonalHeatmapGridTraversal.cells(
                        from: (a.x, a.y),
                        to: (b.x, b.y),
                        cellSizeMeters: cellSizeMeters,
                        isCancelled: isCancelled
                    )
                    for cell in intervalCells {
                        visited.insert(cell)
                    }
                }
            }

            for cell in visited {
                counts[cell, default: 0] += 1
            }
            // `visited` discarded at end of iteration.
        }

        return AggregatePass(counts: counts, invalidIntervals: invalidIntervals)
    }

    // MARK: - Finalize

    private func finalizeSnapshot(
        counts: [PersonalHeatmapCellID: Int],
        filteredCounts: [PersonalHeatmapCellID: Int],
        prepared: PreparationResult,
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

        let totalDistance = prepared.workouts.reduce(0.0) { $0 + $1.distanceMeters }
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
            includedWorkoutCount: prepared.workouts.count,
            totalDistanceMeters: totalDistance,
            maximumOverlap: maximumOverlap,
            requestedCellSizeMeters: requestedCellSize,
            effectiveCellSizeMeters: effectiveCellSize,
            resolutionWasAdjusted: adaptiveRetries > 0,
            excludedUndatedWorkoutCount: prepared.excludedUndated,
            excludedNoRouteWorkoutCount: prepared.excludedNoRoute
        )

        let diagnostics = PersonalHeatmapDiagnostics(
            totalCandidateWorkouts: prepared.totalCandidates,
            includedWorkouts: prepared.workouts.count,
            excludedUndatedWorkouts: prepared.excludedUndated,
            excludedNoRouteWorkouts: prepared.excludedNoRoute,
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
