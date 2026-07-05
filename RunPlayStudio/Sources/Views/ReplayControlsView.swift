import SwiftUI

/// Controls for the route replay: play/pause, timeline, speed.
struct ReplayControlsView: View {
    @ObservedObject var controller: ReplayController

    var body: some View {
        VStack(spacing: 8) {
            // Timeline slider
            HStack {
                Text(controller.state.formattedCurrentTime)
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { controller.state.progress },
                        set: { controller.seekToProgress($0) }
                    ),
                    in: 0...1
                )

                Text(controller.state.formattedTotalDuration)
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
            }

            // Playback controls
            HStack(spacing: 20) {
                // Step backward
                Button(action: controller.stepBackward) {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.plain)
                .disabled(!controller.isPlaying && controller.state.currentTime == 0)

                // Play/Pause
                Button(action: controller.togglePlayPause) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Step forward
                Button(action: controller.stepForward) {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.plain)
                .disabled(!controller.isPlaying && controller.state.currentTime >= controller.state.totalDuration)

                Spacer()

                // Speed control
                HStack(spacing: 4) {
                    Text("Speed:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(ReplayController.speedOptions, id: \.self) { speed in
                        Button(action: { controller.setSpeed(speed) }) {
                            Text(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    controller.state.playbackSpeed == speed
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Distance display
                Text(controller.state.formattedCurrentDistance)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
