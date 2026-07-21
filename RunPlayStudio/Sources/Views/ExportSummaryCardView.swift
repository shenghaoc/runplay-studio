import AppKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// SwiftUI view designed for PNG export.
///
/// Fixed-size card layout that renders consistently for image export.
/// Does not depend on live MapKit/SceneKit window content.
///
/// **Typography note:** This view intentionally uses inline `.system(size:)` calls
/// instead of `AppDesign.Typography` tokens because the export card renders at a
/// fixed 1200×1600 canvas — the standard typography scale is too small at this
/// resolution. If the export dimensions change, revisit these sizes.
struct ExportSummaryCardView: View {
    let presentation: ExportSummaryCardPresentation

    private var model: ExportSummaryCardModel { presentation.model }
    private var palette: PNGSummaryExportPalette { presentation.palette }

    let cardWidth: CGFloat = CGFloat(PNGSummaryExportDimensions.width)
    let cardHeight: CGFloat = CGFloat(PNGSummaryExportDimensions.height)

    /// Metrics-only convenience used by older call sites.
    init(model: ExportSummaryCardModel) {
        self.presentation = ExportSummaryCardPresentation(
            model: model,
            mapImage: nil,
            routeLegend: nil,
            appearance: .light,
            layout: model.layout
        )
    }

    init(presentation: ExportSummaryCardPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, presentation.includesMap ? 16 : 24)

            if presentation.includesMap {
                mapSection
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)

