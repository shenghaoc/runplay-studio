import SwiftUI
import RunPlayCore
import SceneKit


/// Displays a 3D comparison of two routes in the same scene.
struct Comparison3DView: View {
    let primaryWorkout: RunWorkout
    let comparisonWorkout: RunWorkout
    let warnings: [ComparisonWarning]
    @ObservedObject var appState: AppState

    @State private var scene: SCNScene?
    @State private var comparisonScene: ComparisonRouteScene?
    @State private var showGrid: Bool = true
    @State private var elevationScale: Double = 2.0
    @State private var cameraNode: SCNNode?

    private let elevationScales: [Double] = [1.0, 2.0, 5.0, 10.0]

    private var commonDistance: Double {
        appState.comparisonCommonDistanceMeters
    }

    var body: some View {
        ZStack {
            if let scene = scene {
                SceneView(
                    scene: scene,
                    pointOfView: cameraNode,
                    options: [.allowsCameraControl, .autoenablesDefaultLighting],
                    preferredFramesPerSecond: 60
                )
            } else {
                ProgressView("Building 3D comparison...")
            }

            // Controls overlay
            VStack {
                HStack(alignment: .top) {
                    // Legend (left side)
                    comparisonLegend

                    Spacer()

                    // Warnings (top center)
                    if !warnings.isEmpty {
                        comparisonWarnings
                    }

                    Spacer()

                    // Control panel (right side)
                    controlPanel
                }
                Spacer()

                // Distance slider bar at bottom
                distanceSliderBar
            }
            .padding()
        }
        .onAppear {
            buildScene()
        }
        .onChange(of: primaryWorkout.routePoints.count) { _, _ in
            buildScene()
        }
        .onChange(of: comparisonWorkout.routePoints.count) { _, _ in
            buildScene()
        }
    }

    // MARK: - Legend

