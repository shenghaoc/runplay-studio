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
    //
    // Semantic type tokens with clear role assignments.
    // Uses SwiftUI semantic font sizes to respect Dynamic Type.
    // Weights are assigned by role, not by feel:
    //   .bold     — primary data, hero values
    //   .semibold — section heads, metric values
    //   .medium   — labels, captions, secondary text
    //   .regular  — body prose (default .body)

    enum Typography {
        /// Display — largest hero numbers in export cards and key stat callouts.
        /// `.largeTitle` ~26pt on macOS.
        static let display = Font.system(.largeTitle, design: .rounded, weight: .bold)

        /// Page / panel title — primary heading for a screen or major section.
        /// `.title` ~22pt on macOS.
        static let heading1 = Font.system(.title, design: .default, weight: .bold)

        /// Section heading — card titles, chart headers, detail view headers.
        /// `.title2` ~17pt on macOS.
        static let heading2 = Font.title2.weight(.semibold)

        /// Sub-section heading — compare panels, export sub-headers.
        /// `.title3` ~15pt on macOS.
        static let heading3 = Font.title3.weight(.semibold)

        /// Section headline — panel titles, picker labels, filter bars.
        /// `.headline` ~13pt semibold on macOS.
        static let sectionHeadline = Font.headline.weight(.semibold)

        /// Primary body text — prose, descriptions, list rows.
        static let body = Font.body

        /// Body text with semibold weight — emphasis in prose.
        static let bodySemibold = Font.body.weight(.semibold)

        /// Secondary / helper text — chart footnotes, hints, metadata.
        /// `.subheadline` ~11pt on macOS.
        static let secondary = Font.subheadline

        /// Large metric value — prominent data numbers (title3 at ~15pt).
        /// Used for key metrics in detail panels and comparison cards.
        static let metricLarge = Font.system(.title3, design: .rounded, weight: .semibold)

        /// Standard metric value — data numbers in badges, cards, and tables.
        /// `.callout` ~12pt semibold on macOS.
        static let metricValue = Font.callout.weight(.semibold)

        /// Metric label — label text beneath metric values.
        /// `.caption` ~11pt medium on macOS.
        static let metricLabel = Font.caption.weight(.medium)

        /// Compact metric — tighter data numbers for badge / sidebar contexts.
        /// `.caption` ~11pt medium on macOS (same base size as metricLabel, different context).
        static let compactMetric = Font.caption.weight(.medium)

        /// Compact label — smallest label text for tight spaces.
        /// `.caption2` ~10pt medium on macOS. Minimum readable size.
        static let compactLabel = Font.caption2.weight(.medium)

        /// Monospaced number value — aligns digits in tables and comparison columns.
        /// Uses `.body` design for readability at standard size; apply `.monospacedDigit()`.
        static let monoValue = Font.body.monospacedDigit()

        /// Monospaced number caption — compact aligned digits.
        /// Uses `.caption`; apply `.monospacedDigit()`.
        static let monoCaption = Font.caption.monospacedDigit()

        /// Empty-state icon — decorative symbol in empty views.
        /// `.largeTitle` weight .light for airy presence.
        static let emptyStateIcon = Font.system(size: 40, weight: .light)

        /// Empty-state heading — what the user should do.
        static let emptyStateHeading = Font.title2

        /// Empty-state body — why the feature matters.
        static let emptyStateBody = Font.subheadline
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
                    .font(.caption2.weight(.medium))
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

// MARK: - View Modifiers

extension View {
    /// Applies the standard panel background: control-background fill clipped to a large rounded rect.
    ///
    /// Use this on any panel, card, or container that should sit on the workspace background
    /// with the system's standard surface color and a consistent corner radius.
    func panelBackground() -> some View {
        background(AppDesign.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
    }
}
