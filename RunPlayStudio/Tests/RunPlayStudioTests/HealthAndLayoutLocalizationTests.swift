import AppKit
import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// The Apple Health sheets, the route-less run text, the File-menu command and
/// the elevation axis once shipped in English in a Chinese app, and four layouts
/// clipped Chinese text that fitted in English. These pin both.
///
/// `@MainActor` because the layout helpers under test are statics on SwiftUI
/// `View`s, which are main-actor isolated. Swift 6.4 infers the isolation for
/// those calls and compiles without it; Swift 6.3.3 does not, and rejects them
/// as actor-isolated calls from a nonisolated context. Matching the other
/// main-actor suites here keeps it correct on both.
@MainActor
final class HealthAndLayoutLocalizationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let simplified = Locale(identifier: "zh-Hans_CN")
    private let traditional = Locale(identifier: "zh-Hant_TW")

    // MARK: - Health sentences

    /// A count in a Health report sentence picks its English plural form and
    /// reads as one Chinese sentence.
    func testReportSentencesPickTheirPluralFormAndTranslate() {
        XCTAssertEqual(
            studioLocalized("\(1) runs were already in your library.", locale: english),
            "1 run was already in your library."
        )
        XCTAssertEqual(
            studioLocalized("\(2) runs were already in your library.", locale: english),
            "2 runs were already in your library."
        )
        XCTAssertEqual(
            studioLocalized("\(2) runs were already in your library.", locale: simplified),
            "2 次跑步已在你的资料库中。"
        )
        XCTAssertEqual(
            studioLocalized("\(2) runs were already in your library.", locale: traditional),
            "2 次跑步已在你的資料庫中。"
        )
        XCTAssertEqual(studioLocalized("Import \(1) Workouts", locale: english), "Import 1 Workout")
        XCTAssertEqual(studioLocalized("Import \(4) Workouts", locale: simplified), "导入 4 项运动")
        XCTAssertEqual(
            studioLocalized("\(1) readings over \("3 minutes").", locale: english),
            "1 reading over 3 minutes."
        )
        XCTAssertEqual(
            studioLocalized("\(4) readings over \("3 minutes").", locale: traditional),
            "4 個讀數，時長 3 minutes。"
        )
    }

    /// Health report titles, chips, row labels and the route-less notices all
    /// resolve in both scripts, not just the keys the catalog check can see.
    func testHealthAndRouteLessTextIsTranslated() {
        let expected: [(String.LocalizationValue, String, String)] = [
            ("Workouts", "运动", "運動"),
            ("With a route", "含路线", "含路線"),
            ("Running", "跑步", "跑步"),
            ("Import cancelled", "导入已取消", "匯入已取消"),
            ("Import Apple Health Export…", "导入 Apple 健康导出文件…", "匯入 Apple 健康匯出檔案…"),
            ("No GPS route", "无 GPS 路线", "無 GPS 路線"),
        ]
        for (key, hans, hant) in expected {
            XCTAssertEqual(studioLocalized(key, locale: simplified), hans)
            XCTAssertEqual(studioLocalized(key, locale: traditional), hant)
        }
    }

    /// Durations and distances go through formatters, so a Chinese reader does
    /// not see "20m 0s" or "5.00 km".
    func testHealthDurationAndDistanceUseTheLocalesFormatters() {
        let window = AppleHealthWorkoutWindow(
            startSeconds: 0, endSeconds: 1_200, activityType: "HKWorkoutActivityTypeRunning", utcOffsetSeconds: 0
        )
        XCTAssertEqual(AppleHealthReviewPresentation.durationText(window, locale: english), "20m 0s")
        for locale in [simplified, traditional] {
            let text = AppleHealthReviewPresentation.durationText(window, locale: locale)
            XCTAssertTrue(text.contains("分"), "\(locale.identifier): \(text)")
            XCTAssertNil(text.range(of: "[A-Za-z]", options: .regularExpression), "\(locale.identifier): \(text)")
        }
        let long = AppleHealthWorkoutWindow(
            startSeconds: 0, endSeconds: 3_900, activityType: "HKWorkoutActivityTypeRunning", utcOffsetSeconds: 0
        )
        XCTAssertEqual(AppleHealthReviewPresentation.durationText(long, locale: english), "1h 5m")
        XCTAssertTrue(AppleHealthReviewPresentation.durationText(long, locale: simplified).contains("小时"))
    }

    /// The elevation axis writes metres through the measurement formatter.
    func testElevationAxisUnitFollowsTheLanguage() {
        XCTAssertEqual(DisplayFormatter.formatMeters(50, locale: english), "50 m")
        XCTAssertEqual(DisplayFormatter.formatMeters(50, locale: simplified), "50米")
        XCTAssertEqual(DisplayFormatter.formatMeters(50, locale: traditional), "50公尺")
    }

    // MARK: - Layouts that size to content

    /// At the default 1200 pt window the Splits table has 896 pt (measured from
    /// the table's frame), and a column sized for English clipped the last one.
    /// Sized to the headers and values of each language, the table fits.
    func testSplitsTableFitsTheDefaultWindowInEveryLanguage() {
        let splits = (1...8).map { index in
            RunSplit(
                splitIndex: index,
                distanceMeters: 1_000,
                elapsedSeconds: 305,
                paceSecondsPerKilometer: 305,
                averageHeartRateBPM: 152,
                averagePowerWatts: 250,
                elevationGainMeters: 23.4,
                startDistanceMeters: Double(index - 1) * 1_000,
                endDistanceMeters: Double(index) * 1_000
            )
        }
        let columns = SplitTableColumn.visibleColumns(showsPower: false)
        for locale in [english, simplified, traditional] {
            let widths = SplitTableColumnWidths.measure(splits: splits, columns: columns, locale: locale)
            XCTAssertLessThanOrEqual(
                widths.tableWidth(columns: columns), 896,
                "\(locale.identifier): the Splits table needs \(widths.tableWidth(columns: columns)) pt"
            )
            for column in columns {
                let header = TextMeasure.width(
                    of: SplitTableColumnWidths.title(of: column, locale: locale),
                    font: SplitTableColumnWidths.headerFont
                )
                XCTAssertGreaterThanOrEqual(widths.width(column), header + SplitTableColumnWidths.headerPadding, "\(locale.identifier) \(column)")
            }
        }
    }

    /// Each column is as wide as what it shows, so a longer header or value
    /// widens its column instead of being cut.
    func testSplitColumnsGrowWithTheirContent() {
        let short = RunSplit(
            splitIndex: 1, distanceMeters: 1_000, elapsedSeconds: 300, paceSecondsPerKilometer: 300,
            startDistanceMeters: 0, endDistanceMeters: 1_000
        )
        let long = RunSplit(
            splitIndex: 1, distanceMeters: 1_000, elapsedSeconds: 36_000, paceSecondsPerKilometer: 300,
            startDistanceMeters: 0, endDistanceMeters: 1_000
        )
        let columns = [SplitTableColumn.elapsed]
        let narrow = SplitTableColumnWidths.measure(splits: [short], columns: columns, locale: english)
        let wide = SplitTableColumnWidths.measure(splits: [long], columns: columns, locale: english)
        XCTAssertGreaterThanOrEqual(wide.width(.elapsed), narrow.width(.elapsed))
    }

    /// The Compare split tables sit in a column beside the map that was fixed at
    /// 380 pt (a 356 pt table, measured from its frame). A delta such as
    /// "-0:38 /km faster" or "-0:38 /公里 快" is wider than that allows, so the
    /// column widens to the measured tables, and stays a modest share of the pane.
    func testCompareSplitTablesFitTheirPaneInEveryLanguage() {
        for locale in [english, simplified, traditional] {
            let delta = DisplayFormatter.formatSignedDurationDelta(
                -37.5, suffix: DisplayFormatter.perKilometerSuffix(locale: locale), locale: locale
            )
            let widths = SplitComparisonTableView.columnWidths(
                indexCells: ["1", "5", "12"],
                selectedCells: ["4:26", "12:40"],
                comparisonCells: ["4:26", "12:40"],
                deltaCells: [delta, "0:00 /km"],
                locale: locale
            )
            XCTAssertLessThanOrEqual(
                widths.tableWidth, 440,
                "\(locale.identifier): the Compare split table needs \(widths.tableWidth) pt for \"\(delta)\""
            )
            XCTAssertGreaterThanOrEqual(
                widths.delta,
                TextMeasure.width(of: delta, font: SplitTableColumnWidths.cellFont) + 20,
                "\(locale.identifier): the delta column is narrower than \"\(delta)\""
            )
            let header = TextMeasure.width(
                of: ComparisonChartView.selectedRunColumnTitle(locale: locale),
                font: SplitTableColumnWidths.headerFont
            )
            XCTAssertGreaterThanOrEqual(widths.selected, header + SplitTableColumnWidths.headerPadding)
        }
    }

    /// The All Runs Date column fits the longest date each language writes, so
    /// "2026年6月25日 下午3:49" is not cut to "2026年6月25日 1…".
    func testAllRunsDateColumnFitsTheLongestDateInEveryLanguage() throws {
        let calendar = Calendar.current
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for locale in [english, simplified, traditional] {
            let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            let width = WorkoutLibraryView.dateColumnWidth(locale: locale)
            for (month, day, hour) in [(12, 28, 22), (6, 25, 15), (9, 30, 10)] {
                let date = try XCTUnwrap(calendar.date(from: DateComponents(
                    year: 2026, month: month, day: day, hour: hour, minute: 49
                )))
                let text = date.formatted(style)
                XCTAssertGreaterThanOrEqual(
                    width, TextMeasure.width(of: text, font: font),
                    "\(locale.identifier): the Date column is \(width) pt for \"\(text)\""
                )
            }
        }
    }
}
