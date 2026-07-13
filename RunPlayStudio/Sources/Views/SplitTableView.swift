import SwiftUI
import RunPlayCore

/// Displays kilometer splits in a table format with current split highlighting.
///
/// Uses semantic colors for the current split indicator and improved typography.
struct SplitTableView: View {
    let splits: [RunSplit]
    var currentSplitIndex: Int? = nil

    var body: some View {
        let activeSplitID = currentSplitIndex.flatMap { index in
            index >= 0 && index < splits.count ? splits[index].id : nil
        }

        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text("Splits")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)

            // Current split highlight
            if let idx = currentSplitIndex, idx >= 0, idx < splits.count {
                let split = splits[idx]
                HStack(spacing: AppDesign.Spacing.small) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(AppDesign.comparisonOrange)
                    Text("Current: Split \(split.splitIndex)")
                        .font(AppDesign.Typography.compactMetric)
                    Text(split.formattedPace)
                        .font(AppDesign.Typography.compactMetric.monospacedDigit())
                    Text(split.formattedElapsed)
                        .font(AppDesign.Typography.compactMetric.monospacedDigit())
                }
                .padding(AppDesign.Spacing.small)
                .background(AppDesign.comparisonOrange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: AppDesign.Radius.small)
                        .strokeBorder(AppDesign.comparisonOrange.opacity(0.3), lineWidth: 1)
                )
            }

            Table(splits) {
                TableColumn("Split") { split in
                    HStack {
                        if split.id == activeSplitID {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(AppDesign.comparisonOrange)
                        }
                        Text("\(split.splitIndex)")
                            .monospacedDigit()
                    }
                }
                .width(50)

                TableColumn("Distance") { split in
                    Text(String(format: "%.2f km", split.distanceMeters / 1000))
                        .monospacedDigit()
                }
                .width(80)

                TableColumn("Time") { split in
                    Text(split.formattedElapsed)
                        .monospacedDigit()
                }
                .width(60)

                TableColumn("Pace") { split in
                    Text(split.formattedPace)
                        .monospacedDigit()
                }
                .width(70)

                TableColumn("HR") { split in
                    if let hr = split.averageHeartRateBPM {
                        Text("\(Int(hr)) bpm")
                            .monospacedDigit()
                            .foregroundStyle(AppDesign.MetricColor.heartRate)
                    } else {
                        Text("—")
                            .foregroundStyle(.quaternary)
                    }
                }
                .width(70)

                TableColumn("Elev") { split in
                    if let elev = split.elevationGainMeters {
                        Text(String(format: "+%.0f m", elev))
                            .monospacedDigit()
                            .foregroundStyle(AppDesign.MetricColor.elevation)
                    } else {
                        Text("—")
                            .foregroundStyle(.quaternary)
                    }
                }
                .width(70)
            }
        }
    }
}
