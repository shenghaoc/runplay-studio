import XCTest
@testable import RunPlayCore

/// Segment titles and subtitles are stored in English with the workout (and
/// written to the segments CSV); display text is rebuilt in the app's
/// language from the stored type, pace, and elevation change.
final class SegmentHighlightLocalizationTests: XCTestCase {
    private func highlight(
        _ type: SegmentType,
        title: String? = nil,
        subtitle: String = "stored",
        pace: Double? = nil,
        elevation: Double? = nil
    ) -> SegmentHighlight {
        SegmentHighlight(
            type: type,
            title: title ?? type.canonicalTitle,
            subtitle: subtitle,
            startDistanceMeters: 0,
            endDistanceMeters: 1_000,
            startElapsedSeconds: 0,
            endElapsedSeconds: 300,
            durationSeconds: 300,
            distanceMeters: 1_000,
            paceSecondsPerKilometer: pace,
            elevationDeltaMeters: elevation,
            sourcePointRange: 0..<2
        )
    }

    func testCanonicalTitlesAreTheStoredEnglishNames() {
        XCTAssertEqual(SegmentType.fastest400m.canonicalTitle, "Fastest 400m")
        XCTAssertEqual(SegmentType.fastest1km.canonicalTitle, "Fastest Kilometer")
        XCTAssertEqual(SegmentType.slowest1km.canonicalTitle, "Slowest Kilometer")
        XCTAssertEqual(SegmentType.biggestClimb.canonicalTitle, "Biggest Climb")
        XCTAssertEqual(SegmentType.biggestDescent.canonicalTitle, "Biggest Descent")
    }

    func testCustomSegmentsKeepTheirStoredText() {
        let custom = highlight(.custom, title: "Hill repeats", subtitle: "x4")
        XCTAssertEqual(custom.displayTitle(), "Hill repeats")
        XCTAssertEqual(custom.displaySubtitle(), "x4")
    }

    func testDetectedSegmentsFallBackToStoredSubtitleWithoutNumbers() {
        XCTAssertEqual(highlight(.fastest1km, subtitle: "4:00 /km").displaySubtitle(), "4:00 /km")
        XCTAssertEqual(highlight(.biggestClimb, subtitle: "12 m ↑").displaySubtitle(), "12 m ↑")
    }

    #if canImport(Darwin)
    func testEnglishDisplayMatchesStoredText() {
        let english = Locale(identifier: "en_US")
        let fastest = highlight(.fastest1km, pace: 240)
        XCTAssertEqual(fastest.displayTitle(locale: english), "Fastest Kilometer")
        XCTAssertEqual(fastest.displaySubtitle(locale: english), "4:00 /km")

        let climb = highlight(.biggestClimb, elevation: 42.4)
        XCTAssertEqual(climb.displaySubtitle(locale: english), "42 m ↑")
        let descent = highlight(.biggestDescent, elevation: -18)
        XCTAssertEqual(descent.displaySubtitle(locale: english), "18 m ↓")
    }

    func testChineseDisplayIsRebuiltFromStoredNumbers() {
        let simplified = Locale(identifier: "zh-Hans_CN")
        let traditional = Locale(identifier: "zh-Hant_TW")
        let fastest = highlight(.fastest1km, pace: 240)
        XCTAssertEqual(fastest.displayTitle(locale: simplified), "最快 1 公里")
        XCTAssertEqual(fastest.displayTitle(locale: traditional), "最快 1 公里")
        XCTAssertEqual(fastest.displaySubtitle(locale: simplified), "4:00 /公里")
        XCTAssertEqual(highlight(.biggestClimb).displayTitle(locale: simplified), "最大爬升")
        XCTAssertEqual(highlight(.biggestClimb).displayTitle(locale: traditional), "最大爬升")
        let climb = highlight(.biggestClimb, elevation: 42)
        XCTAssertTrue(climb.displaySubtitle(locale: simplified).hasSuffix("米 ↑"))
        XCTAssertTrue(climb.displaySubtitle(locale: traditional).hasSuffix("公尺 ↑"))
    }
    #endif
}
