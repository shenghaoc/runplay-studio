import SwiftUI
import RunPlayCore
import SceneKit


/// Displays the 3D route scene with replay marker and controls.
struct Route3DReplayView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState
    @ObservedObject private var replayController: ReplayController

    init(workout: RunWorkout, appState: AppState) {
        self.workout = workout
        self.appState = appState
        self._replayController = ObservedObject(wrappedValue: appState.replayController)
    }

    @State private var scene: SCNScene?
    @State private var scenePoints: [RouteScenePoint] = []
    @State private var hasAttemptedBuild = false
    @State private var showGrid: Bool = true
    @State private var showKmMarkers: Bool = true
    @State private var elevationScale: Double = 2.0
    @State private var colorMode: RouteColorMode = .singleColor
    @State private var paceScale: PaceColorScale?
    @State private var hrScale: HeartRateColorScale?
    @State private var cameraNode: SCNNode?
    @State private var mapLoadState: RouteMapLoadState = .loading

    // Camera presets
    private let elevationScales: [Double] = [1.0, 2.0, 5.0, 10.0]

    var body: some View {
        ZStack {
            if hasAttemptedBuild && scenePoints.count < 2 {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("3D route unavailable")
                        .font(.headline)
                    Text("The route has invalid or missing coordinates and cannot be displayed in 3D.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let scene = scene {
                SceneView(
                    scene: scene,
                    pointOfView: cameraNode,
                    options: [.allowsCameraControl, .autoenablesDefaultLighting],
                    preferredFramesPerSecond: 60
                )
            } else {
                ProgressView("Building 3D scene...")
            }

            // Controls overlay
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Legend (left side)
                        if colorMode == .pace, let scale = paceScale {
                            paceLegend(scale: scale)
                        } else if colorMode == .heartRate, let scale = hrScale {
                            heartRateLegend(scale: scale)
                        }

                        RouteMapStatusBadge(state: mapLoadState)
                    }

                    Spacer()

                    // Control panel (right side)
                    controlPanel
                }
                Spacer()
            }
            .padding()
        }
        .onAppear {
            buildScene()
        }
        .onChange(of: workout.routePoints.count) { _, _ in
            buildScene()
        }
        .onChange(of: replayController.state.currentPointIndex) { _, newIndex in
            updateMarker(at: newIndex)
        }
        .onDisappear {
            appState.mapSnapshotService.cancel()
        }
    }

    // MARK: - Pace Legend

    private func paceLegend(scale: PaceColorScale) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pace")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Color gradient bar
            LinearGradient(
                colors: [.blue, .cyan, .green, .yellow, .red],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: 60)
            .cornerRadius(3)

            // Labels
            VStack(alignment: .leading, spacing: 0) {
                Text(scale.fastestFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(scale.medianFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(scale.slowestFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 60)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }

    private func heartRateLegend(scale: HeartRateColorScale) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heart Rate")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Color gradient bar (low HR blue/green -> high HR red)
            LinearGradient(
                colors: [.blue, .green, .yellow, .orange, .red],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 12, height: 60)
            .cornerRadius(3)

            // Labels
            VStack(alignment: .leading, spacing: 0) {
                Text(scale.lowFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(scale.medianFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(scale.highFormatted)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 60)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Color mode
            VStack(spacing: 4) {
                Text("Color")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(RouteColorMode.allCases) { mode in
                    let disabled = mode == .heartRate && !workout.hasHeartRateData
                    Button(action: { setColorMode(mode) }) {
                        Text(mode.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorMode == mode ? Color.accentColor.opacity(0.3) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .opacity(disabled ? 0.4 : 1.0)
                    .help(disabled ? "No heart rate data available" : "")
                }
            }
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)

            Divider()

            // Reset camera
            Button(action: fitToRoute) {
                Label("Fit Route", systemImage: "viewfinder")
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
                .accessibilityLabel("Default view")

                Button(action: { setCameraPreset(.topDown) }) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Top-down view")
                .accessibilityLabel("Top-down view")

                Button(action: { setCameraPreset(.side) }) {
                    Image(systemName: "arrow.left.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Side view")
                .accessibilityLabel("Side view")

                Button(action: { setCameraPreset(.front) }) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Front view")
                .accessibilityLabel("Front view")
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
            .accessibilityLabel(Text(showGrid ? "Hide grid" : "Show grid"))

            // Toggle km markers
            Button(action: { setKilometerMarkersVisible(!showKmMarkers) }) {
                Image(systemName: showKmMarkers ? "mappin.circle.fill" : "mappin.circle")
                    .font(.caption)
                    .foregroundStyle(showKmMarkers ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)
            .help(showKmMarkers ? "Hide km markers" : "Show km markers")
            .accessibilityLabel(Text(showKmMarkers ? "Hide km markers" : "Show km markers"))
        }
    }

    // MARK: - Actions

    private func buildScene() {
        hasAttemptedBuild = false

        // Update projection service with current elevation scale
        appState.projectionService.elevationExaggeration = elevationScale
        scenePoints = appState.projectionService.project(workout.routePoints)

        // Update builder settings
        appState.sceneBuilder.showGroundGrid = showGrid
        appState.sceneBuilder.showKilometerMarkers = showKmMarkers
        appState.sceneBuilder.colorMode = colorMode

        // Compute scales for legend
        if colorMode == .pace {
            let scenePointsForPace = appState.projectionService.project(workout.routePoints)
            paceScale = appState.sceneBuilder.coloringService.computePaceScale(points: scenePointsForPace)
            hrScale = nil
        } else if colorMode == .heartRate {
            let scenePointsForHR = appState.projectionService.project(workout.routePoints)
            hrScale = appState.sceneBuilder.coloringService.computeHeartRateScale(points: scenePointsForHR)
            paceScale = nil
        } else {
            paceScale = nil
            hrScale = nil
        }

        let newScene = appState.sceneBuilder.buildScene(from: scenePoints)
        let bbox = appState.sceneBuilder.routeBoundingBox
        cameraNode = appState.cameraController.setupCamera(in: newScene, lookingAt: bbox.center)
        appState.cameraController.fitToRoute(center: bbox.center, extent: bbox.extent)
        scene = newScene
        loadMapOverlay(in: newScene)

        // Apply synchronous setup to the new scene rather than relying on the
        // asynchronous propagation of the @State assignment above.
        if let segment = appState.selectedSegment {
            appState.sceneBuilder.highlightSegment(segment, in: newScene)
        }

        // Position marker at controller's current index (not always 0)
        updateMarker(at: replayController.state.currentPointIndex)
        hasAttemptedBuild = true
    }

    private func loadMapOverlay(in targetScene: SCNScene) {
        guard scenePoints.count >= 2 else {
            mapLoadState = .unavailable
            return
        }

        mapLoadState = .loading
        appState.mapSnapshotService.snapshot(
            routeGroups: [workout.routePoints],
            projectionOrigin: workout.routePoints
        ) { result in
            switch result {
            case .success(let overlay):
                appState.sceneBuilder.installMapOverlay(overlay, in: targetScene)
                mapLoadState = .ready
            case .failure:
                mapLoadState = .unavailable
            }
        }
    }

    private func updateMarker(at routeIndex: Int) {
        guard let point = scenePoints.scenePoint(
            forRouteIndex: routeIndex,
            in: workout.routePoints
        ) else { return }
        appState.sceneBuilder.updateCurrentPosition(to: point)
    }

    private func fitToRoute() {
        let bbox = appState.sceneBuilder.routeBoundingBox
        appState.cameraController.fitToRoute(center: bbox.center, extent: bbox.extent)
    }

    private func setCameraPreset(_ preset: CameraPreset) {
        appState.cameraController.setPresetView(preset)
    }

    private func setElevationScale(_ scale: Double) {
        elevationScale = scale
        buildScene()
    }

    private func setColorMode(_ mode: RouteColorMode) {
        colorMode = mode
        buildScene()
    }

    private func setGridVisible(_ isVisible: Bool) {
        showGrid = isVisible
        appState.sceneBuilder.showGroundGrid = isVisible
    }

    private func setKilometerMarkersVisible(_ isVisible: Bool) {
        showKmMarkers = isVisible
        appState.sceneBuilder.showKilometerMarkers = isVisible
    }
}
