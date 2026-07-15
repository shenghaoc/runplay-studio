import SwiftUI
import RunPlayCore

/// Workspace for calculated distance splits and source-recorded laps.
///
/// Keeps one Splits tab with an internal mode selector when recorded laps exist.
/// Calculated splits and recorded laps remain distinct concepts.
struct SplitTableView: View {
    let splits: [RunSplit]
    let recordedLaps: [RecordedLap]
    var currentSplitIndex: Int? = nil
    var currentRecordedLapIndex: Int? = nil
    var onSeekToRecordedLap: ((RecordedLap) -> Void)? = nil

    @State private var mode: IntervalMode = .distanceSplits

    enum IntervalMode: String, CaseIterable, Identifiable {
        case distanceSplits = "Distance Splits"
        case recordedLaps = "Recorded Laps"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            header

            if showsModeSelector {
                Picker("Interval type", selection: $mode) {
                    ForEach(IntervalMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Interval type")
                .help("Distance Splits are calculated by RunPlay Studio. Recorded Laps come from the source file.")
            } else if recordedLaps.isEmpty {
                Text("No recorded laps in this file. Calculated distance splits are still available.")
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No recorded laps available")
            }

            switch effectiveMode {
            case .distanceSplits:
                DistanceSplitsTableView(
                    splits: splits,
                    currentSplitIndex: currentSplitIndex
                )
            case .recordedLaps:
                RecordedLapsTableView(
                    recordedLaps: recordedLaps,
                    currentRecordedLapIndex: currentRecordedLapIndex,
                    onSeekToRecordedLap: onSeekToRecordedLap
                )
            }
        }
    }

    private var showsModeSelector: Bool {
        !recordedLaps.isEmpty
    }

    private var effectiveMode: IntervalMode {
        if recordedLaps.isEmpty { return .distanceSplits }
        return mode
    }

