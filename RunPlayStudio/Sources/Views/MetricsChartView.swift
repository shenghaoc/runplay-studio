import SwiftUI
import RunPlayCore
import Charts


/// Displays running metrics as interactive charts using Swift Charts.
///
/// Shows pace, elevation, and heart rate over distance with
/// optional current position indicator and click/drag to seek.
/// Uses semantic colors from the design system for each metric type.
struct MetricsChartView: View {
    let routePoints: [RoutePoint]
    var currentDistance: Double = 0
    var smoothingWindow: Int = 5
    var onSeek: ((Double) -> Void)? = nil

    @State private var selectedMetric: MetricType = .elevation
    @State private var isDragging: Bool = false
    @State private var dragDistance: Double? = nil
    @State private var chartData: [ChartDataPoint] = []
    @State private var seekDistanceKmText: String = ""
    @FocusState private var seekFieldFocused: Bool

    enum MetricType: String, CaseIterable {
        case elevation = "Elevation"
        case pace = "Pace"
        case heartRate = "Heart Rate"
        case speed = "Speed"
    }

    var body: some View {
        VStack(spacing: AppDesign.Spacing.medium) {
            // Metric picker with semantic color indicator
            HStack {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(MetricType.allCases, id: \.self) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Spacer()

                // Current value readout
                if currentDistance > 0, !chartData.isEmpty {
                    HStack(spacing: AppDesign.Spacing.xxSmall) {
                        Circle()
                            .fill(chartColor)
                            .frame(width: 6, height: 6)
                        Text(formatValue(valueForDistance(currentDistance)))
                            .font(AppDesign.Typography.compactMetric.monospacedDigit())
                            .foregroundStyle(chartColor)
                    }
                }
            }
            .padding(.horizontal)

            // Chart
            ZStack {
                Chart {
                    ForEach(chartData) { point in
                        AreaMark(
                            x: .value("Distance (km)", point.distanceKm),
                            y: .value(selectedMetric.rawValue, point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [chartColor.opacity(0.15), chartColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Distance (km)", point.distanceKm),
                            y: .value(selectedMetric.rawValue, point.value)
                        )
                        .foregroundStyle(chartColor)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }

                    // Current position indicator
                    let displayDistance = isDragging ? (dragDistance ?? currentDistance) : currentDistance
                    if displayDistance > 0 {
                        RuleMark(x: .value("Current", displayDistance / 1000))
                            .foregroundStyle(isDragging ? AppDesign.comparisonOrange : AppDesign.warmYellow)
                            .lineStyle(StrokeStyle(lineWidth: isDragging ? 2.5 : 1.5, dash: [6, 4]))
                            .annotation(position: .top, alignment: .center) {
                                Text(formatValue(valueForDistance(displayDistance)))
                                    .font(AppDesign.Typography.compactMetric)
                                    .padding(.horizontal, AppDesign.Spacing.small)
                                    .padding(.vertical, AppDesign.Spacing.xxSmall)
                                    .background(
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                                    )
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
                            .foregroundStyle(.quaternary)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            Text(formatAxisValue(value.as(Double.self) ?? 0))
                        }
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(height: 180)
                .padding(.horizontal)

                if chartData.isEmpty {
                    noDataOverlay
                }
            }

            // VoiceOver-friendly seek alternative
            if !chartData.isEmpty {
                seekDistanceControl
            }
        }
        .onAppear(perform: refreshChartData)
        .onChange(of: selectedMetric) { _, _ in refreshChartData() }
        .onChange(of: routePoints) { _, _ in refreshChartData() }
        .onChange(of: smoothingWindow) { _, _ in refreshChartData() }
    }

    // MARK: - Seek Distance Control (VoiceOver alternative)

    private var seekDistanceControl: some View {
        let totalKm = (routePoints.last?.distanceFromStartMeters ?? 0) / 1000
        return HStack(spacing: AppDesign.Spacing.small) {
            Text("Seek")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("km", text: $seekDistanceKmText)
                .font(.caption.monospacedDigit())
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .focused($seekFieldFocused)
                .accessibilityLabel("Seek to distance in kilometers")
                .onSubmit { commitSeekDistance(totalKm) }

            Stepper(value: Binding(
                get: { currentDistance / 1000 },
                set: { newKm in
                    let distance = max(0, min(newKm * 1000, totalKm * 1000))
                    onSeek?(distance)
                    seekDistanceKmText = String(format: "%.2f", newKm)
                }
            ), in: 0...max(totalKm, 0.01), step: 0.1) {
                Text(String(format: "%.2f / %.2f km", currentDistance / 1000, totalKm))
                    .font(.caption.monospacedDigit())
            }
            .accessibilityLabel("Adjust seek distance")
            .accessibilityValue(String(format: "%.2f km", currentDistance / 1000))
        }
        .padding(.horizontal)
    }

    private func commitSeekDistance(_ totalKm: Double) {
        guard let km = Double(seekDistanceKmText.replacingOccurrences(of: ",", with: ".")),
              km >= 0, km <= totalKm else {
            seekDistanceKmText = String(format: "%.2f", currentDistance / 1000)
            return
        }
        onSeek?(km * 1000)
    }

    // MARK: - No Data Overlay

    private var noDataOverlay: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: selectedMetric == .heartRate ? "heart.slash" : "chart.line.downtrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(noDataMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

    private func refreshChartData() {
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

        chartData = zip(routePoints, smoothedValues).compactMap { point, value in
            guard let v = value else { return nil }
            return ChartDataPoint(
                distanceKm: point.distanceFromStartMeters / 1000,
                value: v
            )
        }
    }

    private var chartColor: Color {
        switch selectedMetric {
        case .elevation: return AppDesign.MetricColor.elevation
        case .pace: return AppDesign.MetricColor.pace
        case .heartRate: return AppDesign.MetricColor.heartRate
        case .speed: return AppDesign.MetricColor.speed
        }
    }

    private var noDataMessage: String {
        selectedMetric == .heartRate ? "No heart rate data available" : "No chart data available"
    }

    private func valueForDistance(_ distance: Double) -> Double {
        guard distance > 0, !routePoints.isEmpty else { return 0 }
        let index = RoutePointInterpolator.firstIndex(atOrAfter: distance, in: routePoints) ?? routePoints.count - 1
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
