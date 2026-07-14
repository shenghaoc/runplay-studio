import SwiftUI
import RunPlayCore

/// Controls for the route replay: play/pause, timeline, speed.
///
/// Uses pill-style speed selectors and a prominent play button with a native
/// material background for clear visual hierarchy.
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
                .help("Replay follows elapsed time, including pauses and recording gaps.")
                .accessibilityLabel("Elapsed replay time")
                .accessibilityValue(
                    "\(controller.state.formattedCurrentTime) of \(controller.state.formattedTotalDuration)"
                )

                Text(controller.state.formattedTotalDuration)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Elapsed replay timeline")

            // Playback controls row
            HStack(spacing: AppDesign.Spacing.xLarge) {
                // Step backward — 44pt touch target
                Button(action: controller.stepBackward) {
                    Image(systemName: "backward.frame.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step backward (⌥←)")
                .accessibilityLabel("Step backward")
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(!controller.canStepBackward)

                // Play/Pause — prominent circular button, 44pt touch target
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
                .help(controller.isPlaying ? LocalizedStringKey("Pause (⌥Space)") : LocalizedStringKey("Play (⌥Space)"))
                .accessibilityLabel(controller.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"))
                .keyboardShortcut(.space, modifiers: .option)

                // Step forward — 44pt touch target
                Button(action: controller.stepForward) {
                    Image(systemName: "forward.frame.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Step forward (⌥→)")
                .accessibilityLabel("Step forward")
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(!controller.canStepForward)

                Spacer()

                // Speed control — pills on wide, compact on narrow
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

    private func speedPill(_ speed: Double) -> some View {
        Button(action: { controller.setSpeed(speed) }) {
            Text(speed == 1.0 ? "1×" : String(format: "%.1f×", speed))
                .font(AppDesign.Typography.compactMetric)
                .padding(.horizontal, AppDesign.Spacing.small)
                .padding(.vertical, AppDesign.Spacing.medium)
                .frame(minHeight: 44)
                .contentShape(Capsule())
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
        .help("Replay at \(speed == 1.0 ? "normal" : String(format: "%.1f", speed)) speed")
        .accessibilityLabel("Replay at \(speed == 1.0 ? "normal" : String(format: "%.1f", speed)) speed")
    }
}
