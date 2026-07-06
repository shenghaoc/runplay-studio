import SwiftUI
import RunPlayCore
import Charts


/// Displays running metrics as interactive charts using Swift Charts.
///
/// Shows pace, elevation, and heart rate over distance with
/// optional current position indicator and click/drag to seek.
struct MetricsChartView: View {
    let routePoints: [RoutePoint]
    var currentDistance: Double = 0
    var smoothingWindow: Int = 5
    var onSeek: ((Double) -> Void)? = nil

    @State private var selectedMetric: MetricType = .elevation
    @State private var isDragging: Bool = false
    @State private var dragDistance: Double? = nil

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
            ZStack {
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
                    let displayDistance = isDragging ? (dragDistance ?? currentDistance) : currentDistance
                    if displayDistance > 0 {
                        RuleMark(x: .value("Current", displayDistance / 1000))
                            .foregroundStyle(isDragging ? .orange : .yellow)
                            .lineStyle(StrokeStyle(lineWidth: isDragging ? 3 : 2, dash: [5, 5]))
                            .annotation(position: .top, alignment: .center) {
                                Text(formatValue(valueForDistance(displayDistance)))
                                    .font(.caption)
                                    .padding(4)
                                    .background((isDragging ? Color.orange : Color.yellow).opacity(0.2))
                                    .cornerRadius(4)
                            }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        handleChartDrag(at: value.location, proxy: proxy, geometry: geometry)
                                    }
                                    .onEnded { _ in
                                        handleChartDragEnd()
                                    }
                            )
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

                if chartData.isEmpty {
                    Text(noDataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Chart Interaction

    private func handleChartDrag(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let plotFrame = geometry[anchor]
        let plotX = location.x - plotFrame.origin.x
        guard plotFrame.width > 0, plotX >= 0, plotX <= plotFrame.width else { return }
        guard let positionKm: Double = proxy.value(atX: plotX, as: Double.self) else { return }

        let totalDistance = routePoints.last?.distanceFromStartMeters ?? 0
        guard let distance = ChartSelectionMapper.distanceForChartPosition(
            positionKm: positionKm,
            totalDistanceMeters: totalDistance
        ) else { return }

        isDragging = true
        dragDistance = distance

        // Seek replay
        onSeek?(distance)
    }

    private func handleChartDragEnd() {
        isDragging = false
        dragDistance = nil
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
            smoothedValues = MetricSmoother.smoothHeartRate(from: routePoints, windowSize: smoothingWindow)
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

    private var noDataMessage: String {
        selectedMetric == .heartRate ? "No heart rate data" : "No chart data"
    }

    private func valueForDistance(_ distance: Double) -> Double {
        guard distance > 0, !routePoints.isEmpty else { return 0 }
        let index = routePoints.firstIndex { $0.distanceFromStartMeters >= distance } ?? routePoints.count - 1
        guard index >= 0 && index < routePoints.count else { return 0 }

        switch selectedMetric {
        case .elevation: return routePoints[index].altitudeMeters ?? 0
        case .pace: return routePoints[index].paceSecondsPerKilometer ?? 0
        case .heartRate: return routePoints[index].heartRateBPM ?? .nan
        case .speed: return routePoints[index].speedMetersPerSecond ?? 0
        }
    }

    private var currentValue: Double {
        valueForDistance(currentDistance)
    }

    private func formatValue(_ value: Double) -> String {
        switch selectedMetric {
        case .elevation: return "\(Int(value))m"
        case .pace:
            let mins = Int(value) / 60
            let secs = Int(value) % 60
            return "\(mins):\(String(format: "%02d", secs)) /km"
        case .heartRate:
            guard value.isFinite else { return "No HR" }
            return "\(Int(value)) bpm"
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
