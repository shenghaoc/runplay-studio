import XCTest
@testable import RunPlayCore

#if canImport(Darwin)
/// `DisplayFormatter` takes numbers, separators, and unit symbols from
/// Foundation for the requested locale, and the units Foundation lacks from
/// Core's String Catalog.
///
/// Chinese and German expectations assert the locale's conventions (unit
/// words, decimal separators) rather than whole CLDR strings, whose spacing
/// may change between OS releases.
final class LocalizedDisplayFormatterTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let simplified = Locale(identifier: "zh-Hans_CN")
    private let traditional = Locale(identifier: "zh-Hant_TW")
    private let german = Locale(identifier: "de_DE")

    func testEnglishOutputMatchesTheFixedFormats() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(5_432, locale: english), "5.43 km")
        XCTAssertEqual(DisplayFormatter.formatDistance(500, locale: english), "500 m")
        XCTAssertEqual(DisplayFormatter.formatDistance(1_500, locale: english), "1.5 km")
        XCTAssertEqual(DisplayFormatter.formatElevation(12, locale: english), "12 m")
        XCTAssertEqual(DisplayFormatter.formatElevationDelta(50, locale: english), "+50 m")
        XCTAssertEqual(DisplayFormatter.formatElevationDelta(-30, locale: english), "-30 m")
        XCTAssertEqual(DisplayFormatter.formatPace(300, locale: english), "5:00 /km")
        XCTAssertEqual(DisplayFormatter.formatPace(nil, locale: english), "--:-- /km")
        XCTAssertEqual(DisplayFormatter.formatHeartRate(145.7, locale: english), "146 bpm")
        XCTAssertEqual(DisplayFormatter.formatCadence(178, locale: english), "178 spm")
        XCTAssertEqual(DisplayFormatter.formatPower(250, locale: english), "250 W")
        XCTAssertEqual(DisplayFormatter.formatSpeedKmh(3, locale: english), "10.8 km/h")
        XCTAssertEqual(DisplayFormatter.formatSpeed(1.25, locale: english), "1.2 m/s")
        XCTAssertEqual(DisplayFormatter.formatGroundContactTime(220, locale: english), "220 ms")
        XCTAssertEqual(DisplayFormatter.formatVerticalOscillation(8.5, locale: english), "8.5 mm")
        XCTAssertEqual(DisplayFormatter.formatStepLength(1.2, locale: english), "1.20 m")
        XCTAssertEqual(DisplayFormatter.formatVerticalRatio(7.5, locale: english), "7.5%")
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(nil, locale: english), "--- km")
        XCTAssertEqual(DisplayFormatter.formatElevation(nil, locale: english), "--- m")
        XCTAssertEqual(DisplayFormatter.formatHeartRate(nil, locale: english), "--- bpm")
    }

    func testEnglishGroupsLargeValues() {
        XCTAssertEqual(DisplayFormatter.formatElevation(1_234, locale: english), "1,234 m")
    }

    func testSimplifiedChineseUsesChineseUnitWords() {
        let distance = DisplayFormatter.formatDistanceKm(5_432, locale: simplified)
        XCTAssertTrue(distance.hasPrefix("5.43"), distance)
        XCTAssertTrue(distance.contains("公里"), distance)
        XCTAssertFalse(distance.contains("km"), distance)

        let elevation = DisplayFormatter.formatElevation(12, locale: simplified)
        XCTAssertTrue(elevation.contains("米"), elevation)

        let pace = DisplayFormatter.formatPace(330, locale: simplified)
        XCTAssertTrue(pace.hasPrefix("5:30 /"), pace)
        XCTAssertTrue(pace.hasSuffix("公里"), pace)

        let missing = DisplayFormatter.formatDistanceKm(nil, locale: simplified)
        XCTAssertTrue(missing.contains("---"), missing)
        XCTAssertTrue(missing.contains("公里"), missing)
    }

    func testTraditionalChineseTaiwanUsesItsOwnLengthUnits() {
        // Taiwan writes metres as 公尺 and millimetres as 公釐.
        XCTAssertTrue(DisplayFormatter.formatElevation(12, locale: traditional).contains("公尺"))
        XCTAssertTrue(DisplayFormatter.formatVerticalOscillation(8.5, locale: traditional).contains("公釐"))
        XCTAssertTrue(DisplayFormatter.formatDistanceKm(5_000, locale: traditional).contains("公里"))
    }

    func testCatalogUnitsResolveInChinese() {
        XCTAssertEqual(DisplayFormatter.formatHeartRate(146, locale: simplified), "146 次/分")
        XCTAssertEqual(DisplayFormatter.formatCadence(178, locale: simplified), "178 步/分")
        XCTAssertEqual(DisplayFormatter.formatHeartRate(146, locale: traditional), "146 次/分")
        XCTAssertEqual(DisplayFormatter.formatCadence(178, locale: traditional), "178 步/分")
        XCTAssertEqual(DisplayFormatter.formatHeartRate(nil, locale: simplified), "--- 次/分")
    }

    func testGermanUsesDecimalComma() {
        XCTAssertEqual(DisplayFormatter.formatDistanceKm(5_432, locale: german), "5,43 km")
        XCTAssertTrue(DisplayFormatter.formatSpeedKmh(3, locale: german).hasPrefix("10,8"))
    }

    func testClockValuesStayLocaleNeutral() {
        // Durations and M:SS paces read the same in every locale.
        XCTAssertEqual(DisplayFormatter.formatDuration(3_725), "1:02:05")
        XCTAssertEqual(DisplayFormatter.formatPaceShort(330), "5:30")
        XCTAssertTrue(DisplayFormatter.formatPace(330, locale: german).hasPrefix("5:30 /"))
    }

    func testSignedDeltaWordsAreLocalized() {
        XCTAssertEqual(DisplayFormatter.formatSignedDurationDelta(12, locale: english), "+0:12 slower")
        XCTAssertEqual(DisplayFormatter.formatSignedDurationDelta(-12, locale: english), "-0:12 faster")
        XCTAssertEqual(DisplayFormatter.formatSignedDurationDelta(nil, locale: english), "N/A")
        XCTAssertEqual(
            DisplayFormatter.formatSignedDurationDelta(
                0.2,
                suffix: DisplayFormatter.perKilometerSuffix(locale: english),
                locale: english
            ),
            "0:00 /km even"
        )
        XCTAssertEqual(DisplayFormatter.formatSignedDurationDelta(12, locale: simplified), "+0:12 较慢")
        XCTAssertEqual(DisplayFormatter.formatSignedDurationDelta(-12, locale: traditional), "-0:12 較快")
    }

    func testPerKilometerSuffixFollowsTheLocale() {
        XCTAssertEqual(DisplayFormatter.perKilometerSuffix(locale: english), "/km")
        XCTAssertEqual(DisplayFormatter.perKilometerSuffix(locale: simplified), "/公里")
    }
}
#endif
