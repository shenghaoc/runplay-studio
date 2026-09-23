import SwiftUI
import RunPlayCore
import Charts

struct MetricChartDataPoint: Identifiable, Equatable {
    let id: Int
    let distanceKm: Double
    let value: Double
    let seriesID: Int
    /// Drawn dashed: elevation from a run's fallback source (see
    /// `ElevationChartSourceSplit`).
    var dashed = false
}

/// How an elevation chart separates its two altitude sources. A switch
/// between DEM and recorded altitude always starts a new series, so the line
/// breaks there rather than drawing the offset between sources as a slope;
/// and where a run shows both, its fallback source is dashed.
struct ElevationChartSourceSplit: Equatable {
    /// Per route point, from `ElevationProfileSample.sourceAltitudeIsDEM`.
    let sourceIsDEM: [Bool]
    /// The fallback source: DEM filling gaps in barometric altitude, or
    /// recorded altitude where no tile covered a DEM-corrected run.
    let fallbackIsDEM: Bool

    init(profile: ElevationProfile, recordedAltitudeSensor: RecordedAltitudeSensor) {
        sourceIsDEM = profile.samples.map(\.sourceAltitudeIsDEM)
        fallbackIsDEM = recordedAltitudeSensor == .barometric
    }

    init(sourceIsDEM: [Bool], fallbackIsDEM: Bool) {
        self.sourceIsDEM = sourceIsDEM
        self.fallbackIsDEM = fallbackIsDEM
    }

    /// The legend line for a chart that shows both sources.
    var legend: String {
        fallbackIsDEM
            ? "Dashed sections are DEM elevation filling gaps in the barometric altitude."
            : "Dashed sections use recorded altitude where no DEM tile covers the route."
    }
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
        values: [Double?],
        sourceSplit: ElevationChartSourceSplit? = nil
    ) -> [MetricChartDataPoint] {
        func hasValue(_ index: Int) -> Bool {
            values.indices.contains(index) && values[index].map(\.isFinite) == true
        }
        func isDEM(_ index: Int) -> Bool {
            guard let flags = sourceSplit?.sourceIsDEM, flags.indices.contains(index) else { return false }
            return flags[index]
        }
        let charted = routePoints.indices.filter(hasValue)
        let showsBothSources = sourceSplit != nil
            && charted.contains(where: isDEM)
            && charted.contains(where: { !isDEM($0) })

        var seriesID = 0
        var previousSegment: Int?
        var previousHadValue = false
        var previousWasDEM = false
        return routePoints.indices.compactMap { index in
            let point = routePoints[index]
            guard hasValue(index), let value = values[index] else {
                previousHadValue = false
                return nil
            }
            let pointIsDEM = isDEM(index)
            if !previousHadValue
                || point.routeSegmentIndex != previousSegment
                || pointIsDEM != previousWasDEM {
                seriesID += 1
            }
            previousHadValue = true
            previousSegment = point.routeSegmentIndex
            previousWasDEM = pointIsDEM
            return MetricChartDataPoint(
                id: index,
                distanceKm: point.distanceFromStartMeters / 1_000,
                value: value,
                seriesID: seriesID,
                dashed: showsBothSources && pointIsDEM == sourceSplit?.fallbackIsDEM
            )
        }
    }
}


