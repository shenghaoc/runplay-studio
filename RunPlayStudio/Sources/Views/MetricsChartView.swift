import SwiftUI
import Charts

/// Displays running metrics as interactive charts using Swift Charts.
///
/// Shows pace, elevation, and heart rate over distance with
/// optional current position indicator.
struct MetricsChartView: View {
    let routePoints: [RoutePoint]
    var currentDistance: Double = 0
    var smoothingWindow: Int = 5

    @State private var selectedMetric: MetricType = .elevation

    enum MetricType: String, CaseIterable {
        case elevation = "Elevation"
        case pace = "Pace"
        case heartRate = "Heart Rate"
        case speed = "Speed"
    }

    var body: some View {
        VStack(spacing: 8) {
            // Metric picker
            Picker("Metric", selection: $selectedMetric) {
                ForEach(MetricType.allCases, id: \.self) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Chart
            Chart {
                ForEach(chartData) { point in
                    LineMark(
                        x: .value("Distance (km)", point.distanceKm),
                        y: .value(selectedMetric.rawValue, point.value)
                    )
                    .foregroundStyle(chartColor)
                    .interpolationMethod(.catmullRom)
                }

                // Current position indicator
                if currentDistance > 0 {
                    RuleMark(x: .value("Current", currentDistance / 1000))
                        .foregroundStyle(.yellow)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                        .annotation(position: .top, alignment: .center) {
                            Text(formatValue(currentValue))
                                .font(.caption)
                                .padding(4)
                                .background(.yellow.opacity(0.2))
                                .cornerRadius(4)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let km = value.as(Double.self) {
                            Text("\(Int(km)) km")
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        Text(formatAxisValue(value.as(Double.self) ?? 0))
                    }
                    AxisGridLine()
                }
            }
            .frame(height: 150)
            .padding(.horizontal)
        }
    }

    // MARK: - Chart Data

    private struct ChartDataPoint: Identifiable {
        let id = UUID()
        let distanceKm: Double
        let value: Double
    }

    private var chartData: [ChartDataPoint] {
        let smoothedValues: [Double?]

        switch selectedMetric {
        case .elevation:
            smoothedValues = routePoints.map { $0.altitudeMeters }
        case .pace:
            smoothedValues = MetricSmoother.smoothPace(from: routePoints, windowSize: smoothingWindow)
        case .heartRate:
            smoothedValues = MetricSmoother.movingAverage(
                routePoints.compactMap { $0.heartRateBPM },
                windowSize: smoothingWindow
            ).map { Optional($0) }
        case .speed:
            smoothedValues = routePoints.map { $0.speedMetersPerSecond }
        }

        return zip(routePoints, smoothedValues).compactMap { point, value in
            guard let v = value else { return nil }
            return ChartDataPoint(
                distanceKm: point.distanceFromStartMeters / 1000,
                value: v
            )
        }
    }

    private var chartColor: Color {
        switch selectedMetric {
        case .elevation: return .green
        case .pace: return .blue
        case .heartRate: return .red
        case .speed: return .orange
        }
    }

    private var currentValue: Double {
        guard currentDistance > 0 else { return 0 }
        let index = routePoints.firstIndex { $0.distanceFromStartMeters >= currentDistance } ?? routePoints.count - 1
        guard index < routePoints.count else { return 0 }

        switch selectedMetric {
        case .elevation: return routePoints[index].altitudeMeters ?? 0
        case .pace: return routePoints[index].paceSecondsPerKilometer ?? 0
        case .heartRate: return routePoints[index].heartRateBPM ?? 0
        case .speed: return routePoints[index].speedMetersPerSecond ?? 0
        }
    }

    private func formatValue(_ value: Double) -> String {
        switch selectedMetric {
        case .elevation: return "\(Int(value))m"
        case .pace:
            let mins = Int(value) / 60
            let secs = Int(value) % 60
            return "\(mins):\(String(format: "%02d", secs)) /km"
        case .heartRate: return "\(Int(value)) bpm"
        case .speed: return String(format: "%.1f m/s", value)
        }
    }

    private func formatAxisValue(_ value: Double) -> String {
        switch selectedMetric {
        case .elevation: return "\(Int(value))m"
        case .pace:
            let mins = Int(value) / 60
            let secs = Int(value) % 60
            return "\(mins):\(String(format: "%02d", secs))"
        case .heartRate: return "\(Int(value))"
        case .speed: return String(format: "%.1f", value)
        }
    }
}