    private var comparisonLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: .blue, label: "Primary: \(primaryWorkout.displayName)")
            legendRow(color: .orange, label: "Comparison: \(comparisonWorkout.displayName)")

            Divider()

            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Start")
                    .font(.caption2)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Finish")
                    .font(.caption2)
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 18, height: 4)
            Text(label)
                .lineLimit(1)
        }
    }

    // MARK: - Warnings

    private var comparisonWarnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning.rawValue, systemImage: warning.icon)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Fit camera
            Button(action: fitToRoutes) {
                Label("Fit Routes", systemImage: "viewfinder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)

            // Camera presets
            VStack(spacing: 4) {
                Text("View")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(action: { setCameraPreset(.default) }) {
                    Image(systemName: "cube")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Default view")

                Button(action: { setCameraPreset(.topDown) }) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Top-down view")

                Button(action: { setCameraPreset(.side) }) {
                    Image(systemName: "arrow.left.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Side view")

                Button(action: { setCameraPreset(.front) }) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Front view")
            }
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)

            Divider()

            // Elevation scale
            VStack(spacing: 4) {
                Text("Elev")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(elevationScales, id: \.self) { scale in
                    Button(action: { setElevationScale(scale) }) {
                        Text("\(Int(scale))×")
                            .font(.caption)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(elevationScale == scale ? Color.accentColor.opacity(0.3) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)

            Divider()

            // Toggle grid
            Button(action: { setGridVisible(!showGrid) }) {
                Image(systemName: showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(showGrid ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)
            .help(showGrid ? "Hide grid" : "Show grid")
        }
    }

    // MARK: - Actions

    // MARK: - Distance Slider Bar

    private var distanceSliderBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Selected Distance")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(appState.comparisonDistanceMetrics.selectedDistanceFormatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)

                if commonDistance > 0 {
                    Text("/ \(String(format: "%.2f km", commonDistance / 1000))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: { appState.selectedComparisonDistanceMeters = 0; updateDistanceMarkers() }) {
                    Image(systemName: "backward.end.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Reset to start")

                Slider(
                    value: Binding(
                        get: { appState.selectedComparisonDistanceMeters },
                        set: { appState.selectedComparisonDistanceMeters = $0; updateDistanceMarkers() }
                    ),
                    in: 0...max(commonDistance, 1),
                    step: max(commonDistance / 500, 1)
                )
                .disabled(commonDistance <= 0)

                Button(action: { appState.selectedComparisonDistanceMeters = commonDistance; updateDistanceMarkers() }) {
                    Image(systemName: "forward.end.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Jump to end")
                .disabled(commonDistance <= 0)
            }

            // Metrics readout
            comparisonDistanceMetricsRow
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var comparisonDistanceMetricsRow: some View {
        let metrics = appState.comparisonDistanceMetrics
        return HStack(spacing: 16) {
            metricBadge(label: "Primary", value: metrics.primaryElapsedFormatted, color: .blue)
            metricBadge(label: "Comparison", value: metrics.comparisonElapsedFormatted, color: .orange)
            metricBadge(label: "Time", value: metrics.timeDeltaFormatted, color: timeDeltaColor(metrics.timeDeltaSeconds))

            Divider().frame(height: 16)

            metricBadge(label: "P Pace", value: metrics.primaryPaceFormatted, color: .blue)
            metricBadge(label: "C Pace", value: metrics.comparisonPaceFormatted, color: .orange)
            metricBadge(label: "Pace", value: metrics.paceDeltaFormatted, color: paceDeltaColor(metrics.paceDeltaSecondsPerKm))
        }
        .frame(height: 24)
    }

    private func metricBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func timeDeltaColor(_ delta: Double?) -> Color {
        guard let delta, delta.isFinite else { return .secondary }
        if abs(delta) < 0.5 { return .secondary }
        return delta < 0 ? .green : .red
    }

    private func paceDeltaColor(_ delta: Double?) -> Color {
        guard let delta, delta.isFinite else { return .secondary }
        if abs(delta) < 0.5 { return .secondary }
        return delta < 0 ? .green : .red
    }

    // MARK: - Actions

    private func buildScene() {
        appState.comparisonProjectionService.elevationExaggeration = elevationScale
        appState.comparisonSceneBuilder.showGroundGrid = showGrid

        let result = appState.comparisonProjectionService.project(
            primary: primaryWorkout.routePoints,
            comparison: comparisonWorkout.routePoints,
            existingWarnings: warnings
        )
        comparisonScene = result

        let newScene = appState.comparisonSceneBuilder.buildScene(from: result)
        let bbox = appState.comparisonSceneBuilder.routeBoundingBox(for: result)
        cameraNode = appState.comparisonCameraController.setupCamera(in: newScene, lookingAt: bbox.center)
        appState.comparisonCameraController.fitToRoute(center: bbox.center, extent: bbox.extent)
        scene = newScene

        appState.clampComparisonDistance()
        updateDistanceMarkers(in: newScene, result: result)
    }

    private func updateDistanceMarkers() {
        guard let scene, let compScene = comparisonScene else { return }
        updateDistanceMarkers(in: scene, result: compScene)
    }

    private func updateDistanceMarkers(in scene: SCNScene, result: ComparisonRouteScene) {
        let selectedDist = appState.selectedComparisonDistanceMeters
        guard selectedDist > 0, commonDistance > 0 else {
            appState.comparisonSceneBuilder.updateDistanceMarkers(in: scene, primaryPoint: nil, comparisonPoint: nil)
            return
        }

        let metrics = appState.comparisonService.metricsAtDistance(
            selectedDist,
            primary: primaryWorkout,
            comparison: comparisonWorkout,
            primaryScenePoints: result.primaryRoute,
            comparisonScenePoints: result.comparisonRoute
        )

        appState.comparisonSceneBuilder.updateDistanceMarkers(
            in: scene,
            primaryPoint: metrics.primaryScenePoint,
            comparisonPoint: metrics.comparisonScenePoint
        )
    }

    private func fitToRoutes() {
        guard let compScene = comparisonScene else { return }
        let bbox = appState.comparisonSceneBuilder.routeBoundingBox(for: compScene)
        appState.comparisonCameraController.fitToRoute(center: bbox.center, extent: bbox.extent)
    }

    private func setCameraPreset(_ preset: CameraPreset) {
        appState.comparisonCameraController.setPresetView(preset)
    }

    private func setElevationScale(_ scale: Double) {
        elevationScale = scale
        buildScene()
    }

    private func setGridVisible(_ isVisible: Bool) {
        showGrid = isVisible
        appState.comparisonSceneBuilder.showGroundGrid = isVisible
    }
}
