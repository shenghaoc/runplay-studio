import SwiftUI
import RunPlayCore
import Charts


/// Chart showing active-pace comparison over distance or matched route progress.
///
/// Uses semantic colors from the design system for primary/comparison routes.
/// Route-Aware series are split per alignment block so gaps are not bridged.
struct ComparisonChartView: View {
    let metrics: [ComparisonMetricPoint]
    let alignedMetrics: [AlignedComparisonMetricPoint]
    let alignmentMode: ComparisonAlignmentMode
    let isRouteAwareReady: Bool
    let primaryName: String
    let comparisonName: String

    init(
        metrics: [ComparisonMetricPoint],
        alignedMetrics: [AlignedComparisonMetricPoint] = [],
        alignmentMode: ComparisonAlignmentMode = .distance,
        isRouteAwareReady: Bool = false,
        primaryName: String,
        comparisonName: String
    ) {
        self.metrics = metrics
        self.alignedMetrics = alignedMetrics
        self.alignmentMode = alignmentMode
        self.isRouteAwareReady = isRouteAwareReady
        self.primaryName = primaryName
        self.comparisonName = comparisonName
    }

    private var usesAlignedChart: Bool {
        alignmentMode == .routeAware && isRouteAwareReady && !alignedMetrics.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(alignment: .lastTextBaseline) {
                Text(usesAlignedChart ? "Active Pace Over Matched Route" : "Active Pace Over Distance")
                    .font(AppDesign.Typography.sectionHeadline)
                Text("(lower is faster)")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
            .help(
                usesAlignedChart
                    ? "Pace uses active time along matched route progress. Alignment blocks are not connected across gaps."
                    : "Pace uses active time and excludes recording gaps."
            )

            if usesAlignedChart {
                alignedChart
            } else if metrics.isEmpty {
                ComparisonChartEmptyView()
            } else {
                distanceChart
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chartAccessibilityModel.spokenSummary)
    }

    private var distanceChart: some View {
        Chart {
            ForEach(metrics) { point in
                if let primaryPace = point.primaryPace, primaryPace.isFinite {
                    LineMark(
                        x: .value("Distance (km)", point.distanceKm),
                        y: .value("min/km", primaryPace)
                    )
                    .foregroundStyle(by: .value("Run", primaryName))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                if let comparisonPace = point.comparisonPace, comparisonPace.isFinite {
                    LineMark(
                        x: .value("Distance (km)", point.distanceKm),
                        y: .value("min/km", comparisonPace)
                    )
                    .foregroundStyle(by: .value("Run", comparisonName))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartForegroundStyleScale([
            primaryName: AppDesign.primaryBlue,
            comparisonName: AppDesign.comparisonOrange
        ])
        .chartXAxis { distanceAxis }
        .chartYAxis { paceAxis }
        .chartLegend(position: .bottom) { legend }
    }

    private var alignedChart: some View {
        Chart {
            ForEach(alignedMetrics) { point in
                if let primaryPace = point.primaryPace, primaryPace.isFinite {
                    LineMark(
                        x: .value("Matched route (km)", point.alignedProgressKm),
                        y: .value("min/km", primaryPace),
                        series: .value("Series", "P-\(point.blockIndex)")
                    )
                    .foregroundStyle(AppDesign.primaryBlue)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let comparisonPace = point.comparisonPace, comparisonPace.isFinite {
                    LineMark(
                        x: .value("Matched route (km)", point.alignedProgressKm),
                        y: .value("min/km", comparisonPace),
                        series: .value("Series", "C-\(point.blockIndex)")
                    )
                    .foregroundStyle(AppDesign.comparisonOrange)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisValueLabel {
                    if let km = value.as(Double.self) {
                        Text(String(format: "%.1f km", km))
                    }
                }
                AxisGridLine()
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis { paceAxis }
        .chartLegend(position: .bottom) { legend }
    }

    private var distanceAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisValueLabel {
                if let km = value.as(Double.self) {
                    Text("\(Int(km)) km")
                }
            }
            AxisGridLine()
                .foregroundStyle(.quaternary)
        }
    }

    private var paceAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisValueLabel {
                if let pace = value.as(Double.self) {
                    let mins = Int(pace) / 60
                    let secs = Int(pace) % 60
                    Text("\(mins):\(String(format: "%02d", secs))")
                }
            }
            AxisGridLine()
                .foregroundStyle(.quaternary)
        }
    }

    private var legend: some View {
        HStack(spacing: AppDesign.Spacing.xLarge) {
            Label(truncatedName(primaryName), systemImage: "circle.fill")
                .foregroundStyle(AppDesign.primaryBlue)
                .font(AppDesign.Typography.compactMetric)
            Label(truncatedName(comparisonName), systemImage: "circle.fill")
                .foregroundStyle(AppDesign.comparisonOrange)
                .font(AppDesign.Typography.compactMetric)
        }
    }

    private var chartAccessibilityModel: ChartAccessibilityModel {
        if usesAlignedChart {
            // ⚡ Bolt: Inline loop avoids multiple intermediate O(N) array allocations from compactMap and +.
            var paces: [Double] = []
            paces.reserveCapacity(alignedMetrics.count * 2)
            var seriesIDs: [Int] = []
            seriesIDs.reserveCapacity(alignedMetrics.count)
            for metric in alignedMetrics {
                if let p = metric.primaryPace { paces.append(p) }
                if let c = metric.comparisonPace { paces.append(c) }
                seriesIDs.append(metric.blockIndex)
            }
            return ChartAccessibilityModel.make(
                metricName: "Active Pace Over Matched Route",
                unit: "s/km",
                values: paces,
                seriesIDs: seriesIDs,
                currentValue: nil,
                totalDistanceMeters: alignedMetrics.last?.alignedProgressMeters ?? 0
            ).updatingTitles(
                title: "Active Pace Over Matched Route",
                xAxisTitle: "Matched route",
                xAxisUnit: "km"
            )
        }
        // ⚡ Bolt: Inline loop avoids multiple intermediate O(N) array allocations from compactMap and +.
        var paces: [Double] = []
        paces.reserveCapacity(metrics.count * 2)
        for metric in metrics {
            if let p = metric.primaryPace { paces.append(p) }
            if let c = metric.comparisonPace { paces.append(c) }
        }
        return ChartAccessibilityModel.make(
            metricName: "Active Pace",
            unit: "s/km",
            values: paces,
            seriesIDs: [0],
            currentValue: nil,
            totalDistanceMeters: (metrics.last?.distanceMeters ?? 0)
        )
    }

    private func truncatedName(_ name: String) -> String {
        if name.count > 20 {
            return String(name.prefix(18)) + "…"
        }
        return name
    }
}

private extension ChartAccessibilityModel {
    func updatingTitles(title: String, xAxisTitle: String, xAxisUnit: String) -> ChartAccessibilityModel {
        ChartAccessibilityModel(
            title: title,
            xAxisTitle: xAxisTitle,
            xAxisUnit: xAxisUnit,
            yAxisTitle: yAxisTitle,
            yAxisUnit: yAxisUnit,
            series: series,
            totalDistanceMeters: totalDistanceMeters,
            gapCount: gapCount
        )
    }
}

// MARK: - Chart Empty State

struct ComparisonChartEmptyView: View {
    var body: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No pace data to chart")
                .font(AppDesign.Typography.secondary)
                .foregroundStyle(.secondary)
            Text("Both runs need GPS route points with timing data to build a pace comparison.")
                .font(AppDesign.Typography.compactMetric)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Split Comparison Table

struct SplitComparisonTableView: View {
    let splits: [SplitComparison]
    var isRouteAwareMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text(isRouteAwareMode ? "Distance Splits (not route-aligned)" : "Split Active Pace (min/km)")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)
                .help(
                    isRouteAwareMode
                        ? "Kilometre splits remain ordinary cumulative-distance splits. They are not DTW aligned."
                        : "Split comparison uses active time and excludes recording gaps."
                )

            if splits.isEmpty {
                Text("No splits to compare")
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Table(splits) {
                    TableColumn("km") { split in
                        Text("\(split.splitIndex)")
                            .monospacedDigit()
                    }
                    .width(35)

                    TableColumn("Selected") { split in
                        if let s = split.primarySplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.primaryBlue)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(90)

                    TableColumn("Comparison") { split in
                        if let s = split.comparisonSplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.comparisonOrange)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(110)

                    TableColumn("Δ") { split in
                        HStack(spacing: AppDesign.Spacing.xxSmall) {
                            Image(systemName: winnerIcon(for: split.winner))
                                .font(AppDesign.Typography.compactLabel)
                                .accessibilityHidden(true)
                            Text(split.formattedPaceDelta)
                                .monospacedDigit()
                        }
                        .foregroundStyle(deltaColor(split.paceDeltaSecondsPerKm))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Active pace difference \(split.formattedPaceDelta); \(split.winner.label)"
                        )
                    }
                    .width(110)
                }
            }
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        AppDesign.deltaColor(delta, threshold: 5)
    }

    private func winnerIcon(for result: RunPlayCore.ComparisonResult) -> String {
        switch result {
        case .primary: return "1.circle.fill"
        case .comparison: return "2.circle.fill"
        case .tie: return "equal.circle.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

}

/// Ordinal recorded-lap comparison. Does not claim route alignment.
struct RecordedLapComparisonTableView: View {
    let comparisons: [RecordedLapComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text("Recorded Laps (ordinal)")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)
                .help("Pairs lap 1 with lap 1 only. Not route-aligned, even in Route-Aware mode.")

            if let caveatText {
                Text(caveatText)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if comparisons.isEmpty {
                Text("No recorded laps to compare")
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.tertiary)
            } else {
                Table(comparisons) {
                    TableColumn("Lap") { row in
                        Text("\(row.lapIndex)")
                            .monospacedDigit()
                    }
                    .width(40)

                    TableColumn("Selected") { row in
                        if let lap = row.primaryLap {
                            Text(lap.formattedActivePace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.primaryBlue)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(90)

                    TableColumn("Comparison") { row in
                        if let lap = row.comparisonLap {
                            Text(lap.formattedActivePace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.comparisonOrange)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(110)

                    TableColumn("Δ Active") { row in
                        Text(row.formattedActivePaceDelta)
                            .monospacedDigit()
                            .foregroundStyle(AppDesign.deltaColor(row.activePaceDeltaSecondsPerKm, threshold: 5))
                    }
                    .width(100)
                }
                .frame(minHeight: 120)
            }
        }
    }

    private var caveatText: String? {
        let caveats = Array(Set(comparisons.flatMap(\.caveats))).sorted()
        return caveats.isEmpty ? nil : caveats.joined(separator: " • ")
    }
}
