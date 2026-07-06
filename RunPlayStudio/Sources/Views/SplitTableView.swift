import SwiftUI
import RunPlayCore

/// Displays kilometer splits in a table format with current split highlighting.
struct SplitTableView: View {
    let splits: [RunSplit]
    var currentSplitIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits")
                .font(.headline)

            // Current split highlight
            if let idx = currentSplitIndex, idx < splits.count {
                let split = splits[idx]
                HStack {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                    Text("Current: Split \(split.splitIndex)")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(split.formattedPace)
                        .font(.caption)
                        .monospacedDigit()
                    Text(split.formattedElapsed)
                        .font(.caption)
                        .monospacedDigit()
                }
                .padding(6)
                .background(.orange.opacity(0.1))
                .cornerRadius(6)
            }

            Table(splits) {
                TableColumn("Split") { split in
                    HStack {
                        if currentSplitIndex != nil && splits.firstIndex(where: { $0.id == split.id }) == currentSplitIndex {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.orange)
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
                    } else {
                        Text("—")
                    }
                }
                .width(70)

                TableColumn("Elev") { split in
                    if let elev = split.elevationGainMeters {
                        Text(String(format: "+%.0f m", elev))
                            .monospacedDigit()
                    } else {
                        Text("—")
                    }
                }
                .width(70)
            }
        }
    }
}
