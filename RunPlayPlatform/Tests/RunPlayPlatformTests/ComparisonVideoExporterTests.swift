import CoreGraphics
import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class ComparisonVideoExporterTests: XCTestCase {
    func testDistanceExportProducesValidMP4() async throws {
        let primary = makeWorkout(distanceMeters: 800, pace: 300)
        let comparison = makeWorkout(distanceMeters: 800, pace: 330, latOffset: 0.0001)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let primaryContext = WorkoutAnalysisContext(workout: primary)
        let comparisonContext = WorkoutAnalysisContext(workout: comparison)

        let exporter = ComparisonVideoExporter(
            mapPreparer: SyntheticComparisonVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("comparison-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try await exporter.export(
            pair: pair,
            configuration: ComparisonVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .light,
                alignmentMode: .distance
            ),
            destinationURL: destination,
            policy: .unitTest,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )

        XCTAssertEqual(result.frameCount, 150)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.framesPerSecond, 10)
        XCTAssertEqual(result.alignmentMode, .distance)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(result.fileSizeBytes, 0)
        XCTAssertEqual(result.outputDurationSeconds, 15, accuracy: 0.05)
    }

    func testPosterRendersMidpoint() async throws {
        let primary = makeWorkout(distanceMeters: 600, pace: 300)
        let comparison = makeWorkout(distanceMeters: 600, pace: 300, latOffset: 0.0001)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let exporter = ComparisonVideoExporter(
            mapPreparer: SyntheticComparisonVideoMapPreparer()
        )
        let map = try await exporter.prepareMap(
            pair: pair,
            configuration: ComparisonVideoExportConfiguration(),
            policy: .unitTest
        )
        let poster = try exporter.renderPosterResult(
            pair: pair,
            configuration: ComparisonVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .dark,
                alignmentMode: .distance
            ),
            mapPreparation: map,
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            snapshot: nil,
            policy: .unitTest
        )
        XCTAssertEqual(poster.image.width, 320)
        XCTAssertEqual(poster.image.height, 180)
        XCTAssertEqual(poster.alignmentMode, .distance)
        XCTAssertGreaterThan(poster.sample.progress, 0)
        XCTAssertLessThan(poster.sample.progress, 1)
    }

    func testCancellationDuringExport() async throws {
        let primary = makeWorkout(distanceMeters: 1_200, pace: 300)
        let comparison = makeWorkout(distanceMeters: 1_200, pace: 300, latOffset: 0.0001)
        let pair = ComparisonPair(primary: primary, comparison: comparison)
        let exporter = ComparisonVideoExporter(
            mapPreparer: SyntheticComparisonVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("comparison-cancel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let task = Task {
            try await exporter.export(
                pair: pair,
                configuration: ComparisonVideoExportConfiguration(
                    duration: .sixtySeconds,
                    appearance: .light,
                    alignmentMode: .distance
                ),
                destinationURL: destination,
                policy: .unitTest,
                primaryContext: WorkoutAnalysisContext(workout: primary),
                comparisonContext: WorkoutAnalysisContext(workout: comparison)
            )
        }
        // Cancel promptly so encode cannot finish all frames.
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()

        do {
            _ = try await task.value
            // May finish if cancel lost the race on a tiny encode — still must not leave corrupt dest.
        } catch let error as ComparisonVideoExportError {
            XCTAssertTrue(error.isCancellation)
        } catch is CancellationError {
            // ok
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            // Destination may exist only if export completed before cancel was observed.
            let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(size, 0)
        }
    }

    func testFrameRendererDimensions() throws {
        let sample = ComparisonVideoFrameSample(
            frameIndex: 0,
            frameCount: 10,
            progress: 0,
            alignmentMode: .distance,
            domainPositionMeters: 0,
            domainLengthMeters: 1_000,
            alignmentBlockIndex: nil,
            alignmentBlockCount: nil,
            primaryDistanceMeters: 0,
            comparisonDistanceMeters: 0,
            primaryElapsedSeconds: 0,
            comparisonElapsedSeconds: 0,
            elapsedDeltaSeconds: 0,
            primaryActiveSeconds: 0,
            comparisonActiveSeconds: 0,
            activeDeltaSeconds: 0,
            primaryActivePaceSecondsPerKm: 300,
            comparisonActivePaceSecondsPerKm: 310,
            activePaceDeltaSecondsPerKm: -10,
            spatialSeparationMeters: nil,
            primaryRoutePosition: nil,
            comparisonRoutePosition: nil,
            alignmentQuality: nil,
            alignmentStatusLabel: nil
        )
        let model = ComparisonVideoFrameModel(
            sample: sample,
            primaryTitle: "Primary Run With A Very Long Name That Should Truncate Safely",
            comparisonTitle: "Comparison Run Also Long",
            primaryMarkerPixel: CGPoint(x: 40, y: 40),
            comparisonMarkerPixel: CGPoint(x: 80, y: 60),
            appearance: .light
        )
        let map = try makeSolidMap(width: 320, height: 180)
        let renderer = ComparisonVideoFrameRenderer()
        let image = try renderer.renderImage(
            frame: model,
            staticMap: map,
            width: 320,
            height: 180,
            mapSize: CGSize(width: 320, height: 180)
        )
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
    }

    /// Delta text states one identity only. `formatSignedDurationDelta` appends
    /// "slower"/"faster" unless suppressed, which previously produced the
    /// self-contradictory "C faster by 0:19 /km slower" in exported frames.
    func testDeltaLabelsCarryASingleIdentity() {
        let renderer = ComparisonVideoFrameRenderer()

        let slowerPrimary = renderer.formatDelta(19, kind: .pace)
        XCTAssertEqual(slowerPrimary, "C faster by 0:19 /km")

        let fasterPrimary = renderer.formatDelta(-19, kind: .pace)
        XCTAssertEqual(fasterPrimary, "P faster by 0:19 /km")

        for text in [slowerPrimary, fasterPrimary] {
            XCTAssertFalse(text.contains("slower"), "leaked formatter label in \(text)")
            XCTAssertFalse(text.hasSuffix(" "), "trailing separator in \(text)")
            XCTAssertEqual(
                text.components(separatedBy: "faster").count - 1,
                1,
                "delta text must state faster/slower exactly once: \(text)"
            )
        }

        // delta = primary - comparison; positive means primary took more time.
        XCTAssertEqual(renderer.formatDelta(42, kind: .time), "C ahead by 0:42")
        XCTAssertEqual(renderer.formatDelta(-42, kind: .time), "P ahead by 0:42")
        XCTAssertEqual(renderer.formatDelta(0, kind: .time), "Tie")
        XCTAssertEqual(renderer.formatDelta(nil, kind: .pace), "Unavailable")
    }

    // MARK: - Fixtures

    private func makeWorkout(
        distanceMeters: Double,
        pace: Double,
        latOffset: Double = 0
    ) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var d = 0.0
        let speed = 1000.0 / pace
        while d <= distanceMeters {
            let elapsed = d / speed
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 37.7749 + latOffset + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: elapsed,
                paceSecondsPerKilometer: pace,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + 25)
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Test Run"),
            routePoints: points
        )
    }

    private func makeSolidMap(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let image = context.makeImage() else {
            throw XCTSkip("Could not create solid map image")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
