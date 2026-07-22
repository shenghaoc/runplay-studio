import XCTest
@testable import RunPlayStudio
import RunPlayCore
import RunPlayPlatform

@MainActor
final class PNGSummaryExportTests: XCTestCase {
    func testMapInclusiveLayoutUsesCompactLimits() {
        let workout = workoutWithManySplits()
        let segments = manySegments(count: 8)
        let metrics = ExportSummaryCardModel(workout: workout, segments: segments, layout: .metricsOnly)
        let mapCard = ExportSummaryCardModel(
            workout: workout,
            segments: segments,
            layout: .mapInclusive,
            includesMapImagery: true
        )
        XCTAssertEqual(metrics.segments.count, 5)
        XCTAssertEqual(metrics.splits.count, 10)
        XCTAssertEqual(mapCard.segments.count, 3)
        XCTAssertEqual(mapCard.splits.count, 5)
        XCTAssertNotNil(mapCard.segmentsTruncationText)
        XCTAssertNotNil(mapCard.splitsTruncationText)
        XCTAssertTrue(mapCard.privacyNote.contains("Apple Maps"))
        XCTAssertFalse(metrics.privacyNote.contains("Apple Maps"))
    }

    func testConfigurationLayoutHelpers() {
        let config = PNGSummaryExportConfiguration(includeMap: true, appearance: .dark, routeColorMode: .pace)
        XCTAssertEqual(config.layout(hasMapImage: true), .mapInclusive)
        XCTAssertEqual(config.layout(hasMapImage: false), .metricsOnly)
    }

