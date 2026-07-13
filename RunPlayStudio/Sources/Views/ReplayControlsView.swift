import SwiftUI
import RunPlayCore

/// Controls for the route replay: play/pause, timeline, speed.
///
/// Uses pill-style speed selectors and a prominent play button
/// with a subtle circular background for better visual hierarchy.
struct ReplayControlsView: View {
    @ObservedObject var controller: ReplayController

    var body: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            // Timeline slider
            HStack(spacing: AppDesign.Spacing.small) {
                Text(controller.state.formattedCurrentTime)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { controller.state.progress },
                        set: { controller.seekToProgress($0) }
                    ),
                    in: 0...1
                )
                .tint(AppDesign.primaryBlue)

                Text(controller.state.formattedTotalDuration)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }

            // Playback controls row
            HStack(spacing: AppDesign.Spacing.xLarge) {
                // Step backward
                Button(action: controller.stepBackward) {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step backward (←)")
                .accessibilityLabel("Step backward")
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!controller.isPlaying && controller.state.currentTime == 0)

                // Play/Pause — prominent circular button
                Button(action: controller.togglePlayPause) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .shadow(color: AppDesign.primaryBlue.opacity(0.2), radius: 4, y: 2)
                        )
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"))
                .accessibilityLabel(controller.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"))
                .keyboardShortcut(.space, modifiers: [])

                // Step forward
                Button(action: controller.stepForward) {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step forward (→)")
                .accessibilityLabel("Step forward")
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!controller.isPlaying && controller.state.currentTime >= controller.state.totalDuration)

                Spacer()

                // Speed control pills
                HStack(spacing: AppDesign.Spacing.xxSmall) {
                    Text("Speed")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)

                    ForEach(ReplayController.speedOptions, id: \.self) { speed in
                        Button(action: { controller.setSpeed(speed) }) {
                            Text(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))
                                .font(AppDesign.Typography.compactMetric)
                                .padding(.horizontal, AppDesign.Spacing.small)
                                .padding(.vertical, AppDesign.Spacing.xxSmall)
                                .background(
                                    Capsule()
                                        .fill(
                                            controller.state.playbackSpeed == speed
                                                ? AppDesign.primaryBlue.opacity(0.15)
                                                : Color.clear
                                        )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            controller.state.playbackSpeed == speed
                                                ? AppDesign.primaryBlue.opacity(0.3)
                                                : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            controller.state.playbackSpeed == speed
                                ? AppDesign.primaryBlue
                                : .secondary
                        )
                    }
                }

                Spacer()

                // Distance display
                Text(controller.state.formattedCurrentDistance)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(AppDesign.MetricColor.distance)
            }
        }
    }
}
