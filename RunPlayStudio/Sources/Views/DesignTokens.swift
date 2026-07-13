import RunPlayPlatform
import SwiftUI

/// Central design tokens for RunPlay Studio.
///
/// All views reference these tokens instead of hardcoding colors, spacing,
/// or typography values. This keeps the visual language cohesive and makes
/// future theme adjustments trivial.
enum AppDesign {

    // MARK: - Color Palette

    /// Primary brand blue — used for primary route, key actions, and emphasis.
    static let primaryBlue = Color(hex: 0x0A84FF)

    /// Warm comparison orange — used for comparison route and secondary emphasis.
    static let comparisonOrange = Color(hex: 0xFF9F0A)

    /// Energetic green — used for start markers, positive deltas, success states.
    static let energeticGreen = Color(hex: 0x30D158)

    /// Alert red — used for finish markers, negative deltas, heart rate.
    static let alertRed = Color(hex: 0xFF453A)

    /// Soft purple — used for elevation, descent segments.
    static let softPurple = Color(hex: 0xBF5AF2)

    /// Warm yellow — used for current position, caution states.
    static let warmYellow = Color(hex: 0xFFD60A)

    // MARK: - Semantic Metric Colors

    enum MetricColor {
        static let distance = primaryBlue
        static let duration = Color(hex: 0x64D2FF)
        /// Slightly lighter blue than distance, so pace/distance are distinguishable.
        static let pace = Color(hex: 0x409CFF)
        static let speed = comparisonOrange
        static let elevation = energeticGreen
        static let heartRate = alertRed
        static let cadence = softPurple
        static let split = comparisonOrange
    }

    // MARK: - Semantic Helpers

    /// Returns a green/red color for positive/negative deltas, with a dead-zone threshold.
    static func deltaColor(_ delta: Double?, threshold: Double = 0.5) -> Color {
        guard let d = delta, d.isFinite, abs(d) >= threshold else { return .secondary }
        return d < 0 ? energeticGreen : alertRed
    }

    // MARK: - Spacing Scale

    enum Spacing {
        /// 2pt — hairline gaps
        static let xxSmall: CGFloat = 2
        /// 4pt — tight gaps within components
        static let xSmall: CGFloat = 4
        /// 6pt — compact gaps
        static let small: CGFloat = 6
        /// 8pt — default inner padding
        static let medium: CGFloat = 8
        /// 12pt — standard component spacing
        static let large: CGFloat = 12
        /// 16pt — section-level spacing
        static let xLarge: CGFloat = 16
        /// 20pt — generous section gaps
        static let xxLarge: CGFloat = 20
        /// 24pt — major section separation
        static let xxxLarge: CGFloat = 24
    }

    // MARK: - Corner Radius

    enum Radius {
        /// 6pt — small badges, tags
        static let small: CGFloat = 6
        /// 8pt — cards, panels
        static let medium: CGFloat = 8
        /// 12pt — large cards, overlays
        static let large: CGFloat = 12
        /// 16pt — hero cards
        static let xLarge: CGFloat = 16
    }

    // MARK: - Typography

    enum Typography {
        /// Large hero metric — used for primary values in summary cards.
        static let heroMetric = Font.system(.title, design: .rounded, weight: .bold)

        /// Section headline — used for panel titles.
        static let sectionHeadline = Font.system(.subheadline, design: .default, weight: .semibold)

        /// Metric value — used for data values in badges and cards.
        static let metricValue = Font.system(.callout, design: .default, weight: .semibold)

        /// Metric label — used for labels beneath values.
        static let metricLabel = Font.system(.caption2, design: .default, weight: .medium)

        /// Compact metric — used for tight spaces like comparison badges.
        /// Uses `.caption` for Dynamic Type compatibility (~12pt on macOS).
        static let compactMetric = Font.caption.weight(.medium)

        /// Compact label — used for very tight label text.
        /// Uses `.caption2` for Dynamic Type compatibility (~10pt on macOS).
        static let compactLabel = Font.caption2.weight(.medium)

        /// Compact icon — used for inline icons in tight spaces like sidebar rows.
        static let compactIcon = Font.system(size: 8, weight: .medium)
    }

    // MARK: - Background Treatments

    /// Opaque grouped surface. Avoids muddy transparency over maps and charts.
    static let panelBackground = Color(nsColor: .controlBackgroundColor)

    /// Card background with subtle warmth.
    static let cardBackground = Color(nsColor: .underPageBackgroundColor)

    /// Active/selected card background.
    static let activeCardBackground = Color.accentColor.opacity(0.08)

    /// Overlay backdrop for map controls.
    static let overlayBackground = Color(nsColor: .controlBackgroundColor).opacity(0.85)

    /// The stable canvas behind every analysis workspace.
    static let workspaceBackground = Color(nsColor: .windowBackgroundColor)
}

// MARK: - Color Hex Initializer

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Shared Map Components

/// A compact map-mode indicator (2D/3D) for use in map overlays and legends.
struct MapModeBadge: View {
    let displayMode: RouteMapDisplayMode

    var body: some View {
        HStack(spacing: AppDesign.Spacing.xxSmall) {
            Circle()
                .fill(displayMode == .threeD ? AppDesign.MetricColor.elevation : AppDesign.MetricColor.distance)
                .frame(width: 5, height: 5)
            Text(displayMode == .threeD ? "3D" : "2D")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Shared Metric Components

/// Unified metric display — shows a label, value, and optional icon with a semantic color.
///
/// Supports two layout modes:
/// - `.centered` (default) — used in compact badge contexts like the live metrics panel.
/// - `.leading` — used in summary cards and detail rows.
struct MetricDisplay: View {
    enum Layout {
        case centered, leading
    }

    let label: String
    let value: String
    var icon: String? = nil
    var color: Color = .primary
    var layout: Layout = .centered

    var body: some View {
        VStack(alignment: alignment, spacing: AppDesign.Spacing.xxSmall) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(color.opacity(0.7))
            }

            Text(value)
                .font(AppDesign.Typography.metricValue.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
        }
    }

    private var alignment: HorizontalAlignment {
        layout == .leading ? .leading : .center
    }
}