    func testAsyncMetricsOnlyExportDimensions() async throws {
        let result = try await PNGExportService.exportSummaryPNG(
            workout: sampleWorkout(),
            segments: [],
            configuration: PNGSummaryExportConfiguration(
                includeMap: false,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: nil
        )
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: result.data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
    }

    func testAsyncMapExportWithBlankSnapshotter() async throws {
        let result = try await PNGExportService.exportSummaryPNG(
            workout: sampleWorkout(),
            segments: [],
            configuration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .dark,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankSnapshotter()
        )
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: result.data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
        XCTAssertTrue(result.filename.hasSuffix(".png"))
    }

    func testSolidMapExportSkipsMetricAvailabilityProbe() async throws {
        let recorder = ExportProfileBuilderRecorder()

        _ = try await PNGExportService.exportSummaryPNG(
            workout: sampleWorkout(),
            segments: [],
            configuration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: BlankSnapshotter(),
            profileBuilder: RecordingExportProfileBuilder(recorder: recorder)
        )

        XCTAssertEqual(recorder.probeCount, 0)
        XCTAssertEqual(recorder.buildModes, [.solid])
    }

    func testMapFailurePropagatesAndMetricsPathRemains() async throws {
        do {
            _ = try await PNGExportService.exportSummaryPNG(
                workout: sampleWorkout(),
                segments: [],
                configuration: PNGSummaryExportConfiguration(
                    includeMap: true,
                    appearance: .light,
                    routeColorMode: .solid
                ),
                mapSnapshotter: AlwaysFailSnapshotter()
            )
            XCTFail("Expected map failure")
        } catch {
            XCTAssertTrue(error is WorkoutMapSnapshotError || "\(error)".contains("Map") || "\(error)".contains("unavailable"))
        }

        let metrics = try await PNGExportService.exportSummaryPNG(
            workout: sampleWorkout(),
            segments: [],
            configuration: PNGSummaryExportConfiguration(
                includeMap: false,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: AlwaysFailSnapshotter()
        )
        XCTAssertFalse(metrics.data.isEmpty)
    }

    func testNoGPSFallsBackToMetricsOnlyEvenWhenIncludeMapTrue() async throws {
        let result = try await PNGExportService.exportSummaryPNG(
            workout: RunWorkout(
                metadata: WorkoutMetadata(name: "No GPS", activityType: "run"),
                source: .json,
                routePoints: []
            ),
            segments: [],
            configuration: PNGSummaryExportConfiguration(
                includeMap: true,
                appearance: .light,
                routeColorMode: .solid
            ),
            mapSnapshotter: AlwaysFailSnapshotter()
        )
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: result.data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
    }

    func testHasUsableRouteDetection() {
        XCTAssertTrue(PNGExportService.hasUsableRoute(sampleWorkout()))
        XCTAssertFalse(PNGExportService.hasUsableRoute(RunWorkout(routePoints: [])))
    }

    func testRouteColorReuseUsesCanonicalBuilders() throws {
        let workout = sampleWorkout()
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try RouteMetricProfileBuilder().build(
            routePoints: workout.routePoints,
            context: context,
            mode: .pace
        )
        let lines = try RouteMetricMapLineBuilder().build(
            routePoints: workout.routePoints,
            profile: profile,
            idPrefix: "export-route"
        )
        XCTAssertFalse(lines.lines.isEmpty)
        // Export path uses the same builders; gap preservation: multi-segment should stay separate.
        let multi = multiSegmentWorkout()
        let multiContext = WorkoutAnalysisContext(workout: multi)
        let solidProfile = try RouteMetricProfileBuilder().build(
            routePoints: multi.routePoints,
            context: multiContext,
            mode: .solid
        )
        let multiLines = try RouteMetricMapLineBuilder().build(
            routePoints: multi.routePoints,
            profile: solidProfile,
            idPrefix: "export-route"
        )
        XCTAssertGreaterThanOrEqual(multiLines.lines.count, 2)
    }

    // MARK: - Helpers

    private func sampleWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(50)
        for i in 0..<50 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 4),
                    latitude: 37.77 + index * 0.00012,
                    longitude: -122.42 + index * 0.0001,
                    altitudeMeters: 15 + index * 0.15,
                    distanceFromStartMeters: index * 15,
                    elapsedSeconds: index * 4,
                    heartRateBPM: 135 + Double(i % 12)
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "PNG Export Test", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 735,
                totalElapsedSeconds: 200,
                averagePaceSecondsPerKilometer: 272,
                elevationGainMeters: 7,
                averageHeartRateBPM: 140,
                maxHeartRateBPM: 155
            )
        )
    }

    private func multiSegmentWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 3),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 10,
                elapsedSeconds: Double(i) * 3,
                routeSegmentIndex: 0
            ))
        }
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(20 + i) * 3),
                latitude: 37.78 + Double(i) * 0.0001,
                longitude: -122.41,
                distanceFromStartMeters: 100 + Double(i) * 10,
                elapsedSeconds: Double(20 + i) * 3,
                routeSegmentIndex: 1
            ))
        }
        return RunWorkout(routePoints: points)
    }

    private func workoutWithManySplits() -> RunWorkout {
        var splits: [RunSplit] = []
        splits.reserveCapacity(12)
        for index in 1...12 {
            splits.append(
                RunSplit(
                    splitIndex: index,
                    elapsedSeconds: 300,
                    paceSecondsPerKilometer: 300,
                    startDistanceMeters: Double(index - 1) * 1_000,
                    endDistanceMeters: Double(index) * 1_000
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Many Splits", activityType: "run"),
            source: .json,
            routePoints: sampleWorkout().routePoints,
            splits: splits,
            summary: RunSummary(totalDistanceMeters: 12_000, totalElapsedSeconds: 3_600)
        )
    }

    private func manySegments(count: Int) -> [SegmentHighlight] {
        var segments: [SegmentHighlight] = []
        segments.reserveCapacity(count)
        for i in 0..<count {
            let startDistance = Double(i) * 100
            let endDistance = Double(i + 1) * 100
            let startElapsed = Double(i) * 30
            let endElapsed = Double(i + 1) * 30
            let segment = SegmentHighlight(
                type: .fastest1km,
                title: "Segment \(i + 1)",
                subtitle: "value",
                startDistanceMeters: startDistance,
                endDistanceMeters: endDistance,
                startElapsedSeconds: startElapsed,
                endElapsedSeconds: endElapsed,
                durationSeconds: 30,
                distanceMeters: 100,
                paceSecondsPerKilometer: 300,
                sourcePointRange: 0..<2
            )
            segments.append(segment)
        }
        return segments
    }
}

private struct BlankSnapshotter: WorkoutMapSnapshotting {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        let width = max(1, Int(request.size.width))
        let height = max(1, Int(request.size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let basemap = context.makeImage()!
        let converter = LinearMapCoordinateConverter(routes: request.routes, size: request.size)
        return try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: request.routes,
            markers: request.markers,
            converter: converter,
            lineWidth: request.lineWidth
        )
    }
}

private struct AlwaysFailSnapshotter: WorkoutMapSnapshotting {
    func makeSnapshot(request: WorkoutMapSnapshotRequest) async throws -> WorkoutMapSnapshotResult {
        throw WorkoutMapSnapshotError.snapshotFailed("offline")
    }
}

private final class ExportProfileBuilderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _probeCount = 0
    private var _buildModes: [WorkoutRouteColorMode] = []

    var probeCount: Int {
        lock.withLock { _probeCount }
    }

    var buildModes: [WorkoutRouteColorMode] {
        lock.withLock { _buildModes }
    }

    func recordProbe() {
        lock.withLock { _probeCount += 1 }
    }

    func recordBuild(_ mode: WorkoutRouteColorMode) {
        lock.withLock { _buildModes.append(mode) }
    }
}

private struct RecordingExportProfileBuilder: RouteMetricProfileBuilding {
    let recorder: ExportProfileBuilderRecorder
    private let base = RouteMetricProfileBuilder()

    func build(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        mode: WorkoutRouteColorMode,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfile {
        recorder.recordBuild(mode)
        return try base.build(
            routePoints: routePoints,
            context: context,
            mode: mode,
            policy: policy,
            isCancelled: isCancelled
        )
    }

    func probe(
        routePoints: [RoutePoint],
        context: WorkoutAnalysisContext,
        policy: RouteMetricColorPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteMetricProfileProbe {
        recorder.recordProbe()
        return try base.probe(
            routePoints: routePoints,
            context: context,
            policy: policy,
            isCancelled: isCancelled
        )
    }
}
