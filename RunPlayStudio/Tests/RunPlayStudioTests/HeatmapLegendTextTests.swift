import XCTest
@testable import RunPlayStudio

/// Plural forms and distinct swatches in the Personal Heatmap legend and
/// statistics sentences (#205).
final class HeatmapLegendTextTests: XCTestCase {

    private let english = Locale(identifier: "en")
    private let simplified = Locale(identifier: "zh-Hans")
    private let traditional = Locale(identifier: "zh-Hant")

    // MARK: - Distinct swatches

    func testLegendShowsOnlyDistinctCounts() {
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 0), [1])
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 1), [1])
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 2), [1, 2])
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 3), [1, 3])
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 4), [1, 2, 4])
        XCTAssertEqual(HeatmapLegendText.swatchCounts(maximumOverlap: 9), [1, 4, 9])
    }

    // MARK: - Legend sentence

    func testLegendSentenceWithOneDistinctCount() {
        XCTAssertEqual(
            HeatmapLegendText.legendAccessibilityLabel(maximumOverlap: 1, locale: english),
            "Heatmap legend. Low frequency: 1 run. Color shows how many distinct workouts crossed each cell."
        )
    }

    func testLegendSentenceWithTwoDistinctCounts() {
        XCTAssertEqual(
            HeatmapLegendText.legendAccessibilityLabel(maximumOverlap: 2, locale: english),
            "Heatmap legend. Low frequency: 1 run. High: up to 2 runs. Color shows how many distinct workouts crossed each cell."
        )
    }

    func testLegendSentenceWithThreeDistinctCounts() {
        XCTAssertEqual(
            HeatmapLegendText.legendAccessibilityLabel(maximumOverlap: 9, locale: english),
            "Heatmap legend. Low frequency: 1 run. Medium: 4 runs. High: up to 9 runs. Color shows how many distinct workouts crossed each cell."
        )
    }

    func testLegendSentenceInChinese() {
        XCTAssertEqual(
            HeatmapLegendText.legendAccessibilityLabel(maximumOverlap: 9, locale: simplified),
            "热力图图例。低频率：1 次跑步。中频率：4 次跑步。高频率：最多 9 次跑步。颜色表示经过每个网格的不同运动数量。"
        )
        XCTAssertEqual(
            HeatmapLegendText.legendAccessibilityLabel(maximumOverlap: 9, locale: traditional),
            "熱力圖圖例。低頻率：1 次跑步。中頻率：4 次跑步。高頻率：最多 9 次跑步。顏色表示經過每個網格的不同運動數量。"
        )
    }

    // MARK: - Statistics sentence

    func testStatisticsSentenceGivesEachCountItsOwnPlural() {
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 1, distance: "5.0 km", maximumOverlap: 1, cellSizeMeters: 100, locale: english
            ),
            "Included 1 run, total distance 5.0 km, maximum overlap 1 run, cell size 100 meters"
        )
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 1, distance: "5.0 km", maximumOverlap: 3, cellSizeMeters: 100, locale: english
            ),
            "Included 1 run, total distance 5.0 km, maximum overlap 3 runs, cell size 100 meters"
        )
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 12, distance: "80.0 km", maximumOverlap: 1, cellSizeMeters: 250, locale: english
            ),
            "Included 12 runs, total distance 80.0 km, maximum overlap 1 run, cell size 250 meters"
        )
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 12, distance: "80.0 km", maximumOverlap: 7, cellSizeMeters: 250, locale: english
            ),
            "Included 12 runs, total distance 80.0 km, maximum overlap 7 runs, cell size 250 meters"
        )
    }

    func testStatisticsSentenceInChinese() {
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 1, distance: "5.0 km", maximumOverlap: 1, cellSizeMeters: 100, locale: simplified
            ),
            "已纳入 1 次跑步，总距离 5.0 km，最大重叠 1 次跑步，网格大小 100 米"
        )
        XCTAssertEqual(
            HeatmapLegendText.statisticsAccessibilityLabel(
                included: 12, distance: "80.0 km", maximumOverlap: 7, cellSizeMeters: 250, locale: traditional
            ),
            "已納入 12 次跑步，總距離 80.0 km，最大重疊 7 次跑步，網格大小 250 公尺"
        )
    }
}
