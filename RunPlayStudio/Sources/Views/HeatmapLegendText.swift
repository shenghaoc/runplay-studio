import Foundation

/// Text and swatch rules for the Personal Heatmap legend and statistics (#205).
///
/// Kept as pure functions so the plural forms and the distinct-swatch rule
/// are unit-tested for every language without rendering the view. Each count
/// in a sentence has its own plural substitution in the catalog.
enum HeatmapLegendText {

    /// The run counts the legend draws a swatch for. The low swatch is always
    /// one run; the middle swatch is half the maximum. A count already drawn
    /// is not drawn again, so a maximum of 1, 2 or 3 shows one or two swatches.
    static func swatchCounts(maximumOverlap: Int) -> [Int] {
        let maximum = max(maximumOverlap, 1)
        let middle = max(1, maximum / 2)
        var counts = [1]
        if middle > 1, middle < maximum { counts.append(middle) }
        if maximum > 1 { counts.append(maximum) }
        return counts
    }

    static func legendAccessibilityLabel(maximumOverlap: Int, locale: Locale? = nil) -> String {
        let counts = swatchCounts(maximumOverlap: maximumOverlap)
        let high = counts.last ?? 1
        switch counts.count {
        case 1:
            return studioLocalized(
                "Heatmap legend. Low frequency: 1 run. Color shows how many distinct workouts crossed each cell.",
                locale: locale
            )
        case 2:
            return studioLocalized(
                "Heatmap legend. Low frequency: 1 run. High: up to \(high) runs. Color shows how many distinct workouts crossed each cell.",
                locale: locale
            )
        default:
            let middle = counts[1]
            return studioLocalized(
                "Heatmap legend. Low frequency: 1 run. Medium: \(middle) runs. High: up to \(high) runs. Color shows how many distinct workouts crossed each cell.",
                locale: locale
            )
        }
    }

    static func statisticsAccessibilityLabel(
        included: Int,
        distance: String,
        maximumOverlap: Int,
        cellSizeMeters: Int,
        locale: Locale? = nil
    ) -> String {
        studioLocalized(
            "Included \(included) runs, total distance \(distance), maximum overlap \(maximumOverlap) runs, cell size \(cellSizeMeters) meters",
            locale: locale
        )
    }
}
