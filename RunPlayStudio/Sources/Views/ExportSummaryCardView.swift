import SwiftUI
import RunPlayCore

/// SwiftUI view designed for PNG export.
///
/// Fixed-size card layout that renders consistently for image export.
/// Does not depend on MapKit or SceneKit content.
struct ExportSummaryCardView: View {
    let model: ExportSummaryCardModel

    // Fixed export dimensions
    let cardWidth: CGFloat = 1200
    let cardHeight: CGFloat = 1600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerSection
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 24)

            Divider()

            // Main metrics
            metricsSection
                .padding(.horizontal, 40)
                .padding(.vertical, 24)

            Divider()

            // Segments
            if !model.segments.isEmpty {
                segmentsSection
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)

                Divider()
            }

            // Splits
            if !model.splits.isEmpty {
                splitsSection
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)

                Divider()
            }

            Spacer()

            // Footer
            footerSection
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.appBranding)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.blue)

            Text(model.workoutTitle)
                .font(.system(size: 36, weight: .bold))
                .lineLimit(2)

            HStack(spacing: 16) {
                Label(model.dateText, systemImage: "calendar")
                Label(model.sourceText, systemImage: "square.and.arrow.down")
            }
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Main Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 20) {
                MetricTile(label: "Distance", value: model.distanceText, icon: "figure.run")
                MetricTile(label: "Duration", value: model.durationText, icon: "clock")
                MetricTile(label: "Avg Pace", value: model.paceText, icon: "speedometer")
                MetricTile(label: "Elev Gain", value: model.elevationGainText, icon: "arrow.up.circle")
                MetricTile(label: "Elev Loss", value: model.elevationLossText, icon: "arrow.down.circle")

                if let hr = model.heartRateText {
                    MetricTile(label: "Avg HR", value: hr, icon: "heart.fill", color: .red)
                }
                if let maxHR = model.maxHeartRateText {
                    MetricTile(label: "Max HR", value: maxHR, icon: "heart.circle.fill", color: .red)
                }

                MetricTile(label: "Points", value: model.pointCountText, icon: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    // MARK: - Segments

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key Segments")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(model.segments) { segment in
                HStack {
                    Image(systemName: segment.icon)
                        .font(.system(size: 16))
                        .frame(width: 24)
                        .foregroundStyle(colorForSegment(segment.color))

                    Text(segment.title)
                        .font(.system(size: 16, weight: .medium))

                    Spacer()

                    Text(segment.value)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Splits

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Splits")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)

            // Header
            HStack {
                Text("Split")
                    .frame(width: 50, alignment: .leading)
                Text("Distance")
                    .frame(width: 80, alignment: .leading)
                Text("Pace")
                    .frame(width: 80, alignment: .leading)
                Text("Time")
                    .frame(width: 60, alignment: .leading)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)

            ForEach(model.splits) { split in
                HStack {
                    Text("\(split.index)")
                        .frame(width: 50, alignment: .leading)
                    Text(split.distance)
                        .frame(width: 80, alignment: .leading)
                    Text(split.pace)
                        .frame(width: 80, alignment: .leading)
                    Text(split.duration)
                        .frame(width: 60, alignment: .leading)
                }
                .font(.system(size: 15).monospacedDigit())
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(model.privacyNote)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func colorForSegment(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        default: return .gray
        }
    }
}

/// Single metric tile for the summary card.
struct MetricTile: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}
