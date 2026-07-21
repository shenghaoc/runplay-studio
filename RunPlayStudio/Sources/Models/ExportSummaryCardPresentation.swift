import AppKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Legend values for export (mirrors live map semantics without SwiftUI view state).
struct RouteMetricLegendModel: Hashable, Sendable {
    let mode: WorkoutRouteColorMode
    let scale: RouteMetricScale
    let showsNoData: Bool
    let coverageFraction: Double

    var lowerEndLabel: String {
        switch mode {
        case .pace: return "Faster"
        case .heartRate, .correctedElevation: return "Lower"
        case .solid: return ""
        }
    }

    var upperEndLabel: String {
        switch mode {
        case .pace: return "Slower"
        case .heartRate, .correctedElevation: return "Higher"
        case .solid: return ""
        }
    }

    var directionSummary: String {
        switch mode {
        case .pace: return "Faster → Slower"
        case .heartRate: return "Lower HR → Higher HR"
        case .correctedElevation: return "Lower Elevation → Higher Elevation"
        case .solid: return ""
        }
    }
}

/// Studio-level presentation model for the PNG summary card.
///
/// Keeps `NSImage` / SwiftUI types out of Core.
struct ExportSummaryCardPresentation {
    let model: ExportSummaryCardModel
    let mapImage: NSImage?
    let routeLegend: RouteMetricLegendModel?
    let appearance: PNGSummaryExportAppearance
    let layout: PNGSummaryCardLayout

    var palette: PNGSummaryExportPalette {
        PNGSummaryExportPalette.palette(for: appearance)
    }

    var includesMap: Bool { mapImage != nil }
}

/// Deterministic Light/Dark colors for PNG export (never ambient window colors).
struct PNGSummaryExportPalette: Sendable {
    let pageBackground: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let divider: Color
    let brand: Color
    let mapBorder: Color
    let footerText: Color
    let distance: Color
    let duration: Color
    let pace: Color
    let elevation: Color
    let elevationLoss: Color
    let heartRate: Color
    let noData: Color

    static func palette(for appearance: PNGSummaryExportAppearance) -> PNGSummaryExportPalette {
        switch appearance {
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let light = PNGSummaryExportPalette(
        pageBackground: Color(srgbHex: 0xF5F5F7),
        cardBackground: Color(srgbHex: 0xFFFFFF),
        primaryText: Color(srgbHex: 0x1C1C1E),
        secondaryText: Color(srgbHex: 0x3A3A3C),
        tertiaryText: Color(srgbHex: 0x8E8E93),
        divider: Color(srgbHex: 0xD1D1D6),
        brand: Color(srgbHex: 0x0A84FF),
        mapBorder: Color(srgbHex: 0xC7C7CC),
        footerText: Color(srgbHex: 0x8E8E93),
        distance: Color(srgbHex: 0x0A84FF),
        duration: Color(srgbHex: 0x64D2FF),
        pace: Color(srgbHex: 0x409CFF),
        elevation: Color(srgbHex: 0x30D158),
        elevationLoss: Color(srgbHex: 0xBF5AF2),
        heartRate: Color(srgbHex: 0xFF453A),
        noData: Color(srgbHex: RouteMetricPalette.noDataHex, opacity: RouteMetricPalette.noDataOpacity)
    )

    static let dark = PNGSummaryExportPalette(
        pageBackground: Color(srgbHex: 0x1C1C1E),
        cardBackground: Color(srgbHex: 0x2C2C2E),
        primaryText: Color(srgbHex: 0xF5F5F7),
        secondaryText: Color(srgbHex: 0xEBEBF5).opacity(0.8),
        tertiaryText: Color(srgbHex: 0xEBEBF5).opacity(0.45),
        divider: Color(srgbHex: 0x48484A),
        brand: Color(srgbHex: 0x0A84FF),
        mapBorder: Color(srgbHex: 0x636366),
        footerText: Color(srgbHex: 0xEBEBF5).opacity(0.45),
        distance: Color(srgbHex: 0x0A84FF),
        duration: Color(srgbHex: 0x64D2FF),
        pace: Color(srgbHex: 0x409CFF),
        elevation: Color(srgbHex: 0x30D158),
        elevationLoss: Color(srgbHex: 0xBF5AF2),
        heartRate: Color(srgbHex: 0xFF453A),
        noData: Color(srgbHex: RouteMetricPalette.noDataHex, opacity: RouteMetricPalette.noDataOpacity)
    )
}

private extension Color {
    init(srgbHex: UInt, opacity: Double = 1) {
        let r = Double((srgbHex >> 16) & 0xFF) / 255
        let g = Double((srgbHex >> 8) & 0xFF) / 255
        let b = Double(srgbHex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
