import AppKit
import CoreGraphics
import ImageIO
import RunPlayCore
import SwiftUI
import XCTest
@testable import RunPlayStudio

/// The PNG summary card in English, Simplified Chinese, and Traditional
/// Chinese, rendered from one synthetic run.
///
/// Snapshots catch what only pixels show — missing CJK glyphs, a card in the
/// wrong language or script, labels truncated by widths sized for Latin text.
/// The structural tests pin the same properties without images, and the
/// typesetting test checks the one thing snapshots are too coarse for: that
/// Traditional text is drawn with Traditional glyph shapes.
@MainActor
final class ExportSummaryCardLocalizationTests: XCTestCase {
    private static let locales: [(name: String, locale: Locale)] = [
        ("en", Locale(identifier: "en_US")),
        ("zh-Hans", Locale(identifier: "zh-Hans_CN")),
        ("zh-Hant", Locale(identifier: "zh-Hant_TW")),
    ]
    /// Fixed zone so the card's date line is identical on every machine.
    private static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    // MARK: - Snapshots

    func testMetricsOnlyCardSnapshots() throws {
        let workout = Self.syntheticRun()
        for (name, locale) in Self.locales {
            let image = try render(workout: workout, locale: locale, includeMap: false)
            try SnapshotAssertion.assertMatches(image, group: "ExportSummaryCard", named: "metrics-\(name)")
        }
    }

    func testMapCardSnapshots() throws {
        let workout = Self.syntheticRun()
        for (name, locale) in Self.locales {
            let image = try render(workout: workout, locale: locale, includeMap: true)
            try SnapshotAssertion.assertMatches(image, group: "ExportSummaryCard", named: "map-\(name)")
        }
    }

    // MARK: - Structure

    func testChineseCardsCarryNoUntranslatedWords() {
        let workout = Self.syntheticRun()
        // Words allowed to stay Latin: the app and map brands (Apple 地图),
        // and the workout's own name and source format.
        let allowed = ["RunPlay Studio", "Apple", "Synthetic Riverside 5K", "GPX"]
        for (name, locale) in Self.locales where name != "en" {
            let model = Self.model(for: workout, locale: locale, includeMap: true)
            let presentation = Self.presentation(model: model, locale: locale, includeMap: true)
            let card = ExportSummaryCardView(presentation: presentation)
            var texts = [
                model.dateText, model.distanceText, model.activePaceText, model.movingPaceText,
                model.elapsedPaceText, model.elevationGainText, model.elevationLossText,
                model.pointCountText, model.privacyNote,
            ]
            texts += [model.heartRateText, model.maxHeartRateText, model.recordedLapCountText]
                .compactMap { $0 }
            texts += [model.segmentsTruncationText, model.splitsTruncationText].compactMap { $0 }
            texts += model.segments.flatMap { [$0.title, $0.value] }
            texts += model.splits.map(\.distance)
            texts += card.labels.all
            texts.append(card.labels.legendTitle(modeName: WorkoutRouteColorMode.pace.localizedName(locale: locale)))
            if let legend = presentation.routeLegend {
                texts += [
                    legend.lowerEndLabel(locale: locale),
                    legend.upperEndLabel(locale: locale),
                    legend.directionSummary(locale: locale),
                ]
            }
            for text in texts {
                var stripped = text
                for word in allowed {
                    stripped = stripped.replacingOccurrences(of: word, with: "")
                }
                XCTAssertNil(
                    stripped.range(of: "[A-Za-z]{2,}", options: .regularExpression),
                    "untranslated text on the \(name) card: \(text)"
                )
            }
        }
    }

    func testCardDateFollowsTheLocalesClock() {
        let workout = Self.syntheticRun()
        let simplified = Self.model(for: workout, locale: Locale(identifier: "zh-Hans_CN"), includeMap: false)
        let english = Self.model(for: workout, locale: Locale(identifier: "en_US"), includeMap: false)
        // 07:30 in Shanghai: 24-hour in mainland China, AM/PM in the US.
        XCTAssertTrue(simplified.dateText.contains("07:30"), simplified.dateText)
        XCTAssertFalse(simplified.dateText.contains("上午"), simplified.dateText)
        XCTAssertTrue(english.dateText.contains("7:30"), english.dateText)
        XCTAssertTrue(english.dateText.contains("AM"), english.dateText)
        XCTAssertTrue(simplified.dateText.contains("2026年3月14日"), simplified.dateText)
    }

    func testTraditionalCardIsTypesetInTraditionalChinese() throws {
        let workout = Self.syntheticRun()
        let simplified = Self.presentation(
            model: Self.model(for: workout, locale: Locale(identifier: "zh-Hans_CN"), includeMap: false),
            locale: Locale(identifier: "zh-Hans_CN"),
            includeMap: false
        )
        let traditional = Self.presentation(
            model: Self.model(for: workout, locale: Locale(identifier: "zh-Hant_TW"), includeMap: false),
            locale: Locale(identifier: "zh-Hant_TW"),
            includeMap: false
        )
        XCTAssertEqual(simplified.typesettingLanguage.script?.identifier, "Hans")
        XCTAssertEqual(traditional.typesettingLanguage.script?.identifier, "Hant")
        XCTAssertNotEqual(
            try render(workout: workout, locale: Locale(identifier: "zh-Hans_CN"), includeMap: false).dataProvider?.data,
            try render(workout: workout, locale: Locale(identifier: "zh-Hant_TW"), includeMap: false).dataProvider?.data
        )
    }

