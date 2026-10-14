import AppKit
import CoreGraphics
import CoreText
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform

/// The MP4 HUD draws text with CoreText. These pin the parts that only show
/// up in CJK: the language tag that picks the Simplified or Traditional
/// Chinese font, measured columns instead of widths sized for Latin glyphs,
/// and ellipsis truncation instead of a mid-glyph clip.
final class VideoHUDLocalizationTests: XCTestCase {
    private let simplified = Locale(identifier: "zh-Hans_CN")
    private let traditional = Locale(identifier: "zh-Hant_TW")
    private let english = Locale(identifier: "en_US")

    // MARK: - Font fallback

    func testLanguageTagCarriesTheScript() {
        XCTAssertEqual(VideoHUDText.languageTag(for: simplified), "zh-Hans-CN")
        XCTAssertEqual(VideoHUDText.languageTag(for: traditional), "zh-Hant-TW")
        XCTAssertEqual(VideoHUDText.languageTag(for: Locale(identifier: "zh_HK")), "zh-Hant-HK")
        XCTAssertEqual(VideoHUDText.languageTag(for: english), "en-Latn-US")
    }

    func testHanCharactersTakeTheLanguagesFont() {
        func fontNames(_ tag: String) -> [String] {
            let line = CTLineCreateWithAttributedString(VideoHUDText.attributed(
                "距离 骨",
                font: .systemFont(ofSize: 13),
                color: .black,
                language: tag
            ))
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            return runs.compactMap { run in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let value = attributes[kCTFontAttributeName] else { return nil }
                let font = value as! CTFont
                return CTFontCopyPostScriptName(font) as String
            }
        }
        let simplifiedFonts = fontNames("zh-Hans-CN")
        let traditionalFonts = fontNames("zh-Hant-TW")
        let hongKongFonts = fontNames("zh-Hant-HK")
        XCTAssertTrue(simplifiedFonts.contains { $0.contains("SC") }, "\(simplifiedFonts)")
        XCTAssertTrue(traditionalFonts.contains { $0.contains("TC") }, "\(traditionalFonts)")
        XCTAssertTrue(hongKongFonts.contains { $0.contains("HK") }, "\(hongKongFonts)")
    }

    // MARK: - Measurement