/// Displays running metrics as interactive charts using Swift Charts.
///
/// Shows elevation, active pace, heart rate, power, and speed over distance
/// with optional current position indicator and click/drag to seek.
/// Uses semantic colors from the design system for each metric type.
struct MetricsChartView: View {
    let routePoints: [RoutePoint]
    let elevationProfile: ElevationProfile
    var currentDistance: Double = 0
    var smoothingWindow: Int = 5
    var onSeek: ((Double) -> Void)? = nil
    /// Cumulative-distance window emphasized as a translucent band
    /// (personal-record navigation); `nil` draws no band.
    var highlightedRangeMeters: ClosedRange<Double>? = nil
    /// Where the elevation comes from; shown under the Elevation chart.
    var elevationSource: ElevationSourceSummary? = nil

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
        onSeek: ((Double) -> Void)? = nil,
        highlightedRangeMeters: ClosedRange<Double>? = nil,
        elevationSource: ElevationSourceSummary? = nil
    ) {
        self.routePoints = routePoints
        self.elevationProfile = elevationProfile ?? ElevationProfile(routePoints: routePoints)
        self.currentDistance = currentDistance
        self.smoothingWindow = smoothingWindow
        self.onSeek = onSeek
        self.highlightedRangeMeters = highlightedRangeMeters
        self.elevationSource = elevationSource
    }

    enum MetricType: String, CaseIterable {
        case elevation = "Elevation"
        case pace = "Active Pace"
        case heartRate = "Heart Rate"
        case power = "Power"
        case speed = "Speed"

        var unit: String {
            switch self {
            case .elevation: return "m"
            case .pace: return "s/km"
            case .heartRate: return "bpm"
            case .power: return "W"
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
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: point.dashed ? [5, 3] : []))
                    }

                    // Highlighted record-window band. Decorative emphasis of a
                    // distance range; the spoken summary and current-value
                    // readout remain the accessibility surface.
                    if let highlight = highlightedRangeMeters,
                       let yRange = highlightYRange {
                        RectangleMark(
                            xStart: .value("Highlight start", highlight.lowerBound / 1000),
                            xEnd: .value("Highlight end", highlight.upperBound / 1000),
                            yStart: .value("Highlight y start", yRange.lowerBound),
                            yEnd: .value("Highlight y end", yRange.upperBound)
                        )
                        .foregroundStyle(AppDesign.primaryBlue.opacity(0.08))
                        .accessibilityHidden(true)
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
                    metric: selectedMetric,
                    elevationSourceLabel: selectedMetric == .elevation ? elevationSource?.label : nil
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

            elevationSourceNote

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

    private var noDataIcon: String {
        switch selectedMetric {
        case .heartRate: return "heart.slash"
        case .power: return "bolt.slash"
        default: return "chart.line.downtrend.xyaxis"
        }
    }

    private var noDataOverlay: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: noDataIcon)
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
        case .power:
            smoothedValues = MetricSmoother.smoothPower(from: routePoints, windowSize: smoothingWindow)
        case .speed:
            smoothedValues = routePoints.map { $0.speedMetersPerSecond }
        }

        let sourceSplit = selectedMetric == .elevation ? elevationSourceSplit : nil
        let updatedData = MetricChartDataBuilder.build(
            routePoints: routePoints,
            values: smoothedValues,
            sourceSplit: sourceSplit
        )
        chartData = updatedData
        // The spoken summary counts recording gaps. A source switch also
        // starts a new series but is not a gap, so group without the split.
        let gapSeriesIDs = sourceSplit == nil
            ? updatedData.map(\.seriesID)
            : MetricChartDataBuilder.build(routePoints: routePoints, values: smoothedValues).map(\.seriesID)
        // Power's chart line is smoothed but the Power & Running Dynamics
        // panel shows raw Max Power, so the descriptor summary reports the
        // raw series' min/max/average — otherwise a VoiceOver user hears a
        // smoothed maximum that contradicts the panel a sighted user reads
        // on the same screen.
        let aggregatesFromValues: [Double]? = selectedMetric == .power
            ? routePoints.compactMap { point in
                guard let watts = point.powerWatts,
                      MetricValidation.isValidPower(watts) else { return nil }
                return watts
            }
            : nil
        chartAccessibilityBaseModel = ChartAccessibilityModel.make(
            metricName: selectedMetric.rawValue,
            unit: selectedMetric.unit,
            values: updatedData.map(\.value),
            seriesIDs: gapSeriesIDs,
            currentValue: nil,
            totalDistanceMeters: routePoints.last?.distanceFromStartMeters ?? 0,
            aggregatesFromValues: aggregatesFromValues
        )
        downsampledChartSamples = MetricChartAccessibilityBuilder.downsample(updatedData)
    }

    private var elevationSourceSplit: ElevationChartSourceSplit {
        ElevationChartSourceSplit(
            profile: elevationProfile,
            recordedAltitudeSensor: elevationSource?.recordedAltitudeSensor ?? .unknown
        )
    }

    /// The source label, the dashed-line legend when both sources show, and
    /// the correction notes, read as one element by VoiceOver.
    @ViewBuilder
    private var elevationSourceNote: some View {
        if selectedMetric == .elevation, let source = elevationSource {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
                Text("Source: \(source.label)")
                    .font(AppDesign.Typography.compactLabel.weight(.semibold))
                if chartData.contains(where: \.dashed) {
                    Text(elevationSourceSplit.legend)
                }
                ForEach(source.notes, id: \.self) { note in
                    Text(note)
                }
            }
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.secondary)
            // Wrap, never truncate: the notes carry the plain warning that DEM
            // replaced altitude from an unstated sensor.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
    }

    private var chartColor: Color {
        switch selectedMetric {
        case .elevation: return AppDesign.MetricColor.elevation
        case .pace: return AppDesign.MetricColor.pace
        case .heartRate: return AppDesign.MetricColor.heartRate
        case .power: return AppDesign.MetricColor.power
        case .speed: return AppDesign.MetricColor.speed
        }
    }

    /// Vertical span for the highlight band: the current metric's data range
    /// padded so the band always covers the plotted area without distorting
    /// the y domain.
    private var highlightYRange: ClosedRange<Double>? {
        let values = chartData.map(\.value).filter { $0.isFinite }
        guard let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
            return nil
        }
        let padding = (maximum - minimum) * 0.05
        return (minimum - padding)...(maximum + padding)
    }

    private var noDataMessage: String {
        switch selectedMetric {
        case .heartRate: return "No heart rate data available"
        case .power: return "No power data available"
        default: return "No chart data available"
        }
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
        case .power: return routePoints[index].powerWatts
        case .speed: return routePoints[index].speedMetersPerSecond
        }
    }

    private func formatValue(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            switch selectedMetric {
            case .elevation: return "No elevation data"
            case .pace: return "No pace data"
            case .heartRate: return "No HR data"
            case .power: return "No power data"
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
        case .power: return "\(Int(value)) W"
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
        case .power: return "\(Int(value))"
        case .speed: return String(format: "%.1f", value)
        }
    }
}
