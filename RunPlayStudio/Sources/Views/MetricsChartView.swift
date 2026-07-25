import SwiftUI
import RunPlayCore
import Charts

struct MetricChartDataPoint: Identifiable, Equatable {
    let id: Int
    let distanceKm: Double
    let value: Double
    let seriesID: Int
}

enum MetricChartDataBuilder {
    static func elevationValues(
        routePoints: [RoutePoint],
        profile: ElevationProfile
    ) -> [Double?] {
        routePoints.indices.map { index in
            correctedElevation(
                at: index,
                routePoints: routePoints,
                profile: profile
            )
        }
    }

    static func correctedElevation(
        at index: Int,
        routePoints: [RoutePoint],
        profile: ElevationProfile
    ) -> Double? {
        guard routePoints.indices.contains(index),
              profile.samples.indices.contains(index)
        else {
            return nil
        }
        let point = routePoints[index]
        let sample = profile.samples[index]
        guard sample.routePointID == point.id,
              sample.distanceFromStartMeters == point.distanceFromStartMeters,
              sample.routeSegmentIndex == point.routeSegmentIndex
        else {
            return nil
        }
        return sample.correctedAltitudeMeters
    }

    static func build(
        routePoints: [RoutePoint],
        values: [Double?]
    ) -> [MetricChartDataPoint] {
        var seriesID = 0
        var previousSegment: Int?
        var previousHadValue = false
        return routePoints.indices.compactMap { index in
            let point = routePoints[index]
            guard values.indices.contains(index),
                  let value = values[index],
                  value.isFinite
            else {
                previousHadValue = false
                return nil
            }
            if !previousHadValue || point.routeSegmentIndex != previousSegment {
                seriesID += 1
            }
            previousHadValue = true
            previousSegment = point.routeSegmentIndex
            return MetricChartDataPoint(
                id: index,
                distanceKm: point.distanceFromStartMeters / 1_000,
                value: value,
                seriesID: seriesID
            )
        }
    }
}


/// Displays running metrics as interactive charts using Swift Charts.
///
/// Shows pace, elevation, and heart rate over distance with
/// optional current position indicator and click/drag to seek.
/// Uses semantic colors from the design system for each metric type.
struct MetricsChartView: View {
    let routePoints: [RoutePoint]
    let elevationProfile: ElevationProfile
    var currentDistance: Double = 0
    var smoothingWindow: Int = 5
    var onSeek: ((Double) -> Void)? = nil

    @State private var selectedMetric: MetricType = .elevation
    @State private var isDragging: Bool = false
    @State private var dragDistance: Double? = nil
    @State private var chartData: [MetricChartDataPoint] = []
    @State private var chartAccessibilityBaseModel: ChartAccessibilityModel?
    @State private var downsampledChartSamples: [MetricChartAccessibilitySample] = []
    @State private var seekDistanceKmText: String = ""
    @FocusState private var seekFieldFocused: Bool

    init(
        routePoints: [RoutePoint],
        elevationProfile: ElevationProfile? = nil,
        currentDistance: Double = 0,
        smoothingWindow: Int = 5,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.routePoints = routePoints
        self.elevationProfile = elevationProfile ?? ElevationProfile(routePoints: routePoints)
        self.currentDistance = currentDistance
        self.smoothingWindow = smoothingWindow
        self.onSeek = onSeek
    }

    enum MetricType: String, CaseIterable {
        case elevation = "Elevation"
        case pace = "Active Pace"
        case heartRate = "Heart Rate"
        case speed = "Speed"

        var unit: String {
            switch self {
            case .elevation: return "m"
            case .pace: return "s/km"
            case .heartRate: return "bpm"
            case .speed: return "m/s"
            }
        }
    }

    var body: some View {
        let accessibilityModel = chartAccessibilityModel
        return VStack(spacing: AppDesign.Spacing.medium) {
            // Metric picker with semantic color indicator
            HStack {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(MetricType.allCases, id: \.self) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .accessibilityLabel("Chart metric")
                .accessibilityHint(
                    selectedMetric == .pace
                        ? "Active pace uses recorded time and excludes recording gaps."
                        : "Select the metric shown over distance."
                )
                .help(
                    selectedMetric == .pace
                        ? "Active pace uses recorded time and excludes recording gaps."
                        : "Select the metric shown over distance."
                )

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
                            y: .value(selectedMetric.rawValue, point.value),
                            series: .value("Continuous route", point.seriesID)
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
                            y: .value(selectedMetric.rawValue, point.value),
                            series: .value("Continuous route", point.seriesID)
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
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            Text(formatAxisValue(value.as(Double.self) ?? 0))
                        }
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
                    }
                }
                .accessibilityChartDescriptor(MetricChartDescriptor(
                    model: accessibilityModel,
                    samples: downsampledChartSamples,
                    metric: selectedMetric
                ))
                .accessibilityLabel(accessibilityModel.title)
                .accessibilityValue(accessibilityModel.spokenSummary)
                .accessibilityAction(named: "Seek earlier") {
                    seekRelative(meters: -100)
                }
                .accessibilityAction(named: "Seek later") {
                    seekRelative(meters: 100)
                }
                .frame(height: 180)
                .padding(.horizontal)