    func testFittedLineEndsWithinItsSlot() {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let title = "周末长距离慢跑：滨江绿道往返二十一公里拉练"
        let fullWidth = VideoHUDText.width(title, font: font, language: "zh-Hans-CN")
        XCTAssertGreaterThan(fullWidth, 200)

        let fitted = VideoHUDText.fittedLine(title, font: font, color: .black, language: "zh-Hans-CN", maxWidth: 200)
        XCTAssertLessThanOrEqual(CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil)), 200.5)
        XCTAssertLessThan(CTLineGetGlyphCount(fitted), title.count + 1)

        let short = VideoHUDText.fittedLine("距离", font: font, color: .black, language: "zh-Hans-CN", maxWidth: 200)
        XCTAssertEqual(CTLineGetGlyphCount(short), 2)
    }

    func testRowColumnsStartValuesAfterTheWidestLabel() {
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let longLabel = "Corrected elevation above sea level"
        let columns = VideoHUDText.rowColumns(
            labels: ["Elapsed", longLabel],
            values: ["1:02:03"],
            labelFont: labelFont,
            valueFont: valueFont,
            language: "en-Latn-US",
            inset: 14,
            gap: 16,
            minimumValueOffset: 140,
            minimumPanelWidth: 320,
            maximumPanelWidth: 900
        )
        let labelWidth = VideoHUDText.width(longLabel, font: labelFont, language: "en-Latn-US")
        XCTAssertGreaterThanOrEqual(columns.valueOffset, 14 + labelWidth + 16)
        XCTAssertGreaterThanOrEqual(
            columns.valueWidth,
            VideoHUDText.width("1:02:03", font: valueFont, language: "en-Latn-US")
        )

        // Short labels keep the original layout.
        let compact = VideoHUDText.rowColumns(
            labels: ["距离", "心率"],
            values: ["5.00公里"],
            labelFont: labelFont,
            valueFont: valueFont,
            language: "zh-Hans-CN",
            inset: 14,
            gap: 16,
            minimumValueOffset: 140,
            minimumPanelWidth: 320,
            maximumPanelWidth: 900
        )
        XCTAssertEqual(compact.valueOffset, 140)
        XCTAssertEqual(compact.panelWidth, 320)

        // A label may take at most half the panel.
        let clamped = VideoHUDText.rowColumns(
            labels: [String(repeating: "很长的标签", count: 20)],
            values: ["1"],
            labelFont: labelFont,
            valueFont: valueFont,
            language: "zh-Hans-CN",
            inset: 14,
            gap: 16,
            minimumValueOffset: 140,
            minimumPanelWidth: 320,
            maximumPanelWidth: 600
        )
        XCTAssertEqual(clamped.valueOffset, 300)
    }

    // MARK: - Localized HUD text

    func testMetricRowsAreTranslated() {
        for locale in [simplified, traditional] {
            let rows = WorkoutVideoFrameRenderer.metricRows(for: makeModel(locale: locale))
            for row in rows {
                XCTAssertNil(row.label.range(of: "[A-Za-z]", options: .regularExpression),
                             "untranslated HUD label \(row.label) in \(locale.identifier)")
            }
            let columns = WorkoutVideoFrameRenderer.metricColumns(
                for: rows,
                language: VideoHUDText.languageTag(for: locale),
                frameWidth: 1_280
            )
            for row in rows {
                XCTAssertLessThanOrEqual(
                    VideoHUDText.width(
                        row.label,
                        font: .systemFont(ofSize: 13, weight: .medium),
                        language: VideoHUDText.languageTag(for: locale)
                    ),
                    columns.valueOffset - columns.inset
                )
            }
        }
        let english = WorkoutVideoFrameRenderer.metricRows(for: makeModel(locale: english))
        XCTAssertEqual(english.first?.label, "Elapsed")
    }

    func testProgressCaptionIsOneTranslatedSentence() {
        XCTAssertEqual(makeModel(locale: english).progressCaption, "Progress 50%  ·  Source 00:50 / 01:40")
        let caption = makeModel(locale: simplified).progressCaption
        XCTAssertTrue(caption.contains("50%"), caption)
        XCTAssertFalse(caption.contains("Progress"), caption)
    }

    func testComparisonDeltaPhrasesTranslate() {
        let renderer = ComparisonVideoFrameRenderer()
        XCTAssertEqual(renderer.formatDelta(42, kind: .time, locale: english), "C ahead by 0:42")
        XCTAssertEqual(renderer.formatDelta(42, kind: .time, locale: simplified), "C 领先 0:42")
        XCTAssertEqual(renderer.formatDelta(-42, kind: .time, locale: traditional), "P 領先 0:42")
        XCTAssertEqual(renderer.formatDelta(19, kind: .pace, locale: simplified), "C 快 0:19 /公里")
        XCTAssertEqual(renderer.formatDelta(0, kind: .time, locale: simplified), "持平")
        XCTAssertEqual(renderer.formatDelta(nil, kind: .pace, locale: traditional), "不可用")
    }

    func testSimplifiedAndTraditionalFramesRenderDifferently() throws {
        let map = try blankMap(width: 640, height: 360)
        let renderer = WorkoutVideoFrameRenderer()
        func render(_ locale: Locale) throws -> Data {
            let image = try renderer.renderImage(
                frame: makeModel(locale: locale),
                staticMap: map,
                width: 640,
                height: 360,
                mapSize: CGSize(width: 640, height: 360)
            )
            let bitmap = NSBitmapImageRep(cgImage: image)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let hans = try render(simplified)
        let hant = try render(traditional)
        let latin = try render(english)
        XCTAssertNotEqual(hans, hant)
        XCTAssertNotEqual(hans, latin)
    }

    // MARK: - Helpers

    private func makeModel(locale: Locale) -> WorkoutVideoFrameModel {
        WorkoutVideoFrameModel(
            frameIndex: 5,
            frameCount: 10,
            sourceElapsedSeconds: 50,
            sourceTotalElapsedSeconds: 100,
            progress: 0.5,
            workoutTitle: "晨跑 · 合成测试路线",
            workoutDateText: "2026-10-15",
            markerPixel: CGPoint(x: 320, y: 180),
            elapsedSeconds: 50,
            activeSeconds: 45,
            movingSeconds: 40,
            stoppedSeconds: 5,
            distanceMeters: 500,
            activePaceSecondsPerKilometer: 300,
            heartRateBPM: 150,
            correctedElevationMeters: 42,
            movementState: .moving,
            isInRecordingGap: false,
            stateLabel: nil,
            appearance: .light,
            routeColorMode: .solid,
            locale: locale
        )
    }

    private func blankMap(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(CGColor(red: 0.85, green: 0.9, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
