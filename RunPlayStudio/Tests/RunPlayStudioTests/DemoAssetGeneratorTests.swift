#if DEBUG
import ImageIO
import RunPlayCore
import SwiftUI
import XCTest
@testable import RunPlayStudio

@MainActor
final class DemoAssetGeneratorTests: XCTestCase {
    // MARK: - Specification

    func testCatalogFixesTheDocumentedMedia() throws {
        XCTAssertEqual(DemoAssetCatalog.appearances, [.light, .dark])
        XCTAssertFalse(DemoAssetCatalog.summaryConfiguration(.dark).includeMap)

        let policy = DemoAssetCatalog.videoPolicy
        XCTAssertEqual([policy.width, policy.height, policy.framesPerSecond], [1_920, 1_080, 30])
        XCTAssertEqual(try policy.frameCount(for: DemoAssetCatalog.videoDuration), 450)
        XCTAssertEqual(DemoAssetCatalog.routeReplayConfiguration(.light).routeColorMode, .heartRate)
        XCTAssertEqual(DemoAssetCatalog.comparisonReplayConfiguration(.light).alignmentMode, .routeAware)

        XCTAssertEqual(
            DemoAssetCatalog.filename(DemoAssetCatalog.routeReplayPrefix, .dark, pathExtension: "mp4"),
            "demo-route-replay-dark.mp4"
        )
    }

    // MARK: - Environment pins

    func testPinnedEnvironmentHasNoProblems() throws {
        XCTAssertEqual(try pinnedEnvironment().problems, [])
    }

    func testEveryUnpinnedInputIsReported() throws {
        let environment = DemoAssetEnvironment(
            locale: Locale(identifier: "en_SG"),
            preferredLanguages: ["en-SG"],
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Singapore")),
            variables: [:]
        )
        let problems = environment.problems
        XCTAssertEqual(problems.count, 4, problems.joined(separator: "\n"))
        XCTAssertTrue(problems[0].contains("-AppleLocale en_US"))
        XCTAssertTrue(problems[1].contains("-AppleLanguages"))
        XCTAssertTrue(problems[2].contains("TZ=UTC"))
        XCTAssertTrue(problems[3].contains("SWIFT_DETERMINISTIC_HASHING"))
    }

    func testZoneThatOnlySometimesSitsAtUTCIsRejected() throws {
        // London is UTC+0 only in winter; whatever today's offset, it has
        // daylight-saving transitions, so no date line would be stable.
        let base = try pinnedEnvironment()
        let london = DemoAssetEnvironment(
            locale: base.locale,
            preferredLanguages: base.preferredLanguages,
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/London")),
            variables: base.variables
        )
        XCTAssertEqual(london.problems.count, 1)
    }

    // MARK: - Bundled data the media depend on

    func testBundledSampleRunsAreTheTwoSyntheticDemoWorkouts() throws {
        let runs = try DemoAssetSampleRuns.loadBundled()
        XCTAssertEqual(runs.primary.displayName, "Morning Park Run")
        XCTAssertEqual(runs.comparison.displayName, "Morning Park Progression Run")
        XCTAssertFalse(runs.primary.routePoints.isEmpty)
        XCTAssertFalse(runs.comparison.routePoints.isEmpty)
    }

    /// The route replay refuses a silent fallback to solid colouring, and only
    /// the manual workflow renders videos, so pin the precondition here.
    func testSampleRunSupportsTheRouteReplayColouring() throws {
        let workout = try DemoAssetSampleRuns.loadBundled().primary
        let probe = try RouteMetricProfileBuilder().probe(
            routePoints: workout.routePoints,
            context: WorkoutAnalysisContext(workout: workout)
        )
        XCTAssertTrue(
            probe.availability.isAvailable(DemoAssetCatalog.routeReplayConfiguration(.light).routeColorMode)
        )
    }

    /// Likewise, the comparison replay throws rather than degrading to Distance.
    func testSamplePairSupportsRouteAwareAlignment() throws {
        let runs = try DemoAssetSampleRuns.loadBundled()
        let resolution = try ComparisonVideoAlignmentResolver().resolve(
            pair: ComparisonPair(primary: runs.primary, comparison: runs.comparison),
            primaryContext: WorkoutAnalysisContext(workout: runs.primary),
            comparisonContext: WorkoutAnalysisContext(workout: runs.comparison),
            desiredMode: DemoAssetCatalog.comparisonReplayConfiguration(.light).alignmentMode,
            seed: nil,
            isCancelled: { false }
        )
        guard case .routeAware = resolution else {
            return XCTFail("Route-Aware alignment is unavailable for the bundled pair: \(resolution)")
        }
    }

    // MARK: - Summary cards

