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
///
/// **Localization:** every label resolves through `studioLocalized` in the
/// presentation's locale (never SwiftUI's main-bundle lookup), so a pinned
/// locale renders the same card in the app and in tests. Columns size to their
/// content rather than to widths tuned for Latin glyphs, and the whole card is
/// typeset in its language so Han characters take the Simplified or
/// Traditional font.
struct ExportSummaryCardView: View {
    let presentation: ExportSummaryCardPresentation
    /// The card's fixed labels, resolved once in the presentation's language.
    let labels: ExportSummaryCardLabels

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
        self.labels = ExportSummaryCardLabels(locale: nil)
    }

    init(presentation: ExportSummaryCardPresentation) {
        self.presentation = presentation
        self.labels = ExportSummaryCardLabels(locale: presentation.locale)
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
        .typesettingLanguage(presentation.typesettingLanguage)
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
            Text(labels.legendTitle(modeName: legend.mode.localizedName(locale: presentation.locale)))
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
                    Text(legend.lowerEndLabel(locale: presentation.locale))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                VStack(alignment: .center, spacing: 1) {
                    Text(legend.scale.medianLabel)
                        .font(.system(size: 12, design: .monospaced))
                    Text(labels.median)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(legend.scale.upperLabel)
                        .font(.system(size: 12, design: .monospaced))
                    Text(legend.upperEndLabel(locale: presentation.locale))
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
                    Text(labels.noData)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            Text(legend.directionSummary(locale: presentation.locale))
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
            Text(labels.summary)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: presentation.includesMap ? 10 : AppDesign.Spacing.large) {
                ExportMetricTile(label: labels.distance, value: model.distanceText, icon: "figure.run", color: palette.distance, palette: palette)
                ExportMetricTile(label: labels.elapsed, value: model.elapsedTimeText, icon: "clock", color: palette.duration, palette: palette)
                ExportMetricTile(label: labels.active, value: model.activeTimeText, icon: "timer", color: palette.duration, palette: palette)
                ExportMetricTile(label: labels.movingEstimated, value: model.movingTimeText, icon: "figure.run", color: palette.duration, palette: palette)
                ExportMetricTile(label: labels.paused, value: model.pausedTimeText, icon: "pause.circle", color: palette.secondaryText, palette: palette)
                ExportMetricTile(label: labels.activePace, value: model.activePaceText, icon: "speedometer", color: palette.pace, palette: palette)
                ExportMetricTile(label: labels.movingPaceEstimated, value: model.movingPaceText, icon: "figure.run", color: palette.pace, palette: palette)
                ExportMetricTile(label: labels.elapsedPace, value: model.elapsedPaceText, icon: "clock.arrow.circlepath", color: palette.pace, palette: palette)
                ExportMetricTile(label: labels.correctedGain, value: model.elevationGainText, icon: "arrow.up.circle", color: palette.elevation, palette: palette)
                ExportMetricTile(label: labels.correctedLoss, value: model.elevationLossText, icon: "arrow.down.circle", color: palette.elevationLoss, palette: palette)

                if let hr = model.heartRateText {
                    ExportMetricTile(label: labels.averageHeartRate, value: hr, icon: "heart.fill", color: palette.heartRate, palette: palette)
                }
                if let maxHR = model.maxHeartRateText {
                    ExportMetricTile(label: labels.maximumHeartRate, value: maxHR, icon: "heart.circle.fill", color: palette.heartRate, palette: palette)
                }

                if !presentation.includesMap {
                    ExportMetricTile(label: labels.dataPoints, value: model.pointCountText, icon: "point.3.connected.trianglepath.dotted", color: palette.primaryText, palette: palette)
                }
            }
        }
    }

    // MARK: - Segments

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack {
                Text(labels.keySegments)
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
                Text(labels.splits)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.tertiaryText)
                if let truncation = model.splitsTruncationText {
                    Spacer()
                    Text(truncation)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                }
            }

            // Columns size to the widest cell, so translated headers never
            // truncate inside widths sized for Latin text.
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: AppDesign.Spacing.medium) {
                GridRow {
                    Text(labels.split)
                    Text(labels.distance)
                    Text(labels.elapsed)
                    Text(labels.active)
                    Text(labels.activePace)
                    Text(labels.elapsedPace)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)

                ForEach(model.splits) { split in
                    GridRow {
                        Text(verbatim: String(split.index))
                        Text(split.distance)
                        Text(split.elapsed)
                        Text(split.active)
                        Text(split.activePace)
                        Text(split.elapsedPace)
                    }
                    .font(.system(size: presentation.includesMap ? 12 : 14, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primaryText)
                }
            }
            .lineLimit(1)
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
        case "orange": return AppDesign.comparisonOrange
        case "purple": return palette.elevationLoss
        case "yellow": return AppDesign.warmYellow
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
                    .minimumScaleFactor(0.75)
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

/// Every fixed label on the summary card, resolved once in the card's
/// language. `nil` follows the app; a pinned locale renders the same card in
/// the app and in tests.
struct ExportSummaryCardLabels {
    let summary: String
    let keySegments: String
    let splits: String
    let split: String
    let distance: String
    let elapsed: String
    let active: String
    let movingEstimated: String
    let paused: String
    let activePace: String
    let movingPaceEstimated: String
    let elapsedPace: String
    let correctedGain: String
    let correctedLoss: String
    let averageHeartRate: String
    let maximumHeartRate: String
    let dataPoints: String
    let median: String
    let noData: String
    private let locale: Locale?

    init(locale: Locale?) {
        self.locale = locale
        func localized(_ keyAndValue: String.LocalizationValue) -> String {
            studioLocalized(keyAndValue, locale: locale)
        }
        summary = localized("Summary")
        keySegments = localized("Key Segments")
        splits = localized("Splits")
        split = localized("Split")
        distance = localized("Distance")
        elapsed = localized("Elapsed")
        active = localized("Active")
        movingEstimated = localized("Moving (est.)")
        // "Paused" is also a state elsewhere in the app; here it is a duration.
        paused = String(localized: LocalizedStringResource(
            "summary_card.paused_time",
            defaultValue: "Paused",
            locale: locale ?? .current,
            bundle: .atURL(StudioLocalization.bundle.bundleURL),
            comment: "Card tile: the run's total paused time"
        ))
        activePace = localized("Active Pace")
        movingPaceEstimated = localized("Moving Pace (est.)")
        elapsedPace = localized("Elapsed Pace")
        correctedGain = localized("Corrected Gain")
        correctedLoss = localized("Corrected Loss")
        averageHeartRate = localized("Avg HR")
        maximumHeartRate = localized("Max HR")
        dataPoints = localized("Data Points")
        median = localized("Median")
        noData = localized("No data")
    }

    /// The route legend's heading for a colour mode.
    func legendTitle(modeName: String) -> String {
        studioLocalized("\(modeName) — Relative to this workout", locale: locale)
    }

    /// Every label, for checks that the card is fully translated.
    var all: [String] {
        [
            summary, keySegments, splits, split, distance, elapsed, active, movingEstimated, paused,
            activePace, movingPaceEstimated, elapsedPace, correctedGain, correctedLoss,
            averageHeartRate, maximumHeartRate, dataPoints, median, noData,
        ]
    }
}