    private var header: some View {
        Text(effectiveMode == .recordedLaps ? "Recorded Laps" : "Splits")
            .font(AppDesign.Typography.sectionHeadline)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Distance splits

private struct DistanceSplitsTableView: View {
    let splits: [RunSplit]
    var currentSplitIndex: Int? = nil

    var body: some View {
        let activeSplitID = currentSplitIndex.flatMap { index in
            index >= 0 && index < splits.count ? splits[index].id : nil
        }

        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            if let idx = currentSplitIndex, idx >= 0, idx < splits.count {
                let split = splits[idx]
                currentSplitBanner(split)
            }

            Table(splits) {
                TableColumn("Split") { split in
                    HStack(spacing: AppDesign.Spacing.small) {
                        Image(systemName: "circle.fill")
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(AppDesign.comparisonOrange)
                            .opacity(split.id == activeSplitID ? 1 : 0)
                            .accessibilityHidden(true)
                        Text("\(split.splitIndex)")
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "Split \(split.splitIndex), distance \(String(format: "%.2f km", split.distanceMeters / 1000)), elapsed \(split.formattedElapsed), active \(split.formattedActive), active pace \(split.formattedPace)"
                    )
                }
                .width(50)

                TableColumn("Distance") { split in
                    Text(String(format: "%.2f km", split.distanceMeters / 1000))
                        .monospacedDigit()
                }
                .width(80)

                TableColumn("Elapsed") { split in
                    Text(split.formattedElapsed)
                        .monospacedDigit()
                }
                .width(60)

                TableColumn("Active") { split in
                    Text(split.formattedActive)
                        .monospacedDigit()
                }
                .width(60)

                TableColumn("Moving (est.)") { split in
                    Text(split.formattedMoving)
                        .monospacedDigit()
                }
                .width(90)

                TableColumn("Moving Pace (est.)") { split in
                    Text(split.formattedMovingPace)
                        .monospacedDigit()
                }
                .width(115)

                TableColumn("Active Pace") { split in
                    Text(split.formattedPace)
                        .monospacedDigit()
                }
                .width(85)

                TableColumn("Elapsed Pace") { split in
                    Text(split.formattedElapsedPace)
                        .monospacedDigit()
                }
                .width(90)

                TableColumn("HR") { split in
                    optionalBPM(split.averageHeartRateBPM)
                }
                .width(70)

                TableColumn("Elev") { split in
                    optionalElev(split.elevationGainMeters)
                }
                .width(70)
            }
        }
    }

    private func currentSplitBanner(_ split: RunSplit) -> some View {
        HStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "flag.fill")
                .foregroundStyle(AppDesign.comparisonOrange)
            Text("Current: Split \(split.splitIndex)")
                .font(AppDesign.Typography.compactMetric)
            Text("Active pace \(split.formattedPace)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
            Text("Active \(split.formattedActive)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
            Text("Moving (est.) \(split.formattedMoving)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
            Text("Elapsed \(split.formattedElapsed)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
        }
        .padding(AppDesign.Spacing.small)
        .background(AppDesign.comparisonOrange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: AppDesign.Radius.small)
                .strokeBorder(AppDesign.comparisonOrange.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current split \(split.splitIndex)")
        .accessibilityValue(
            "Active pace \(split.formattedPace), active time \(split.formattedActive), elapsed time \(split.formattedElapsed)"
        )
    }

    @ViewBuilder
    private func optionalBPM(_ value: Double?) -> some View {
        if let value {
            Text("\(Int(value)) bpm")
                .monospacedDigit()
                .foregroundStyle(AppDesign.MetricColor.heartRate)
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }

    @ViewBuilder
    private func optionalElev(_ value: Double?) -> some View {
        if let value {
            Text(String(format: "+%.0f m", value))
                .monospacedDigit()
                .foregroundStyle(AppDesign.MetricColor.elevation)
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }
}

// MARK: - Recorded laps

private struct RecordedLapsTableView: View {
    let recordedLaps: [RecordedLap]
    var currentRecordedLapIndex: Int? = nil
    var onSeekToRecordedLap: ((RecordedLap) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            if let idx = currentRecordedLapIndex, idx >= 0, idx < recordedLaps.count {
                currentLapBanner(recordedLaps[idx])
            }

            // List avoids SwiftUI Table type-checker limits with many columns + selection.
            List {
                // Keeping the header in the List gives it exactly the same
                // system-managed horizontal insets as every data row.
                recordedLapHeader
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(.isHeader)

                ForEach(recordedLaps) { lap in
                    Button {
                        onSeekToRecordedLap?(lap)
                    } label: {
                        recordedLapRow(lap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Seek to Lap Start") {
                            onSeekToRecordedLap?(lap)
                        }
                    }
                    .listRowBackground(rowBackground(for: lap))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .help("Click a recorded lap to seek replay to that lap start. Replay pauses first.")
        }
    }

    private var recordedLapHeader: some View {
        HStack(spacing: AppDesign.Spacing.medium) {
            Color.clear.frame(width: 16)
            header("Lap", width: 28, alignment: .leading)
            header("Trigger", width: 90, alignment: .leading)
            header("Distance", width: 72)
            header("Elapsed", width: 56)
            header("Active", width: 56)
            header("Moving", width: 64)
            header("Active Pace", width: 72)
            header("Moving Pace", width: 88)
            header("HR", width: 40)
            header("Elev", width: 56)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recorded lap columns")
        .accessibilityValue("Lap, trigger, distance, elapsed, active, moving, active pace, moving pace, heart rate, elevation")
    }

    private func header(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .trailing
    ) -> some View {
        Text(text)
            .font(AppDesign.Typography.compactLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, alignment: alignment)
    }

    private func currentLapBanner(_ lap: RecordedLap) -> some View {
        HStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(AppDesign.primaryBlue)
            Text("Current: Recorded lap \(lap.lapIndex)")
                .font(AppDesign.Typography.compactMetric)
            Text(lap.trigger.displayName)
                .font(AppDesign.Typography.compactMetric)
            Text("Active \(lap.formattedActive)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
            Text("Moving (est.) \(lap.formattedMoving)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
        }
        .padding(AppDesign.Spacing.small)
        .background(AppDesign.primaryBlue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.small))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current recorded lap \(lap.lapIndex)")
    }

    private func recordedLapRow(_ lap: RecordedLap) -> some View {
        let isCurrent = isCurrentLap(lap)
        return HStack(spacing: AppDesign.Spacing.medium) {
            Image(systemName: "circle.fill")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(AppDesign.primaryBlue)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text("\(lap.lapIndex)")
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
                .frame(width: 28, alignment: .leading)

            Text(lap.trigger.displayName)
                .font(AppDesign.Typography.compactMetric)
                .frame(width: 90, alignment: .leading)

            metric(String(format: "%.2f km", lap.distanceMeters / 1000), width: 72)
            metric(lap.formattedElapsed, width: 56)
            metric(lap.formattedActive, width: 56)
            metric(lap.formattedMoving, width: 64)
            metric(lap.formattedActivePace, width: 72)
            metric(lap.formattedMovingPace, width: 88)

            if let hr = lap.averageHeartRateBPM {
                Text("\(Int(hr))")
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(AppDesign.MetricColor.heartRate)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundStyle(.quaternary)
                    .frame(width: 40, alignment: .trailing)
            }

            if let elev = lap.elevationGainMeters {
                Text(String(format: "+%.0f m", elev))
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    .foregroundStyle(AppDesign.MetricColor.elevation)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("—")
                    .foregroundStyle(.quaternary)
                    .frame(width: 56, alignment: .trailing)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: lap))
        .accessibilityHint("Activates seeking replay to this lap start")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func metric(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(AppDesign.Typography.compactMetric.monospacedDigit())
            .frame(width: width, alignment: .trailing)
    }

    private func isCurrentLap(_ lap: RecordedLap) -> Bool {
        guard let idx = currentRecordedLapIndex,
              idx >= 0,
              idx < recordedLaps.count
        else { return false }
        return recordedLaps[idx].id == lap.id
    }

    private func rowBackground(for lap: RecordedLap) -> Color {
        isCurrentLap(lap) ? AppDesign.primaryBlue.opacity(0.08) : Color.clear
    }

    private func accessibilityLabel(for lap: RecordedLap) -> String {
        var parts = [
            "Recorded lap \(lap.lapIndex)",
            "trigger \(lap.trigger.displayName)",
            "distance \(String(format: "%.2f km", lap.distanceMeters / 1000))",
            "elapsed \(lap.formattedElapsed)",
            "active \(lap.formattedActive)",
            "moving estimated \(lap.formattedMoving)",
            "active pace \(lap.formattedActivePace)"
        ]
        if let hr = lap.averageHeartRateBPM {
            parts.append("average heart rate \(Int(hr))")
        }
        return parts.joined(separator: ", ")
    }
}
