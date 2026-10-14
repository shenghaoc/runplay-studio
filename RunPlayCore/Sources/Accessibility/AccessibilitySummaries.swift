import Foundation

// MARK: - Route map summary

/// Pure, nonvisual summary of a single workout route on the map.
public struct RouteAccessibilitySummary: Equatable, Sendable {
    public let distanceMeters: Double
    public let segmentCount: Int
    public let hasStart: Bool
    public let hasFinish: Bool
    public let currentDistanceMeters: Double?
    public let colorModeName: String
    public let coverageFraction: Double?
    public let metricCoverageLabel: String?

    public init(
        distanceMeters: Double,
        segmentCount: Int,
        hasStart: Bool,
        hasFinish: Bool,
        currentDistanceMeters: Double? = nil,
        colorModeName: String = WorkoutRouteColorMode.solid.displayName,
        coverageFraction: Double? = nil,
        metricCoverageLabel: String? = nil
    ) {
        self.distanceMeters = distanceMeters.isFinite ? max(0, distanceMeters) : 0
        self.segmentCount = max(0, segmentCount)
        self.hasStart = hasStart
        self.hasFinish = hasFinish
        self.currentDistanceMeters = currentDistanceMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.colorModeName = colorModeName
        self.coverageFraction = coverageFraction.flatMap { $0.isFinite ? min(max(0, $0), 1) : nil }
        self.metricCoverageLabel = metricCoverageLabel
    }

    /// Builds a summary from route points and optional colouring context.
    public static func make(
        routePoints: [RoutePoint],
        currentDistanceMeters: Double? = nil,
        colorModeName: String = WorkoutRouteColorMode.solid.displayName,
        coverageFraction: Double? = nil,
        metricCoverageLabel: String? = nil
    ) -> RouteAccessibilitySummary {
        let distance = routePoints.last?.distanceFromStartMeters ?? 0
        let segments = Set(routePoints.map(\.routeSegmentIndex)).count
        return RouteAccessibilitySummary(
            distanceMeters: distance,
            segmentCount: max(segments, routePoints.isEmpty ? 0 : 1),
            hasStart: !routePoints.isEmpty,
            hasFinish: routePoints.count >= 2,
            currentDistanceMeters: currentDistanceMeters,
            colorModeName: colorModeName,
            coverageFraction: coverageFraction,
            metricCoverageLabel: metricCoverageLabel
        )
    }

