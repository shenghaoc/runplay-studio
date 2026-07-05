import SwiftUI
import SceneKit

/// Displays the 3D route scene with replay marker and controls.
struct Route3DReplayView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState

    @State private var scene: SCNScene?
    @State private var scenePoints: [RouteScenePoint] = []
    @State private var showGrid: Bool = true
    @State private var showKmMarkers: Bool = true
    @State private var elevationScale: Double = 2.0

    // Camera presets
    private let elevationScales: [Double] = [1.0, 2.0, 5.0, 10.0]

    var body: some View {
        ZStack {
            if let scene = scene {
                SceneView(
                    scene: scene,
                    pointOfView: nil,
                    options: [.allowsCameraControl, .autoenablesDefaultLighting],
                    preferredFramesPerSecond: 60
                )
            } else {
                ProgressView("Building 3D scene...")
            }

            // Controls overlay
            VStack {
                HStack {
                    Spacer()
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
        .onChange(of: appState.replayController.state.currentPointIndex) { _, newIndex in
            updateMarker(at: newIndex)
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
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
            Button(action: { showGrid.toggle() }) {
                Image(systemName: showGrid ? "grid" : "grid")
                    .font(.caption)
                    .foregroundStyle(showGrid ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)
            .help("Toggle grid")

            // Toggle km markers
            Button(action: { showKmMarkers.toggle() }) {
                Image(systemName: showKmMarkers ? "mappin.circle.fill" : "mappin.circle")
                    .font(.caption)
                    .foregroundStyle(showKmMarkers ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)
            .help("Toggle km markers")
        }
    }

    // MARK: - Actions

    private func buildScene() {
        // Update projection service with current elevation scale
        appState.projectionService.elevationExaggeration = elevationScale
        scenePoints = appState.projectionService.project(workout.routePoints)

        // Update builder visibility
        appState.sceneBuilder.showGroundGrid = showGrid
        appState.sceneBuilder.showKilometerMarkers = showKmMarkers

        scene = appState.sceneBuilder.buildScene(from: scenePoints)
    }

    private func updateMarker(at index: Int) {
        guard index < scenePoints.count else { return }
        appState.sceneBuilder.updateCurrentPosition(to: scenePoints[index])
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
}