                if let legend = presentation.routeLegend {
                    exportLegendSection(legend)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 12)
                }
            } else {
                Divider().overlay(palette.divider)
            }

            metricsSection
                .padding(.horizontal, 40)
                .padding(.vertical, presentation.includesMap ? 12 : 24)

            if !model.segments.isEmpty {
                Divider().overlay(palette.divider)
                segmentsSection
                    .padding(.horizontal, 40)
                    .padding(.vertical, presentation.includesMap ? 10 : 24)
            }

            if !model.splits.isEmpty {
                Divider().overlay(palette.divider)
                splitsSection
                    .padding(.horizontal, 40)
                    .padding(.vertical, presentation.includesMap ? 10 : 24)
            }

            Spacer(minLength: 8)

            footerSection
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(palette.pageBackground)
        .foregroundStyle(palette.primaryText)
        .colorScheme(presentation.appearance == .dark ? .dark : .light)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text(model.appBranding)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(palette.brand)

            Text(model.workoutTitle)
                .font(.system(size: presentation.includesMap ? 28 : 34, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            HStack(spacing: AppDesign.Spacing.xLarge) {
                Label(model.dateText, systemImage: "calendar")
                Label(model.sourceText, systemImage: "square.and.arrow.down")
                if let recordedLapCountText = model.recordedLapCountText {
                    Label(recordedLapCountText, systemImage: "flag.checkered")
                }
            }
            .font(.system(size: presentation.includesMap ? 15 : 17))
            .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        Group {
            if let mapImage = presentation.mapImage {
                Image(nsImage: mapImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(palette.mapBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Legend

    private func exportLegendSection(_ legend: RouteMetricLegendModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(legend.mode.displayName) — Relative to this workout")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.secondaryText)

            HStack(spacing: 2) {
                ForEach(0..<RouteMetricPalette.policyBucketCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppDesign.RouteMetric.color(mode: legend.mode, bucket: .level(index)))
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: 320)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(legend.scale.lowerLabel)
                        .font(.system(size: 12, design: .monospaced))
                    Text(legend.lowerEndLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                VStack(alignment: .center, spacing: 1) {
                    Text(legend.scale.medianLabel)
                        .font(.system(size: 12, design: .monospaced))
                    Text("Median")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(legend.scale.upperLabel)
                        .font(.system(size: 12, design: .monospaced))
                    Text(legend.upperEndLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .frame(maxWidth: 320)

            if legend.showsNoData {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.noData)
                        .frame(width: 14, height: 8)
                    Text("No data")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            Text(legend.directionSummary)
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
        }
        .padding(10)
        .background(palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Main Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Summary")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: presentation.includesMap ? 10 : AppDesign.Spacing.large) {
                ExportMetricTile(label: "Distance", value: model.distanceText, icon: "figure.run", color: palette.distance, palette: palette)
                ExportMetricTile(label: "Elapsed", value: model.elapsedTimeText, icon: "clock", color: palette.duration, palette: palette)
                ExportMetricTile(label: "Active", value: model.activeTimeText, icon: "timer", color: palette.duration, palette: palette)
                ExportMetricTile(label: "Moving (est.)", value: model.movingTimeText, icon: "figure.run", color: palette.duration, palette: palette)
                ExportMetricTile(label: "Paused", value: model.pausedTimeText, icon: "pause.circle", color: palette.secondaryText, palette: palette)
                ExportMetricTile(label: "Active Pace", value: model.activePaceText, icon: "speedometer", color: palette.pace, palette: palette)
                ExportMetricTile(label: "Moving Pace (est.)", value: model.movingPaceText, icon: "figure.run", color: palette.pace, palette: palette)
                ExportMetricTile(label: "Elapsed Pace", value: model.elapsedPaceText, icon: "clock.arrow.circlepath", color: palette.pace, palette: palette)
                ExportMetricTile(label: "Corrected Gain", value: model.elevationGainText, icon: "arrow.up.circle", color: palette.elevation, palette: palette)
                ExportMetricTile(label: "Corrected Loss", value: model.elevationLossText, icon: "arrow.down.circle", color: palette.elevationLoss, palette: palette)

                if let hr = model.heartRateText {
                    ExportMetricTile(label: "Avg HR", value: hr, icon: "heart.fill", color: palette.heartRate, palette: palette)
                }
                if let maxHR = model.maxHeartRateText {
                    ExportMetricTile(label: "Max HR", value: maxHR, icon: "heart.circle.fill", color: palette.heartRate, palette: palette)
                }

                if !presentation.includesMap {
                    ExportMetricTile(label: "Data Points", value: model.pointCountText, icon: "point.3.connected.trianglepath.dotted", color: palette.primaryText, palette: palette)
                }
            }
        }
    }

    // MARK: - Segments

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack {
                Text("Key Segments")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.tertiaryText)
                if let truncation = model.segmentsTruncationText {
                    Spacer()
                    Text(truncation)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            ForEach(model.segments) { segment in
                HStack {
                    Image(systemName: segment.icon)
                        .font(.system(size: 13))
                        .frame(width: 18)
                        .foregroundStyle(colorForSegment(segment.color))

                    Text(segment.title)
                        .font(.system(size: presentation.includesMap ? 13 : 15, weight: .medium))
                        .foregroundStyle(palette.primaryText)

                    Spacer()

                    Text(segment.value)
                        .font(.system(size: presentation.includesMap ? 13 : 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.primaryText)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Splits

    private var splitsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack {
                Text("Splits")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.tertiaryText)
                if let truncation = model.splitsTruncationText {
                    Spacer()
                    Text(truncation)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            HStack {
                Text("Split").frame(width: 50, alignment: .leading)
                Text("Distance").frame(width: 80, alignment: .leading)
                Text("Elapsed").frame(width: 70, alignment: .leading)
                Text("Active").frame(width: 70, alignment: .leading)
                Text("Active Pace").frame(width: 90, alignment: .leading)
                Text("Elapsed Pace").frame(width: 90, alignment: .leading)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.tertiaryText)

            ForEach(model.splits) { split in
                HStack {
                    Text("\(split.index)").frame(width: 50, alignment: .leading)
                    Text(split.distance).frame(width: 80, alignment: .leading)
                    Text(split.elapsed).frame(width: 70, alignment: .leading)
                    Text(split.active).frame(width: 70, alignment: .leading)
                    Text(split.activePace).frame(width: 90, alignment: .leading)
                    Text(split.elapsedPace).frame(width: 90, alignment: .leading)
                }
                .font(.system(size: presentation.includesMap ? 12 : 14, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.primaryText)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Divider().overlay(palette.divider)
            Text(model.privacyNote)
                .font(.system(size: 12))
                .foregroundStyle(palette.footerText)
        }
    }

    // MARK: - Helpers

    private func colorForSegment(_ name: String) -> Color {
        switch name {
        case "blue": return palette.brand
        case "red": return palette.heartRate
        case "orange": return Color(hex: 0xFF9F0A)
        case "purple": return palette.elevationLoss
        case "yellow": return Color(hex: 0xFFD60A)
        default: return palette.secondaryText
        }
    }
}

/// Single metric tile for the export summary card with explicit palette colors.
struct ExportMetricTile: View {
    let label: String
    let value: String
    let icon: String
    var color: Color
    var palette: PNGSummaryExportPalette

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            HStack(spacing: AppDesign.Spacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color.opacity(0.85))
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }
}

/// Back-compat alias used by older tests/code that referenced MetricTile.
typealias MetricTile = ExportMetricTile
