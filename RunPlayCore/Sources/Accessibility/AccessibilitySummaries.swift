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
        colorModeName: String = "Solid",
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
        colorModeName: String = "Solid",
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
            return "No GPS route available."
        }
        var parts: [String] = [
            "Route \(formatDistance(distanceMeters)).",
            "Colour mode \(colorModeName)."
        ]
        if segmentCount > 1 {
            parts.append("\(segmentCount) disconnected route sections.")
        }
        if hasStart { parts.append("Start marker present.") }
        if hasFinish { parts.append("Finish marker present.") }
        if let current = currentDistanceMeters {
            parts.append("Replay position \(formatDistance(current)).")
        }
        if let label = metricCoverageLabel, !label.isEmpty {
            parts.append(label)
        } else if let coverage = coverageFraction, coverage < 0.92 {
            let percent = Int((coverage * 100).rounded())
            parts.append("Metric data covers \(percent) percent of the route.")
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
            "Comparison map.",
            "Primary P: \(primaryName).",
            "Comparison C: \(comparisonName)."
        ]
        if let alignmentModeName {
            parts.append("Alignment mode \(alignmentModeName).")
        }
        if let routeAlignmentQualityName {
            parts.append("Route alignment \(routeAlignmentQualityName).")
        }
        if let matchedDistanceMeters {
            parts.append("Matched distance \(formatDistance(matchedDistanceMeters)).")
        }
        if let primaryCoverageFraction, let comparisonCoverageFraction {
            let p = Int((primaryCoverageFraction * 100).rounded())
            let c = Int((comparisonCoverageFraction * 100).rounded())
            parts.append("Coverage \(p) percent primary, \(c) percent comparison.")
        }
        if let alignedProgressMeters {
            parts.append("Matched route progress \(formatDistance(alignedProgressMeters)).")
        }
        if let mappedPrimaryDistanceMeters, let mappedComparisonDistanceMeters {
            parts.append(
                "Mapped distances \(formatDistance(mappedPrimaryDistanceMeters)) and \(formatDistance(mappedComparisonDistanceMeters))."
            )
        } else {
            parts.append("Common distance \(formatDistance(commonDistanceMeters)).")
            parts.append("Selected distance \(formatDistance(selectedDistanceMeters)).")
        }
        if let spatialSeparationMeters {
            parts.append("Matched positions \(Int(spatialSeparationMeters.rounded())) metres apart.")
        }
        if let primaryTimeLabel {
            parts.append("Primary time \(primaryTimeLabel).")
        }
        if let comparisonTimeLabel {
            parts.append("Comparison time \(comparisonTimeLabel).")
        }
        if let deltaLabel {
            parts.append("Delta \(deltaLabel).")
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
            "Personal Heatmap.",
            "\(includedRunCount) runs included.",
            "Total distance \(formatDistance(totalDistanceMeters)).",
            "Maximum overlap \(maximumOverlap) runs.",
            "Requested cell size \(Int(requestedCellSizeMeters)) metres.",
            "Effective cell size \(Int(effectiveCellSizeMeters)) metres.",
            "Date filter \(dateFilterDescription).",
            "Minimum \(minimumRepeatCount) runs per cell."
        ]
        if requestedCellSizeMeters > 0,
           abs(effectiveCellSizeMeters - requestedCellSizeMeters) > 0.5 {
            parts.append("Cell size was increased to stay within the render budget.")
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

    public init(
        title: String,
        xAxisTitle: String = "Distance",
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
            return "\(title). No data available."
        }
        var parts: [String] = [
            title + ".",
            "\(xAxisTitle) in \(xAxisUnit).",
            "\(yAxisTitle) in \(yAxisUnit)."
        ]
        if let minimum = series.minimum, let maximum = series.maximum {
            parts.append("Range \(formatMetric(minimum, unit: series.unit)) to \(formatMetric(maximum, unit: series.unit)).")
        }
        if let average = series.average {
            parts.append("Average \(formatMetric(average, unit: series.unit)).")
        }
        if let current = series.currentValue {
            parts.append("At current replay position \(formatMetric(current, unit: series.unit)).")
        }
        if gapCount > 0 {
            parts.append("\(gapCount) recording gaps break the series.")
        }
        parts.append("Distance \(formatDistance(totalDistanceMeters)).")
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
    public static func make(
        metricName: String,
        unit: String,
        values: [Double],
        seriesIDs: [Int],
        currentValue: Double?,
        totalDistanceMeters: Double
    ) -> ChartAccessibilityModel {
        let finite = values.filter(\.isFinite)
        let missing = finite.isEmpty
        let minV = finite.min()
        let maxV = finite.max()
        let avg: Double? = {
            guard !finite.isEmpty else { return nil }
            // Pace averages can be misleading physiologically; still report
            // arithmetic mean of displayed samples for orientation only.
            return finite.reduce(0, +) / Double(finite.count)
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
            title: "\(metricName) chart",
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
        case .unchecked: return "Unchecked"
        case .checked: return "Checked"
        case .mixed: return "Mixed"
        }
    }
}

// MARK: - Formatting helpers

private func formatDistance(_ meters: Double) -> String {
    guard meters.isFinite else { return "unavailable" }
    if meters >= 1000 {
        return String(format: "%.2f kilometres", meters / 1000)
    }
    return String(format: "%.0f metres", meters)
}

private func formatMetric(_ value: Double, unit: String) -> String {
    guard value.isFinite else { return "unavailable" }
    if unit == "s/km" || unit.contains("pace") {
        let mins = Int(value) / 60
        let secs = Int(value) % 60
        return String(format: "%d:%02d per kilometre", mins, secs)
    }
    if unit == "bpm" {
        return "\(Int(value.rounded())) beats per minute"
    }
    if unit == "m" {
        return "\(Int(value.rounded())) metres"
    }
    if unit == "m/s" {
        return String(format: "%.1f metres per second", value)
    }
    return String(format: "%.2f %@", value, unit)
}
