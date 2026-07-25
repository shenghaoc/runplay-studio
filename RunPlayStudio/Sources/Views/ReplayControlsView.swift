import SwiftUI
import RunPlayCore

/// Controls for the route replay: play/pause, timeline, speed.
///
/// Uses pill-style speed selectors and a prominent play button with a native
/// material background for clear visual hierarchy.
///
/// Global play/pause, seek, speed, and restart shortcuts live in the Replay
/// menu (`WorkoutViewCommands`). Bare Left/Right frame steps remain local to
/// these buttons so tables, lists, and text fields keep native arrow behaviour.
struct ReplayControlsView: View {
    @ObservedObject var controller: ReplayController
    @FocusState private var controlsFocused: Bool

    var body: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            // Timeline slider
            HStack(spacing: AppDesign.Spacing.small) {
                Text(controller.state.formattedCurrentTime)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { controller.state.progress },
                        set: { controller.seekToProgress($0) }
                    ),
                    in: 0...1
                )
                .tint(AppDesign.primaryBlue)
                .help("Replay follows elapsed time, including pauses and recording gaps.")
                .accessibilityLabel("Elapsed replay time")
                .accessibilityValue(
                    "\(controller.state.formattedCurrentTime) of \(controller.state.formattedTotalDuration)"
                )
                .accessibilityHint("Adjustable. Drag or use arrow keys when focused.")

                Text(controller.state.formattedTotalDuration)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Elapsed replay timeline")

            // Playback controls row
            HStack(spacing: AppDesign.Spacing.xLarge) {
                Button(action: controller.stepBackward) {
                    Image(systemName: "backward.frame.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step backward one route point when replay controls are focused")
                .accessibilityLabel("Step backward")
                .accessibilityHint("Moves to the previous route point")
                .disabled(!controller.canStepBackward)
                .focused($controlsFocused)

                Button(action: controller.togglePlayPause) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(AppDesign.Typography.heading3)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(controller.isPlaying ? "Pause replay" : "Play replay")
                .accessibilityHint(controller.isPlaying ? "Pauses route playback" : "Starts route playback")
                .accessibilityValue(controller.isPlaying ? "Playing" : "Paused")

                Button(action: controller.stepForward) {
                    Image(systemName: "forward.frame.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step forward one route point when replay controls are focused")
                .accessibilityLabel("Step forward")
                .accessibilityHint("Moves to the next route point")
                .disabled(!controller.canStepForward)
                .focused($controlsFocused)

                Spacer()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppDesign.Spacing.xxSmall) {
                        Text("Speed")
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(.secondary)

                        ForEach(ReplayController.speedOptions, id: \.self) { speed in
                            speedPill(speed)
                        }
                    }

                    HStack(spacing: AppDesign.Spacing.xxSmall) {
                        Text("Speed")
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(.secondary)

                        Picker("Speed", selection: Binding(
                            get: { controller.state.playbackSpeed },
                            set: { controller.setSpeed($0) }
                        )) {
                            ForEach(ReplayController.speedOptions, id: \.self) { speed in
                                Text(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))
                                    .tag(speed)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.regular)
                        .accessibilityLabel("Replay speed")
                        .accessibilityValue(controller.state.formattedSpeed)
                    }
                }

                Spacer()

                Text(controller.state.formattedCurrentDistance)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(AppDesign.MetricColor.distance)
                    .accessibilityLabel("Current distance")
                    .accessibilityValue(controller.state.formattedCurrentDistance)
            }
            .onKeyPress(.leftArrow) {
                guard controlsFocused, controller.canStepBackward else {
                    return .ignored
                }
                controller.stepBackward()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard controlsFocused, controller.canStepForward else {
                    return .ignored
                }
                controller.stepForward()
                return .handled
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replay controls")
    }

    private func speedPill(_ speed: Double) -> some View {
        let isSelected = controller.state.playbackSpeed == speed
        return Button(action: { controller.setSpeed(speed) }) {
            Text(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))
                .font(AppDesign.Typography.compactMetric)
                .padding(.horizontal, AppDesign.Spacing.small)
                .padding(.vertical, AppDesign.Spacing.medium)
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(isSelected ? AppDesign.primaryBlue.opacity(0.15) : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? AppDesign.primaryBlue.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppDesign.primaryBlue : .secondary)
        .help("Replay at \(speed == 1.0 ? "normal" : String(format: "%.1f", speed)) speed")
        .accessibilityLabel("Replay speed \(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
