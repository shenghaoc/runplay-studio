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
        static let pace = primaryBlue
        static let speed = comparisonOrange
        static let elevation = energeticGreen
        static let heartRate = alertRed
        static let cadence = softPurple
        static let split = comparisonOrange
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
        static let compactMetric = Font.system(size: 11, weight: .medium, design: .default)

        /// Compact label — used for very tight label text.
        static let compactLabel = Font.system(size: 9, weight: .medium, design: .default)
    }

    // MARK: - Background Treatments

    /// Subtle grouped background for panels — lighter than window background.
    static let panelBackground = Color.primary.opacity(0.03)

    /// Card background with subtle warmth.
    static let cardBackground = Color.primary.opacity(0.04)

    /// Active/selected card background.
    static let activeCardBackground = Color.accentColor.opacity(0.08)

    /// Overlay backdrop for map controls.
    static let overlayBackground = Color(nsColor: .controlBackgroundColor).opacity(0.85)
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