                if chartData.isEmpty {
                    noDataOverlay
                }
            }

            // Always-visible summary for VoiceOver and sighted keyboard users.
            if !chartData.isEmpty {
                Text(accessibilityModel.spokenSummary)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityLabel("Chart summary")
                    .accessibilityValue(accessibilityModel.spokenSummary)
            }

            // Keyboard-accessible seek alternative
            if !chartData.isEmpty {
                DisclosureGroup("Jump to distance") {
                    seekDistanceContent
                        .padding(.top, AppDesign.Spacing.xSmall)
                }
                .font(AppDesign.Typography.compactMetric)
                .padding(.horizontal)
                .accessibilityHint("Keyboard alternative to dragging the chart")
            }
        }
        .onAppear {
            refreshChartData()
            seekDistanceKmText = String(format: "%.2f", currentDistance / 1000)
        }
        .onChange(of: selectedMetric) { _, _ in refreshChartData() }
        .onChange(of: routePoints) { _, _ in refreshChartData() }
        .onChange(of: smoothingWindow) { _, _ in refreshChartData() }
        .onChange(of: currentDistance) { _, newValue in
            if !seekFieldFocused {
                seekDistanceKmText = String(format: "%.2f", newValue / 1000)
            }
        }
        .onChange(of: seekFieldFocused) { _, isFocused in
            if !isFocused {
                let totalKm = (routePoints.last?.distanceFromStartMeters ?? 0) / 1000
                commitSeekDistance(totalKm)
            }
        }
    }

    // MARK: - Seek Distance Control

    private var seekDistanceContent: some View {
        let totalKm = (routePoints.last?.distanceFromStartMeters ?? 0) / 1000
        return HStack(spacing: AppDesign.Spacing.small) {
            Text("Jump to")
                .font(AppDesign.Typography.compactMetric)
                .foregroundStyle(.tertiary)

            TextField("km", text: $seekDistanceKmText)
                .font(AppDesign.Typography.monoCaption)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .focused($seekFieldFocused)
                .accessibilityLabel("Jump to distance in kilometers")
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
                    .font(AppDesign.Typography.monoCaption)
            }
            .accessibilityLabel("Adjust jump distance")
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

    private func seekRelative(meters: Double) {
        let total = routePoints.last?.distanceFromStartMeters ?? 0
        let next = max(0, min(currentDistance + meters, total))
        onSeek?(next)
        seekDistanceKmText = String(format: "%.2f", next / 1000)
    }

    private var chartAccessibilityModel: ChartAccessibilityModel {
        let base = chartAccessibilityBaseModel ?? ChartAccessibilityModel.make(
            metricName: selectedMetric.rawValue,
            unit: selectedMetric.unit,
            values: [],
            seriesIDs: [],
            currentValue: nil,
            totalDistanceMeters: routePoints.last?.distanceFromStartMeters ?? 0
        )
        return base.updatingCurrentValue(valueForDistance(currentDistance))
    }

    // MARK: - No Data Overlay

    private var noDataOverlay: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: selectedMetric == .heartRate ? "heart.slash" : "chart.line.downtrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(noDataMessage)
                .font(AppDesign.Typography.secondary)
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

    private func refreshChartData() {
        let smoothedValues: [Double?]

        switch selectedMetric {
        case .elevation:
            smoothedValues = MetricChartDataBuilder.elevationValues(
                routePoints: routePoints,
                profile: elevationProfile
            )
        case .pace:
            smoothedValues = MetricSmoother.smoothPace(from: routePoints, windowSize: smoothingWindow)
        case .heartRate:
            smoothedValues = MetricSmoother.smoothHeartRate(from: routePoints, windowSize: smoothingWindow)
        case .speed:
            smoothedValues = routePoints.map { $0.speedMetersPerSecond }
        }

        let updatedData = MetricChartDataBuilder.build(
            routePoints: routePoints,
            values: smoothedValues
        )
        chartData = updatedData
        chartAccessibilityBaseModel = ChartAccessibilityModel.make(
            metricName: selectedMetric.rawValue,
            unit: selectedMetric.unit,
            values: updatedData.map(\.value),
            seriesIDs: updatedData.map(\.seriesID),
            currentValue: nil,
            totalDistanceMeters: routePoints.last?.distanceFromStartMeters ?? 0
        )
        downsampledChartSamples = MetricChartAccessibilityBuilder.downsample(updatedData)
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

    private func valueForDistance(_ distance: Double) -> Double? {
        guard distance >= 0, !routePoints.isEmpty else { return nil }
        let index = RoutePointInterpolator.firstIndex(atOrAfter: distance, in: routePoints) ?? routePoints.count - 1
        guard index >= 0 && index < routePoints.count else { return nil }

        switch selectedMetric {
        case .elevation:
            return MetricChartDataBuilder.correctedElevation(
                at: index,
                routePoints: routePoints,
                profile: elevationProfile
            )
        case .pace: return routePoints[index].paceSecondsPerKilometer
        case .heartRate: return routePoints[index].heartRateBPM
        case .speed: return routePoints[index].speedMetersPerSecond
        }
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            switch selectedMetric {
            case .elevation: return "No elevation data"
            case .pace: return "No pace data"
            case .heartRate: return "No HR data"
            case .speed: return "No speed data"
            }
        }
        switch selectedMetric {
        case .elevation: return "\(Int(value))m"
        case .pace:
            let mins = Int(value) / 60
            let secs = Int(value) % 60
            return "\(mins):\(String(format: "%02d", secs)) /km"
        case .heartRate:
            guard value.isFinite else { return "No HR data" }
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