    /// The card pins its own typesetting language, so the language around it
    /// (the app's, or a caller's modifier) cannot swap in the other script's
    /// glyph shapes. Same text, same machine: the two renders must be
    /// byte-identical, which a tolerance-based snapshot cannot check.
    func testCardTypesettingIgnoresTheSurroundingLanguage() throws {
        let workout = Self.syntheticRun()
        let simplified = Locale.Language(identifier: "zh-Hans")
        let traditional = Locale.Language(identifier: "zh-Hant")
        for (name, locale) in Self.locales where name != "en" {
            let model = Self.model(for: workout, locale: locale, includeMap: false)
            let card = ExportSummaryCardView(
                presentation: Self.presentation(model: model, locale: locale, includeMap: false)
            )
            // Not vacuous: the card's own text has glyphs whose Simplified and
            // Traditional shapes differ, so an unpinned card would change. The
            // renderer is opaque, so the probe brings its own background.
            let probe = Text(card.labels.all.joined(separator: " ") + model.dateText)
                .font(.system(size: 32))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)
            XCTAssertNotEqual(
                try PNGExportRenderer.renderPNG(from: probe.typesettingLanguage(simplified)),
                try PNGExportRenderer.renderPNG(from: probe.typesettingLanguage(traditional)),
                "\(name): no glyph on the card differs between the two scripts"
            )
            XCTAssertEqual(
                try PNGExportRenderer.renderPNG(from: card.typesettingLanguage(simplified)),
                try PNGExportRenderer.renderPNG(from: card.typesettingLanguage(traditional)),
                "\(name) card follows the surrounding typesetting language"
            )
        }
    }

    // MARK: - Fixtures

    private func render(workout: RunWorkout, locale: Locale, includeMap: Bool) throws -> CGImage {
        let model = Self.model(for: workout, locale: locale, includeMap: includeMap)
        let presentation = Self.presentation(model: model, locale: locale, includeMap: includeMap)
        let data = try PNGExportRenderer.renderPNG(
            from: ExportSummaryCardView(presentation: presentation),
            appearance: .light
        )
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw NSError(domain: "ExportSummaryCardLocalizationTests", code: 1)
        }
        return image
    }

    private static func model(for workout: RunWorkout, locale: Locale, includeMap: Bool) -> ExportSummaryCardModel {
        ExportSummaryCardModel(
            workout: workout,
            segments: workout.segments,
            layout: includeMap ? .mapInclusive : .metricsOnly,
            includesMapImagery: includeMap,
            locale: locale,
            timeZone: timeZone
        )
    }

    private static func presentation(
        model: ExportSummaryCardModel,
        locale: Locale,
        includeMap: Bool
    ) -> ExportSummaryCardPresentation {
        ExportSummaryCardPresentation(
            model: model,
            mapImage: includeMap ? syntheticMapImage() : nil,
            routeLegend: includeMap
                ? RouteMetricLegendModel(
                    mode: .pace,
                    scale: RouteMetricScale(
                        lowerBound: 270,
                        median: 300,
                        upperBound: 330,
                        lowerLabel: "4:30",
                        medianLabel: "5:00",
                        upperLabel: "5:30",
                        direction: .lowerIsBetter
                    ),
                    showsNoData: true,
                    coverageFraction: 0.98
                )
                : nil,
            appearance: .light,
            layout: includeMap ? .mapInclusive : .metricsOnly,
            locale: locale
        )
    }

    /// A flat two-tone stand-in for the Apple Maps snapshot: the card layout
    /// is under test, not MapKit.
    private static func syntheticMapImage() -> NSImage {
        let size = NSSize(width: PNGExportService.mapImageSize.width, height: PNGExportService.mapImageSize.height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.86, green: 0.91, blue: 0.86, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(srgbRed: 0.16, green: 0.45, blue: 0.86, alpha: 1).setStroke()
        let path = NSBezierPath(ovalIn: NSRect(x: 360, y: 120, width: 400, height: 320))
        path.lineWidth = 6
        path.stroke()
        image.unlockFocus()
        return image
    }

    /// A deterministic 5.4 km run: pace, altitude, and heart rate vary on
    /// fixed sine waves so splits, segment highlights, and HR all appear.
    static func syntheticRun() -> RunWorkout {
        // 2026-03-14 07:30 in Shanghai.
        let start = Date(timeIntervalSince1970: 1_773_444_600)
        var points: [RoutePoint] = []
        var distance = 0.0
        var elapsed = 0.0
        let step = 5.0
        for index in 0..<330 {
            let time = Double(index)
            let pace = 300 + 30 * sin(time / 35)
            if index > 0 {
                distance += 1_000 / pace * step
                elapsed += step
            }
            let angle = distance / 5_400 * 2 * .pi
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 47.0 + 0.0075 * sin(angle),
                longitude: 8.0 + 0.011 * (1 - cos(angle)),
                altitudeMeters: 400 + 30 * sin(angle * 2),
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                heartRateBPM: 142 + 12 * sin(time / 50) + time / 40
            ))
        }
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Synthetic Riverside 5K", activityType: "running", startDate: start),
            source: .gpx,
            routePoints: points,
            summary: RunSummary()
        )
        WorkoutAnalyzer().analyze(&workout)
        return workout
    }
}
