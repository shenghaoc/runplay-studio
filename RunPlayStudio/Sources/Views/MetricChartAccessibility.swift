import Accessibility
import RunPlayCore
import SwiftUI

/// One bounded accessibility-chart point that retains its visual gap identity.
struct MetricChartAccessibilitySample: Equatable {
    let distanceKm: Double
    let value: Double
    let seriesID: Int
}

enum MetricChartAccessibilityBuilder {
    /// Keeps the descriptor bounded while always retaining both sides of every
    /// recording gap. The visual chart and VoiceOver audio graph therefore
    /// expose the same continuous regions.
    static func downsample(
        _ points: [MetricChartDataPoint],
        maximumSampleCount: Int = 80
    ) -> [MetricChartAccessibilitySample] {
        guard !points.isEmpty else { return [] }
        let boundedMaximum = max(1, maximumSampleCount)
        let strideCount = max(
            1,
            (points.count + boundedMaximum - 1) / boundedMaximum
        )

        return points.indices.compactMap { index in
            let point = points[index]
            guard point.value.isFinite else { return nil }
            let startsSeries = index == points.startIndex
                || points[index - 1].seriesID != point.seriesID
            let endsSeries = index == points.index(before: points.endIndex)
                || points[index + 1].seriesID != point.seriesID
            guard startsSeries || endsSeries || index % strideCount == 0 else {
                return nil
            }
            return MetricChartAccessibilitySample(
                distanceKm: point.distanceKm,
                value: point.value,
                seriesID: point.seriesID
            )
        }
    }
}

/// Value-type chart descriptor so Accessibility framework code stays outside
/// the replay-invalidated SwiftUI view.
struct MetricChartDescriptor: AXChartDescriptorRepresentable {
    let model: ChartAccessibilityModel
    let samples: [MetricChartAccessibilitySample]
    let metric: MetricsChartView.MetricType

    func makeChartDescriptor() -> AXChartDescriptor {
        let xScale = AXNumericDataAxisDescriptor(
            title: "\(model.xAxisTitle) (\(model.xAxisUnit))",
            range: 0...max(model.totalDistanceMeters / 1000, 0.001),
            gridlinePositions: []
        ) { value in
            String(format: "%.2f km", value)
        }

        let yValues = samples.map(\.value)
        let yMin = yValues.min() ?? 0
        let yMax = yValues.max() ?? 1
        let yScale = AXNumericDataAxisDescriptor(
            title: "\(model.yAxisTitle) (\(model.yAxisUnit))",
            range: min(yMin, yMax)...max(yMin, yMax, yMin + 0.001),
            gridlinePositions: []
        ) { [metric] value in
            switch metric {
            case .elevation: return "\(Int(value)) m"
            case .pace:
                let mins = Int(value) / 60
                let secs = Int(value) % 60
                return String(format: "%d:%02d /km", mins, secs)
            case .heartRate: return "\(Int(value)) bpm"
            case .speed: return String(format: "%.1f m/s", value)
            }
        }

        var groupedSamples: [[MetricChartAccessibilitySample]] = []
        for sample in samples {
            if groupedSamples.last?.last?.seriesID == sample.seriesID {
                groupedSamples[groupedSamples.count - 1].append(sample)
            } else {
                groupedSamples.append([sample])
            }
        }
        let dataSeries = groupedSamples.enumerated().map { index, group in
            AXDataSeriesDescriptor(
                name: groupedSamples.count == 1
                    ? model.series.name
                    : "\(model.series.name), section \(index + 1)",
                isContinuous: true,
                dataPoints: group.map {
                    AXDataPoint(x: $0.distanceKm, y: $0.value)
                }
            )
        }

        return AXChartDescriptor(
            title: model.title,
            summary: model.spokenSummary,
            xAxis: xScale,
            yAxis: yScale,
            additionalAxes: [],
            series: dataSeries
        )
    }
}
