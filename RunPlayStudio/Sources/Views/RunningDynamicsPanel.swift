import SwiftUI
import RunPlayCore

/// Collapsible running-power and dynamics detail panel for the Charts tab.
///
/// Numeric summary only — running dynamics deliberately stay off the main
/// charts. VoiceOver reads combined label/value rows; nothing here announces
/// per replay frame, and colour never carries meaning alone (rows are plain
/// label/value text).
struct RunningDynamicsPanel: View {
    let workout: RunWorkout
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                ForEach(RunningDynamicsPanel.rows(for: workout), id: \.label) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.value).monospacedDigit()
                    }
                    .font(AppDesign.Typography.compactMetric)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }

                if let provenance = RunningDynamicsPanel.provenanceText(for: workout) {
                    Text(provenance)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.tertiary)
                }

                ForEach(workout.developerFieldSummary?.notes ?? [], id: \.self) { note in
                    Text(note)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, AppDesign.Spacing.small)
        } label: {
            Label(RunningDynamicsPanel.title(for: workout), systemImage: "bolt.horizontal")
                .font(AppDesign.Typography.compactMetric)
        }
        .padding(.horizontal)
        .accessibilityHint("Running power and dynamics summary with source provenance")
    }

    /// Pure row derivation so the panel's content is unit-testable.
    static func rows(for workout: RunWorkout) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        let summary = workout.summary
        if let value = summary.averagePowerWatts {
            rows.append(("Average Power", DisplayFormatter.formatPower(value)))
        }
        if let value = summary.maxPowerWatts {
            rows.append(("Max Power", DisplayFormatter.formatPower(value)))
        }
        if let value = summary.best20MinutePowerWatts {
            rows.append(("Best 20 min Power", DisplayFormatter.formatPower(value)))
        }
        if let value = summary.averageGroundContactTimeMilliseconds {
            rows.append(("Average Ground Contact Time", DisplayFormatter.formatGroundContactTime(value)))
        }
        if let value = summary.averageVerticalOscillationMillimeters {
            rows.append(("Average Vertical Oscillation", DisplayFormatter.formatVerticalOscillation(value)))
        }
        if let value = summary.averageVerticalRatioPercent {
            rows.append(("Average Vertical Ratio", DisplayFormatter.formatVerticalRatio(value)))
        }
        if let value = summary.averageStanceTimeBalancePercent {
            rows.append(("Average Stance Time Balance", DisplayFormatter.formatStanceTimeBalance(value)))
        }
        if let value = summary.averageStepLengthMeters {
            rows.append(("Average Step Length", DisplayFormatter.formatStepLength(value)))
        }
        return rows
    }

    static func title(for workout: RunWorkout) -> String {
        let count = rows(for: workout).count
        return count == 0
            ? "Power & Running Dynamics"
            : "Power & Running Dynamics (\(count) metrics)"
    }

    /// Which device or application produced the power data.
    static func provenanceText(for workout: RunWorkout) -> String? {
        guard let summary = workout.developerFieldSummary else {
            return workout.hasPowerData ? "Power from the watch's native power field." : nil
        }
        if summary.powerSourceIsNativeRecordField {
            return "Power from the watch's native power field."
        }
        if let index = summary.powerSourceDeveloperDataIndex {
            let application = summary.sources.first { $0.developerDataIndex == index }
            if let applicationID = application?.applicationIDHex {
                return "Power from developer data index \(index) (application id \(applicationID))."
            }
            return "Power from developer data index \(index)."
        }
        return nil
    }
}