    func testSummaryCardsRenderBothAppearancesAtTheExportSize() async throws {
        let directory = try temporaryDirectory()
        let generator = DemoAssetGenerator(
            runs: try DemoAssetSampleRuns.loadBundled(),
            outputDirectory: directory,
            log: { _ in }
        )
        let written = try await generator.renderSummaryCards()

        XCTAssertEqual(written.map(\.lastPathComponent), ["demo-summary-light.png", "demo-summary-dark.png"])
        let images = try written.map { try DemoAssetImageComparator.loadImage(at: $0) }
        for image in images {
            XCTAssertEqual([image.width, image.height], [1_200, 1_600])
        }
        XCTAssertNotEqual(try Data(contentsOf: written[0]), try Data(contentsOf: written[1]))
    }

    /// On the real card, the drift gate must pass an unchanged render and fail
    /// one changed digit of one metric (max heart rate 166 → 167).
    func testSummaryCardToleranceSeparatesRepeatRendersFromOneChangedDigit() async throws {
        let original = try DemoAssetSampleRuns.loadBundled().primary
        let changed = try sampleRunRaisingMaxHeartRate()
        XCTAssertEqual(changed.summary.maxHeartRateBPM, (original.summary.maxHeartRateBPM ?? 0) + 1)

        let tolerance = DemoAssetPixelTolerance.summaryCard
        let reference = try await summaryCard(for: original)
        let repeated = try await DemoAssetImageComparator.compare(
            reference: reference,
            candidate: summaryCard(for: original),
            tolerance: tolerance
        )
        XCTAssertEqual(repeated.differingPixelCount, 0)
        XCTAssertTrue(repeated.isWithin(tolerance))

        let drifted = try await DemoAssetImageComparator.compare(
            reference: reference,
            candidate: summaryCard(for: changed),
            tolerance: tolerance
        )
        XCTAssertFalse(drifted.isWithin(tolerance), drifted.report(tolerance: tolerance))
    }

    /// The card's smallest data text is a 14-pt split time, so one changed
    /// digit there is the smallest change the gate must still catch.
    func testToleranceCatchesOneDigitOfTheSmallestCardText() throws {
        let tolerance = DemoAssetPixelTolerance.summaryCard
        for (before, after) in [("0:42", "0:43"), ("1:45", "1:46"), ("5:00", "5:06"), ("5:00", "5:01")] {
            let difference = try DemoAssetImageComparator.compare(
                reference: splitTime(before),
                candidate: splitTime(after),
                tolerance: tolerance
            )
            XCTAssertFalse(
                difference.isWithin(tolerance),
                "\(before) → \(after): \(difference.report(tolerance: tolerance))"
            )
        }
    }

    // MARK: - Helpers

    private func pinnedEnvironment() throws -> DemoAssetEnvironment {
        DemoAssetEnvironment(
            locale: Locale(identifier: "en_US"),
            preferredLanguages: ["en-US"],
            timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")),
            variables: ["SWIFT_DETERMINISTIC_HASHING": "1"]
        )
    }

    /// A split time drawn the way the metrics-only card draws its split rows.
    private func splitTime(_ text: String) throws -> CGImage {
        let palette = PNGSummaryExportPalette.light
        let view = Text(text)
            .font(.system(size: 14, design: .rounded).monospacedDigit())
            .foregroundStyle(palette.primaryText)
            .frame(width: 70, height: 24, alignment: .leading)
            .background(palette.pageBackground)
        let data = try PNGExportRenderer.renderPNG(
            from: view,
            pixelSize: CGSize(width: 70, height: 24),
            appearance: .light
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func summaryCard(for workout: RunWorkout) async throws -> CGImage {
        let result = try await PNGExportService.exportSummaryPNG(
            workout: workout,
            segments: workout.segments,
            configuration: DemoAssetCatalog.summaryConfiguration(.light)
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The bundled sample with its highest heart-rate sample one beat higher.
    private func sampleRunRaisingMaxHeartRate() throws -> RunWorkout {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // RunPlayStudioTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RunPlayStudio
            .appending(path: "Resources/sample_run.json")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var points = try XCTUnwrap(json["routePoints"] as? [[String: Any]])
        let index = try XCTUnwrap(
            points.indices.max { lhs, rhs in
                (points[lhs]["heartRateBPM"] as? Double ?? 0) < (points[rhs]["heartRateBPM"] as? Double ?? 0)
            }
        )
        points[index]["heartRateBPM"] = try XCTUnwrap(points[index]["heartRateBPM"] as? Double) + 1
        json["routePoints"] = points

        let changedURL = try temporaryDirectory().appending(path: "sample_run.json")
        try JSONSerialization.data(withJSONObject: json).write(to: changedURL)
        return try WorkoutImporterFactory.importWorkout(from: changedURL)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DemoAssetGeneratorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
#endif
