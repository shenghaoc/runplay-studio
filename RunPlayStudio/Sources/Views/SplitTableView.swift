import SwiftUI

/// Displays kilometer splits in a table format.
struct SplitTableView: View {
    let splits: [RunSplit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Splits")
                .font(.headline)

            Table(splits) {
                TableColumn("Split") { split in
                    Text("\(split.splitIndex)")
                        .monospacedDigit()
                }
                .width(40)

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
