import SwiftUI
import SceneKit

/// Displays the 3D route scene with replay marker.
struct Route3DReplayView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState

    @State private var scene: SCNScene?
    @State private var scenePoints: [RouteScenePoint] = []

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

            // Camera controls overlay
            VStack {
                HStack {
                    Spacer()
                    Button(action: resetCamera) {
                        Image(systemName: "arrow.counterclockwise")
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
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

    private func buildScene() {
        scenePoints = appState.projectionService.project(workout.routePoints)
        scene = appState.sceneBuilder.buildScene(from: scenePoints)
    }

    private func updateMarker(at index: Int) {
        guard index < scenePoints.count else { return }
        appState.sceneBuilder.updateCurrentPosition(to: scenePoints[index])
    }

    private func resetCamera() {
        // Reset handled by SceneKit's built-in camera controls
    }
}
