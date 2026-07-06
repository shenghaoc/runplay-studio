import SwiftUI
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
        }
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

        scene = appState.comparisonSceneBuilder.buildScene(from: result)

        // Fit camera on first build
        fitToRoutes()
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
}
