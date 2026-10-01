import Accessibility
import Charts
import RunPlayCore
import SwiftUI

/// A heart-rate chart over elapsed time, for a run that has no route.
///
/// Such a run has readings but no distance to plot them against, so there is
/// nothing to seek or replay: the chart shows the readings, and its summary says
/// the same in words. Each reading holds until the next, which is how the source
/// reported it, and, while there are few enough to tell apart, each is marked
/// (`TimeDomainHeartRateChartModel.marksEachReading`).
struct TimeDomainHeartRateChart: View {
    let model: TimeDomainHeartRateChartModel

    var body: some View {
        VStack(spacing: AppDesign.Spacing.medium) {
            Chart {
                ForEach(model.points) { point in
                    LineMark(
                        x: .value("Time (min)", point.minutes),
                        y: .value("Heart Rate", point.bpm),
                        series: .value("Recording", point.seriesID)
                    )
                    .foregroundStyle(AppDesign.MetricColor.heartRate)
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    if model.marksEachReading {
                        PointMark(
                            x: .value("Time (min)", point.minutes),
                            y: .value("Heart Rate", point.bpm)
                        )
                        .foregroundStyle(AppDesign.MetricColor.heartRate)
                        .symbolSize(24)
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text("\(Int(minutes)) min")
                        }
                    }
                    AxisGridLine()
                        .foregroundStyle(.quaternary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        Text("\(Int(value.as(Double.self) ?? 0))")
                    }
                    AxisGridLine()
                        .foregroundStyle(.quaternary)
                }
            }
            .accessibilityChartDescriptor(TimeDomainHeartRateChartDescriptor(model: model))
            .accessibilityLabel(model.title)
            .accessibilityValue(model.spokenSummary)
            .frame(height: 180)
            .padding(.horizontal)

            // Always-visible summary for VoiceOver and sighted keyboard users,
            // as on the distance charts.
            Text(model.spokenSummary)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .accessibilityLabel("Chart summary")
                .accessibilityValue(model.spokenSummary)
        }
    }
}

/// Value-type chart descriptor, so Accessibility framework code stays out of the
/// SwiftUI view.
struct TimeDomainHeartRateChartDescriptor: AXChartDescriptorRepresentable {
    let model: TimeDomainHeartRateChartModel

    func makeChartDescriptor() -> AXChartDescriptor {
        let xScale = AXNumericDataAxisDescriptor(
            title: "Time (minutes)",
            range: 0...max(model.durationMinutes, 0.001),
            gridlinePositions: []
        ) { value in
            String(format: "%.1f min", value)
        }
        let yScale = AXNumericDataAxisDescriptor(
            title: "Heart Rate (bpm)",
            range: model.minimum...max(model.maximum, model.minimum + 0.001),
            gridlinePositions: []
        ) { value in
            "\(Int(value)) bpm"
        }

        var sections: [[HeartRateTimePoint]] = []
        for point in model.points {
            if sections.last?.last?.seriesID == point.seriesID {
                sections[sections.count - 1].append(point)
            } else {
                sections.append([point])
            }
        }
        let series = sections.enumerated().map { index, section in
            AXDataSeriesDescriptor(
                name: sections.count == 1 ? "Heart Rate" : "Heart Rate, section \(index + 1)",
                isContinuous: true,
                dataPoints: section.map { AXDataPoint(x: $0.minutes, y: $0.bpm) }
            )
        }

        return AXChartDescriptor(
            title: model.title,
            summary: model.spokenSummary,
            xAxis: xScale,
            yAxis: yScale,
            additionalAxes: [],
            series: series
        )
    }
}
