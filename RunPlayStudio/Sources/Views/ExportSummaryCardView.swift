import SwiftUI
import RunPlayCore

/// SwiftUI view designed for PNG export.
///
/// Fixed-size card layout that renders consistently for image export.
/// Does not depend on MapKit or SceneKit content.
///
/// **Typography note:** This view intentionally uses inline `.system(size:)` calls
/// instead of `AppDesign.Typography` tokens because the export card renders at a
/// fixed 1200x1600pt canvas — the standard typography scale is too small at this
/// resolution. If the export dimensions change, revisit these sizes.
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
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text(model.appBranding)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppDesign.primaryBlue, AppDesign.MetricColor.pace],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text(model.workoutTitle)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(2)

            HStack(spacing: AppDesign.Spacing.xLarge) {
                Label(model.dateText, systemImage: "calendar")
                Label(model.sourceText, systemImage: "square.and.arrow.down")
            }
            .font(.system(size: 17))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Main Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Summary")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: AppDesign.Spacing.large) {
                MetricTile(label: "Distance", value: model.distanceText, icon: "figure.run", color: AppDesign.MetricColor.distance)
                MetricTile(label: "Duration", value: model.durationText, icon: "clock", color: AppDesign.MetricColor.duration)
                MetricTile(label: "Avg Pace", value: model.paceText, icon: "speedometer", color: AppDesign.MetricColor.pace)
                MetricTile(label: "Elev Gain", value: model.elevationGainText, icon: "arrow.up.circle", color: AppDesign.MetricColor.elevation)
                MetricTile(label: "Elev Loss", value: model.elevationLossText, icon: "arrow.down.circle", color: AppDesign.softPurple)

                if let hr = model.heartRateText {
                    MetricTile(label: "Avg HR", value: hr, icon: "heart.fill", color: AppDesign.MetricColor.heartRate)
                }
                if let maxHR = model.maxHeartRateText {
                    MetricTile(label: "Max HR", value: maxHR, icon: "heart.circle.fill", color: AppDesign.MetricColor.heartRate)
                }

                MetricTile(label: "Points", value: model.pointCountText, icon: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    // MARK: - Segments

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Key Segments")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tertiary)

            ForEach(model.segments) { segment in
                HStack {
                    Image(systemName: segment.icon)
                        .font(.system(size: 14))
                        .frame(width: 20)
                        .foregroundStyle(colorForSegment(segment.color))

                    Text(segment.title)
                        .font(.system(size: 15, weight: .medium))

                    Spacer()

                    Text(segment.value)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Splits

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Splits")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tertiary)

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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)

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
                .font(.system(size: 14, design: .rounded).monospacedDigit())
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Divider()
            Text(model.privacyNote)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func colorForSegment(_ name: String) -> Color {
        switch name {
        case "blue": return AppDesign.primaryBlue
        case "red": return AppDesign.alertRed
        case "orange": return AppDesign.comparisonOrange
        case "purple": return AppDesign.softPurple
        case "yellow": return AppDesign.warmYellow
        default: return .secondary
        }
    }
}

/// Single metric tile for the summary card.
///
/// Uses semantic colors and improved typography from the design system.
struct MetricTile: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            HStack(spacing: AppDesign.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color.opacity(0.7))
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppDesign.Spacing.medium)
        .background(AppDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }
}