    public var spokenSummary: String {
        guard hasStart else {
            return coreLocalized("No GPS route available.")
        }
        var parts: [String] = [
            coreLocalized("Route \(formatDistance(distanceMeters))."),
            coreLocalized("Colour mode \(colorModeName).")
        ]
        if segmentCount > 1 {
            parts.append(coreLocalized("\(segmentCount) disconnected route sections."))
        }
        if hasStart { parts.append(coreLocalized("Start marker present.")) }
        if hasFinish { parts.append(coreLocalized("Finish marker present.")) }
        if let current = currentDistanceMeters {
            parts.append(coreLocalized("Replay position \(formatDistance(current))."))
        }
        if let label = metricCoverageLabel, !label.isEmpty {
            parts.append(label)
        } else if let coverage = coverageFraction, coverage < 0.92 {
            let percent = Int((coverage * 100).rounded())
            parts.append(coreLocalized("Metric data covers \(percent) percent of the route."))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Comparison map summary

/// Pure, nonvisual summary of a two-workout comparison map.
public struct ComparisonAccessibilitySummary: Equatable, Sendable {
    public let primaryName: String
    public let comparisonName: String
    public let commonDistanceMeters: Double
    public let selectedDistanceMeters: Double
    public let primaryTimeLabel: String?
    public let comparisonTimeLabel: String?
    public let deltaLabel: String?
    public let warnings: [String]
    public let alignmentModeName: String?
    public let routeAlignmentQualityName: String?
    public let matchedDistanceMeters: Double?
    public let primaryCoverageFraction: Double?
    public let comparisonCoverageFraction: Double?
    public let alignedProgressMeters: Double?
    public let mappedPrimaryDistanceMeters: Double?
    public let mappedComparisonDistanceMeters: Double?
    public let spatialSeparationMeters: Double?

    public init(
        primaryName: String,
        comparisonName: String,
        commonDistanceMeters: Double,
        selectedDistanceMeters: Double,
        primaryTimeLabel: String? = nil,
        comparisonTimeLabel: String? = nil,
        deltaLabel: String? = nil,
        warnings: [String] = [],
        alignmentModeName: String? = nil,
        routeAlignmentQualityName: String? = nil,
        matchedDistanceMeters: Double? = nil,
        primaryCoverageFraction: Double? = nil,
        comparisonCoverageFraction: Double? = nil,
        alignedProgressMeters: Double? = nil,
        mappedPrimaryDistanceMeters: Double? = nil,
        mappedComparisonDistanceMeters: Double? = nil,
        spatialSeparationMeters: Double? = nil
    ) {
        self.primaryName = primaryName
        self.comparisonName = comparisonName
        self.commonDistanceMeters = commonDistanceMeters.isFinite ? max(0, commonDistanceMeters) : 0
        self.selectedDistanceMeters = selectedDistanceMeters.isFinite ? max(0, selectedDistanceMeters) : 0
        self.primaryTimeLabel = primaryTimeLabel
        self.comparisonTimeLabel = comparisonTimeLabel
        self.deltaLabel = deltaLabel
        self.warnings = warnings
        self.alignmentModeName = alignmentModeName
        self.routeAlignmentQualityName = routeAlignmentQualityName
        self.matchedDistanceMeters = matchedDistanceMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.primaryCoverageFraction = primaryCoverageFraction.flatMap { $0.isFinite ? min(max(0, $0), 1) : nil }
        self.comparisonCoverageFraction = comparisonCoverageFraction.flatMap { $0.isFinite ? min(max(0, $0), 1) : nil }
        self.alignedProgressMeters = alignedProgressMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.mappedPrimaryDistanceMeters = mappedPrimaryDistanceMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.mappedComparisonDistanceMeters = mappedComparisonDistanceMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.spatialSeparationMeters = spatialSeparationMeters.flatMap { $0.isFinite ? max(0, $0) : nil }
    }

    public var spokenSummary: String {
        var parts: [String] = [
            coreLocalized("Comparison map."),
            coreLocalized("Primary P: \(primaryName)."),
            coreLocalized("Comparison C: \(comparisonName).")
        ]
        if let alignmentModeName {
            parts.append(coreLocalized("Alignment mode \(alignmentModeName)."))
        }
        if let routeAlignmentQualityName {
            parts.append(coreLocalized("Route alignment \(routeAlignmentQualityName)."))
        }
        if let matchedDistanceMeters {
            parts.append(coreLocalized("Matched distance \(formatDistance(matchedDistanceMeters))."))
        }
        if let primaryCoverageFraction, let comparisonCoverageFraction {
            let p = Int((primaryCoverageFraction * 100).rounded())
            let c = Int((comparisonCoverageFraction * 100).rounded())
            parts.append(coreLocalized("Coverage \(p) percent primary, \(c) percent comparison."))
        }
        if let alignedProgressMeters {
            parts.append(coreLocalized("Matched route progress \(formatDistance(alignedProgressMeters))."))
        }
        if let mappedPrimaryDistanceMeters, let mappedComparisonDistanceMeters {
            parts.append(coreLocalized(
                "Mapped distances \(formatDistance(mappedPrimaryDistanceMeters)) and \(formatDistance(mappedComparisonDistanceMeters))."
            ))
        } else {
            parts.append(coreLocalized("Common distance \(formatDistance(commonDistanceMeters))."))
            parts.append(coreLocalized("Selected distance \(formatDistance(selectedDistanceMeters))."))
        }
        if let spatialSeparationMeters {
            parts.append(coreLocalized("Matched positions \(Int(spatialSeparationMeters.rounded())) metres apart."))
        }
        if let primaryTimeLabel {
            parts.append(coreLocalized("Primary time \(primaryTimeLabel)."))
        }
        if let comparisonTimeLabel {
            parts.append(coreLocalized("Comparison time \(comparisonTimeLabel)."))
        }
        if let deltaLabel {
            parts.append(coreLocalized("Delta \(deltaLabel)."))
        }
        for warning in warnings where !warning.isEmpty {
            parts.append(warning)
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Heatmap summary

/// Pure, nonvisual summary of the Personal Heatmap workspace.
public struct HeatmapAccessibilitySummary: Equatable, Sendable {
    public let includedRunCount: Int
    public let totalDistanceMeters: Double
    public let maximumOverlap: Int
    public let requestedCellSizeMeters: Double
    public let effectiveCellSizeMeters: Double
    public let dateFilterDescription: String
    public let minimumRepeatCount: Int

    public init(
        includedRunCount: Int,
        totalDistanceMeters: Double,
        maximumOverlap: Int,
        requestedCellSizeMeters: Double,
        effectiveCellSizeMeters: Double,
        dateFilterDescription: String,
        minimumRepeatCount: Int
    ) {
        self.includedRunCount = max(0, includedRunCount)
        self.totalDistanceMeters = totalDistanceMeters.isFinite ? max(0, totalDistanceMeters) : 0
        self.maximumOverlap = max(0, maximumOverlap)
        self.requestedCellSizeMeters = requestedCellSizeMeters.isFinite ? max(0, requestedCellSizeMeters) : 0
        self.effectiveCellSizeMeters = effectiveCellSizeMeters.isFinite ? max(0, effectiveCellSizeMeters) : 0
        self.dateFilterDescription = dateFilterDescription
        self.minimumRepeatCount = max(1, minimumRepeatCount)
    }

    public var spokenSummary: String {
        var parts: [String] = [
            coreLocalized("Personal Heatmap."),
            coreLocalized("\(includedRunCount) runs included."),
            coreLocalized("Total distance \(formatDistance(totalDistanceMeters))."),
            coreLocalized("Maximum overlap \(maximumOverlap) runs."),
            coreLocalized("Requested cell size \(Int(requestedCellSizeMeters)) metres."),
            coreLocalized("Effective cell size \(Int(effectiveCellSizeMeters)) metres."),
            coreLocalized("Date filter \(dateFilterDescription)."),
            coreLocalized("Minimum \(minimumRepeatCount) runs per cell.")
        ]
        if requestedCellSizeMeters > 0,
           abs(effectiveCellSizeMeters - requestedCellSizeMeters) > 0.5 {
            parts.append(coreLocalized("Cell size was increased to stay within the render budget."))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Chart accessibility model

/// Series-level facts for a workout metric chart (not one element per GPS point).
public struct ChartAccessibilitySeries: Equatable, Sendable {
    public let name: String
    public let unit: String
    public let minimum: Double?
    public let maximum: Double?
    public let average: Double?
    public let currentValue: Double?
    public let pointCount: Int
    public let seriesCount: Int
    public let missingData: Bool

    public init(
        name: String,
        unit: String,
        minimum: Double?,
        maximum: Double?,
        average: Double?,
        currentValue: Double?,
        pointCount: Int,
        seriesCount: Int,
        missingData: Bool
    ) {
        self.name = name
        self.unit = unit
        self.minimum = Self.finite(minimum)
        self.maximum = Self.finite(maximum)
        self.average = Self.finite(average)
        self.currentValue = Self.finite(currentValue)
        self.pointCount = max(0, pointCount)
        self.seriesCount = max(0, seriesCount)
        self.missingData = missingData
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// Descriptor data for Swift Charts accessibility, independent of UIKit/AppKit.
public struct ChartAccessibilityModel: Equatable, Sendable {
    public let title: String
    public let xAxisTitle: String
    public let xAxisUnit: String
    public let yAxisTitle: String
    public let yAxisUnit: String
    public let series: ChartAccessibilitySeries
    public let totalDistanceMeters: Double
    public let gapCount: Int

    /// "Distance" in the app's language: the x-axis a workout metric chart
    /// plots against unless the caller names another. `@usableFromInline`
    /// so the public initializer can use it as a default argument.
    @usableFromInline
    static var defaultXAxisTitle: String { coreLocalized("Distance") }

    public init(
        title: String,
        xAxisTitle: String = ChartAccessibilityModel.defaultXAxisTitle,
        xAxisUnit: String = "km",
        yAxisTitle: String,
        yAxisUnit: String,
        series: ChartAccessibilitySeries,
        totalDistanceMeters: Double,
        gapCount: Int
    ) {
        self.title = title
        self.xAxisTitle = xAxisTitle
        self.xAxisUnit = xAxisUnit
        self.yAxisTitle = yAxisTitle
        self.yAxisUnit = yAxisUnit
        self.series = series
        self.totalDistanceMeters = totalDistanceMeters.isFinite ? max(0, totalDistanceMeters) : 0
        self.gapCount = max(0, gapCount)
    }

    public var spokenSummary: String {
        if series.missingData || series.pointCount == 0 {
            return coreLocalized("\(title). No data available.")
        }
        let xUnit = DisplayFormatter.unitSymbol(forToken: xAxisUnit)
        let yUnit = DisplayFormatter.unitSymbol(forToken: yAxisUnit)
        var parts: [String] = [
            title + ".",
            coreLocalized("\(xAxisTitle) in \(xUnit)."),
            coreLocalized("\(yAxisTitle) in \(yUnit).")
        ]
        if let minimum = series.minimum, let maximum = series.maximum {
            parts.append(coreLocalized(
                "Range \(formatMetric(minimum, unit: series.unit)) to \(formatMetric(maximum, unit: series.unit))."
            ))
        }
        if let average = series.average {
            parts.append(coreLocalized("Average \(formatMetric(average, unit: series.unit))."))
        }
        if let current = series.currentValue {
            parts.append(coreLocalized("At current replay position \(formatMetric(current, unit: series.unit))."))
        }
        if gapCount > 0 {
            parts.append(coreLocalized("\(gapCount) recording gaps break the series."))
        }
        parts.append(coreLocalized("Distance \(formatDistance(totalDistanceMeters))."))
        return parts.joined(separator: " ")
    }

    /// Returns the cached series aggregates with only the replay-position value
    /// replaced. This is O(1), so a 30 fps replay tick does not rescan every
    /// chart sample.
    public func updatingCurrentValue(_ currentValue: Double?) -> ChartAccessibilityModel {
        ChartAccessibilityModel(
            title: title,
            xAxisTitle: xAxisTitle,
            xAxisUnit: xAxisUnit,
            yAxisTitle: yAxisTitle,
            yAxisUnit: yAxisUnit,
            series: ChartAccessibilitySeries(
                name: series.name,
                unit: series.unit,
                minimum: series.minimum,
                maximum: series.maximum,
                average: series.average,
                currentValue: currentValue,
                pointCount: series.pointCount,
                seriesCount: series.seriesCount,
                missingData: series.missingData
            ),
            totalDistanceMeters: totalDistanceMeters,
            gapCount: gapCount
        )
    }

    /// Builds a model from precomputed finite chart samples (already gap-split).
    ///
    /// `aggregatesFromValues`, when non-nil, is the series used to compute
    /// the spoken minimum/maximum/average. `values` still drives the plot
    /// structure (point count, gap detection, missing-data flag). Pass this
    /// when the plotted line is a smoothed derivative and the descriptor
    /// must report the raw series' extremes so it doesn't contradict a
    /// panel showing the same metric on the same screen (e.g. the Power
    /// chart's smoothed line vs. the Power & Running Dynamics panel's raw
    /// Max Power).
    public static func make(
        metricName: String,
        unit: String,
        values: [Double],
        seriesIDs: [Int],
        currentValue: Double?,
        totalDistanceMeters: Double,
        aggregatesFromValues: [Double]? = nil
    ) -> ChartAccessibilityModel {
        let finite = values.filter(\.isFinite)
        let missing = finite.isEmpty
        let aggregateFinite = (aggregatesFromValues ?? values).filter(\.isFinite)
        let minV = aggregateFinite.min()
        let maxV = aggregateFinite.max()
        let avg: Double? = {
            guard !aggregateFinite.isEmpty else { return nil }
            // Pace averages can be misleading physiologically; still report
            // arithmetic mean of the aggregate source for orientation only.
            return aggregateFinite.reduce(0, +) / Double(aggregateFinite.count)
        }()
        let uniqueSeries = Set(seriesIDs).count
        let gapCount = max(0, uniqueSeries - 1)
        let series = ChartAccessibilitySeries(
            name: metricName,
            unit: unit,
            minimum: minV,
            maximum: maxV,
            average: avg,
            currentValue: currentValue,
            pointCount: finite.count,
            seriesCount: uniqueSeries,
            missingData: missing
        )
        return ChartAccessibilityModel(
            title: coreLocalized("\(metricName) chart"),
            yAxisTitle: metricName,
            yAxisUnit: unit,
            series: series,
            totalDistanceMeters: totalDistanceMeters,
            gapCount: gapCount
        )
    }
}

// MARK: - Tag mixed-state description

/// Accessibility wording for bulk-tag checkbox states.
public enum TagSelectionAccessibilityState: String, Sendable, Equatable {
    case unchecked
    case checked
    case mixed

    public var spokenValue: String {
        switch self {
        case .unchecked: return coreLocalized("Unchecked")
        case .checked: return coreLocalized("Checked")
        case .mixed: return coreLocalized("Mixed")
        }
    }
}

// MARK: - Trends summaries

/// Spoken overview of one Trends aggregation.
///
/// Contributor counts are always disclosed next to heart rate and ascent so a
/// sparse month is never heard as a complete trend.
public struct TrendsAccessibilitySummary: Equatable, Sendable {
    public let periodDescription: String
    public let rangeDescription: String
    public let scopeDescription: String
    public let includedRunCount: Int
    public let outOfWindowRunCount: Int
    public let undatedRunCount: Int
    public let aggregation: WorkoutTrendsAggregation

    public init(
        periodDescription: String,
        rangeDescription: String,
        scopeDescription: String,
        includedRunCount: Int,
        outOfWindowRunCount: Int,
        undatedRunCount: Int,
        aggregation: WorkoutTrendsAggregation
    ) {
        self.periodDescription = periodDescription
        self.rangeDescription = rangeDescription
        self.scopeDescription = scopeDescription
        self.includedRunCount = max(0, includedRunCount)
        self.outOfWindowRunCount = max(0, outOfWindowRunCount)
        self.undatedRunCount = max(0, undatedRunCount)
        self.aggregation = aggregation
    }

    public var spokenSummary: String {
        var parts: [String] = [
            coreLocalized("Trends by \(periodDescription)."),
            coreLocalized("Range \(rangeDescription)."),
            coreLocalized("Scope \(scopeDescription)."),
            coreLocalized("\(includedRunCount) runs in \(aggregation.buckets.count) periods."),
            coreLocalized("Total distance \(formatDistance(aggregation.totalDistanceMeters))."),
            coreLocalized("Total active time \(formatDuration(aggregation.totalActiveSeconds)).")
        ]
        if let pace = aggregation.meanActivePaceSecondsPerKilometer {
            // `formatMetric` already renders the "per kilometre" unit.
            parts.append(coreLocalized("Mean active pace \(formatMetric(pace, unit: "s/km"))."))
        } else {
            parts.append(coreLocalized("Mean active pace unavailable."))
        }
        if let heartRate = aggregation.meanHeartRateBPM {
            parts.append(coreLocalized("""
                Mean heart rate \(Int(heartRate)) beats per minute from \
                \(aggregation.heartRateContributingRuns) of \(includedRunCount) runs.
                """))
        } else {
            parts.append(coreLocalized("No heart-rate data."))
        }
        if let ascent = aggregation.totalAscentMeters {
            // Ascent is a climb, not a horizontal distance: metres always,
            // never rolled up into kilometres.
            parts.append(coreLocalized("""
                Total ascent \(formatMetric(ascent, unit: "m")) from \
                \(aggregation.ascentContributingRuns) of \(includedRunCount) runs.
                """))
        } else {
            parts.append(coreLocalized("No elevation data."))
        }
        if outOfWindowRunCount > 0 {
            parts.append(coreLocalized("\(outOfWindowRunCount) runs fall outside the selected range."))
        }
        if undatedRunCount > 0 {
            parts.append(coreLocalized("\(undatedRunCount) runs have no date and are excluded."))
        }
        return parts.joined(separator: " ")
    }
}

/// Spoken summary of one Trends chart series, gap-aware.
public struct TrendsChartAccessibilitySummary: Equatable, Sendable {
    public let metricName: String
    public let unit: String
    public let periodDescription: String
    /// One entry per period in window order; `nil` marks a gap.
    public let values: [Double?]
    /// Contributing runs per period, when the metric can be partial
    /// (heart rate, ascent); `nil` otherwise.
    public let contributorCounts: [Int]?
    /// Run count per period, for contributor comparisons.
    public let runCounts: [Int]

    public init(
        metricName: String,
        unit: String,
        periodDescription: String,
        values: [Double?],
        contributorCounts: [Int]? = nil,
        runCounts: [Int]
    ) {
        self.metricName = metricName
        self.unit = unit
        self.periodDescription = periodDescription
        self.values = values
        self.contributorCounts = contributorCounts
        self.runCounts = runCounts
    }

    public var spokenSummary: String {
        let populated = values.compactMap { $0 }
        var parts = [ coreLocalized("\(metricName) per \(periodDescription).") ]
        if populated.isEmpty {
            parts.append(coreLocalized("No data."))
            return parts.joined(separator: " ")
        }
        let gaps = values.count - populated.count
        if gaps > 0 {
            parts.append(coreLocalized("Data in \(populated.count) of \(values.count) periods."))
        } else {
            parts.append(coreLocalized("Data in all \(values.count) periods."))
        }
        if let minimum = populated.min(), let maximum = populated.max() {
            parts.append(coreLocalized(
                "Between \(formatMetric(minimum, unit: unit)) and \(formatMetric(maximum, unit: unit))."
            ))
        }
        if let latest = populated.last {
            parts.append(coreLocalized("Latest \(formatMetric(latest, unit: unit))."))
        }
        if let contributorCounts {
            var partialPeriods = 0
            for index in values.indices {
                guard values[index] != nil else { continue }
                guard index < contributorCounts.count, index < runCounts.count else { continue }
                if contributorCounts[index] < runCounts[index] {
                    partialPeriods += 1
                }
            }
            if partialPeriods > 0 {
                parts.append(coreLocalized("\(partialPeriods) periods use runs that carry only part of this metric."))
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Formatting helpers

private func formatDistance(_ meters: Double) -> String {
    guard meters.isFinite else { return coreLocalized("unavailable") }
    if meters >= 1000 {
        let kilometres = String(format: "%.2f", meters / 1000)
        return coreLocalized("\(kilometres) kilometres")
    }
    let metres = String(format: "%.0f", meters)
    return coreLocalized("\(metres) metres")
}

private func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return coreLocalized("unavailable") }
    let total = Int(seconds)
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    if hours > 0 {
        return coreLocalized("\(hours) h \(minutes) min")
    }
    return coreLocalized("\(minutes) min")
}

private func formatMetric(_ value: Double, unit: String) -> String {
    guard value.isFinite else { return coreLocalized("unavailable") }
    if unit == "s/km" || unit.contains("pace") {
        let mins = Int(value) / 60
        let secs = Int(value) % 60
        let pace = String(format: "%d:%02d", mins, secs)
        return coreLocalized("\(pace) per kilometre")
    }
    if unit == "bpm" {
        return coreLocalized("\(Int(value.rounded())) beats per minute")
    }
    if unit == "m" {
        return coreLocalized("\(Int(value.rounded())) metres")
    }
    if unit == "m/s" {
        let speed = String(format: "%.1f", value)
        return coreLocalized("\(speed) metres per second")
    }
    return "\(DisplayFormatter.formatDecimal(value, fractionDigits: 2)) \(DisplayFormatter.unitSymbol(forToken: unit))"
}

// MARK: - Personal records

/// Spoken summary of the Personal Records workspace table.
///
/// Built from the derived `PersonalRecordsSnapshot`; announces only the
/// standing records, never the full history, so it stays a single deliberate
/// description rather than a per-row announcement stream.
public struct PersonalRecordsAccessibilitySummary: Equatable, Sendable {
    public let scopeDescription: String
    public let snapshot: PersonalRecordsSnapshot

    public init(
        scopeDescription: String,
        snapshot: PersonalRecordsSnapshot
    ) {
        self.scopeDescription = scopeDescription
        self.snapshot = snapshot
    }

    public var spokenSummary: String {
        var parts: [String] = [
            coreLocalized("Personal records."),
            coreLocalized("Scope \(scopeDescription)."),
            coreLocalized("\(snapshot.includedWorkoutCount) runs in scope.")
        ]
        if snapshot.pendingBackfillWorkoutCount > 0 {
            parts.append(coreLocalized(
                "\(snapshot.pendingBackfillWorkoutCount) runs still need record computation."
            ))
        }
        for row in snapshot.rows {
            guard let best = row.best else {
                parts.append(coreLocalized("\(row.category.displayName) not attempted."))
                continue
            }
            if row.category.isPaceWindow {
                parts.append(coreLocalized("""
                    \(row.category.displayName) \(formatMetric(best.value, unit: "s/km")), \
                    set on \(spokenDate(best.date)).
                    """))
            } else if row.category == .biggestAscent {
                parts.append(coreLocalized("""
                    Biggest single-run ascent \(formatMetric(best.value, unit: "m")) \
                    on \(spokenDate(best.date)).
                    """))
            } else {
                parts.append(coreLocalized(
                    "Longest run \(formatDistance(best.value)) on \(spokenDate(best.date))."
                ))
            }
        }
        return parts.joined(separator: " ")
    }

    private func spokenDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day())
    }
}

// MARK: - Training load

/// Spoken summary of the training-load fitness/fatigue/form chart.
///
/// The disclosure rules mirror the model's honesty contract: estimated loads
/// are named as excluded unless opted in, and HR coverage over the displayed
/// window is spoken so the curve's trustworthiness is audible, not just
/// visible.
public struct TrainingLoadChartAccessibilitySummary: Equatable, Sendable {
    public let includesEstimatedLoads: Bool
    /// Measured days ÷ days with runs, or `nil` when no day carries a run.
    public let hrCoverageFraction: Double?
    public let dayCount: Int
    public let hrDayCount: Int
    public let noHRDataDayCount: Int
    public let latestLoad: Double?
    public let latestCTL: Double?
    public let latestATL: Double?
    public let latestTSB: Double?

    public init(
        includesEstimatedLoads: Bool,
        hrCoverageFraction: Double?,
        dayCount: Int,
        hrDayCount: Int,
        noHRDataDayCount: Int,
        latestLoad: Double?,
        latestCTL: Double?,
        latestATL: Double?,
        latestTSB: Double?
    ) {
        self.includesEstimatedLoads = includesEstimatedLoads
        self.hrCoverageFraction = hrCoverageFraction
        self.dayCount = dayCount
        self.hrDayCount = hrDayCount
        self.noHRDataDayCount = noHRDataDayCount
        self.latestLoad = latestLoad
        self.latestCTL = latestCTL
        self.latestATL = latestATL
        self.latestTSB = latestTSB
    }

    public var spokenSummary: String {
        var parts = [coreLocalized("Training load by day.")]
        guard dayCount > 0, let latestCTL else {
            parts.append(coreLocalized("No data."))
            return parts.joined(separator: " ")
        }
        if let latestLoad {
            parts.append(coreLocalized("Latest daily load \(Int(latestLoad.rounded())) TRIMP."))
        }
        parts.append(coreLocalized("Fitness \(Int(latestCTL.rounded()))."))
        if let latestATL {
            parts.append(coreLocalized("Fatigue \(Int(latestATL.rounded()))."))
        }
        if let latestTSB {
            let signed = latestTSB >= 0 ? "+" : ""
            let form = "\(signed)\(Int(latestTSB.rounded()))"
            parts.append(coreLocalized("Form \(form)."))
        }
        // The bias disclosure is spoken in both modes. The shading on the
        // chart does not depend on the opt-in — an unmeasured day is still
        // unmeasured when an invented value is standing in for it — so the
        // spoken channel must not disclose it in only one mode.
        if includesEstimatedLoads {
            parts.append(coreLocalized("Estimated loads are included in the model on your explicit request; they are invented values and make the curve less trustworthy."))
            if noHRDataDayCount > 0 {
                parts.append(coreLocalized("\(noHRDataDayCount) days with runs have no measured heart rate; where no estimate stands in, the model decays as if you had rested."))
            }
        } else if noHRDataDayCount > 0 {
            parts.append(coreLocalized("\(noHRDataDayCount) days with runs have no heart rate and contribute nothing to the model."))
            parts.append(coreLocalized("The model has no load for those days and decays as if you had rested, so that stretch reads as lost fitness and gained freshness."))
        }
        if let coverage = hrCoverageFraction {
            parts.append(coreLocalized("Heart-rate coverage \(Int((coverage * 100).rounded())) percent of days with runs."))
        }
        return parts.joined(separator: " ")
    }

    /// Hover/scrub phrase for one day.
    ///
    /// The day's kind is passed rather than a `hasHRData` flag because the
    /// readout has to separate the two zeroes the model cannot: a rest day is
    /// a measured zero — no run happened — while an unknown-load day is an
    /// unmeasured one, a run the model has no load for. Both integrate as
    /// zero; only one of them is a fact about the training.
    public static func dayPhrase(
        contribution: TrainingLoadDay.Contribution,
        load: Double,
        estimatedLoad: Bool,
        ctl: Double,
        atl: Double,
        tsb: Double
    ) -> String {
        var parts: [String] = []
        switch contribution {
        case .hrDay:
            parts.append(coreLocalized("Load \(Int(load.rounded())) TRIMP"))
        case .noHRData where estimatedLoad:
            parts.append(coreLocalized("Load \(Int(load.rounded())) TRIMP, estimated, not in model"))
        case .noHRData:
            parts.append(coreLocalized("No heart-rate load, modelled as rest"))
        case .restDay:
            parts.append(coreLocalized("Rest day"))
        }
        parts.append(coreLocalized("fitness \(Int(ctl.rounded()))"))
        parts.append(coreLocalized("fatigue \(Int(atl.rounded()))"))
        let signed = tsb >= 0 ? "+" : ""
        let form = "\(signed)\(Int(tsb.rounded()))"
        parts.append(coreLocalized("form \(form)"))
        return parts.joined(separator: ", ")
    }
}
