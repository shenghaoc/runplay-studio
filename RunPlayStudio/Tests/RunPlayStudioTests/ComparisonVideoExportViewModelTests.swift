import XCTest
import os
@testable import RunPlayStudio
import RunPlayCore
import RunPlayPlatform

@MainActor
final class ComparisonVideoExportViewModelTests: XCTestCase {
    func testDefaultFilenameAndDistanceReady() async throws {
        let primary = makeWorkout(distanceMeters: 1_000, name: "Primary")
        let comparison = makeWorkout(distanceMeters: 1_000, name: "Comparison", latOffset: 0.0001)
        let client = MockComparisonVideoClient()
        let vm = ComparisonVideoExportViewModel(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            initialConfiguration: ComparisonVideoExportConfiguration(alignmentMode: .distance),
            exporter: client,
            policy: .unitTest,
            posterPolicy: .unitTest
        )
        vm.onAppear()
        // Wait for poster pipeline.
        for _ in 0..<50 {
            if vm.canExport { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(vm.defaultFilename().hasSuffix("-comparison-replay.mp4"))
        XCTAssertTrue(vm.defaultFilename().contains("-vs-"))
        XCTAssertEqual(vm.configuration.alignmentMode, .distance)
    }

    func testAppearanceChangeRebuildsMap() async throws {
        let primary = makeWorkout(distanceMeters: 800, name: "A")
        let comparison = makeWorkout(distanceMeters: 800, name: "B", latOffset: 0.0001)
        let client = MockComparisonVideoClient()
        let vm = ComparisonVideoExportViewModel(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            initialConfiguration: ComparisonVideoExportConfiguration(alignmentMode: .distance),
            exporter: client,
            policy: .unitTest,
            posterPolicy: .unitTest
        )
        vm.onAppear()
        for _ in 0..<50 {
            if client.prepareCount >= 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let initialPrepares = client.prepareCount
        vm.configuration.appearance = .dark
        for _ in 0..<50 {
            if client.prepareCount > initialPrepares { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(client.prepareCount, initialPrepares)
    }

    func testDurationChangeReusesMap() async throws {
        let primary = makeWorkout(distanceMeters: 800, name: "A")
        let comparison = makeWorkout(distanceMeters: 800, name: "B", latOffset: 0.0001)
        let client = MockComparisonVideoClient()
        let vm = ComparisonVideoExportViewModel(
            pair: ComparisonPair(primary: primary, comparison: comparison),
            primaryContext: WorkoutAnalysisContext(workout: primary),
            comparisonContext: WorkoutAnalysisContext(workout: comparison),
            initialConfiguration: ComparisonVideoExportConfiguration(
                duration: .fifteenSeconds,
                alignmentMode: .distance
            ),
            exporter: client,
            policy: .unitTest,
            posterPolicy: .unitTest
        )
        vm.onAppear()
        for _ in 0..<50 {
            if client.prepareCount >= 1, client.posterCount >= 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let prepares = client.prepareCount
        let posters = client.posterCount
        vm.configuration.duration = .thirtySeconds
        for _ in 0..<50 {
            if client.posterCount > posters { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(client.prepareCount, prepares)
        XCTAssertGreaterThan(client.posterCount, posters)
    }

    // MARK: - Mock

    private final class MockComparisonVideoClient: ComparisonVideoExportClient, @unchecked Sendable {
        private let prepareCounter = OSAllocatedUnfairLock(initialState: 0)
        private let posterCounter = OSAllocatedUnfairLock(initialState: 0)
        private let preparer = SyntheticComparisonVideoMapPreparer()
        private let renderer = ComparisonVideoFrameRenderer()

        var prepareCount: Int {
            prepareCounter.withLock { $0 }
        }

        var posterCount: Int {
            posterCounter.withLock { $0 }
        }

        func prepareMap(
            pair: ComparisonPair,
            configuration: ComparisonVideoExportConfiguration,
            policy: WorkoutVideoExportPolicy
        ) async throws -> ComparisonVideoMapPreparation {
            prepareCounter.withLock { $0 += 1 }
            let request = ComparisonVideoMapPreparationRequest(
                size: CGSize(width: policy.width, height: policy.height),
                appearance: WorkoutMapSnapshotAppearance(configuration.appearance),
                primaryRoutePoints: pair.primary.routePoints,
                comparisonRoutePoints: pair.comparison.routePoints
            )
            return try await preparer.prepare(request: request)
        }

        func renderPosterResult(
            pair: ComparisonPair,
            configuration: ComparisonVideoExportConfiguration,
            mapPreparation: ComparisonVideoMapPreparation,
            primaryContext: WorkoutAnalysisContext,
            comparisonContext: WorkoutAnalysisContext,
            snapshot: RouteAlignmentSnapshot?,
            policy: WorkoutVideoExportPolicy
        ) throws -> ComparisonVideoPoster {
            posterCounter.withLock { $0 += 1 }
            let sampler = ComparisonVideoSampler(
                pair: pair,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext,
                alignmentMode: configuration.alignmentMode,
                snapshot: snapshot
            )
            let plan = try ComparisonVideoFramePlan.make(
                duration: configuration.duration,
                policy: policy,
                domainLength: max(1, sampler.domainLengthMeters),
                domain: sampler.domain
            )
            let sample = sampler.sample(frameIndex: plan.frameCount / 2, plan: plan)
            let model = ComparisonVideoFrameModel(
                sample: sample,
                primaryTitle: pair.primary.displayName,
                comparisonTitle: pair.comparison.displayName,
                primaryMarkerPixel: nil,
                comparisonMarkerPixel: nil,
                appearance: configuration.appearance
            )
            let image = try renderer.renderImage(
                frame: model,
                staticMap: mapPreparation.staticMapImage,
                width: policy.width,
                height: policy.height,
                mapSize: CGSize(width: mapPreparation.pixelWidth, height: mapPreparation.pixelHeight)
            )
            return ComparisonVideoPoster(
                image: image,
                sample: sample,
                alignmentMode: configuration.alignmentMode
            )
        }

        func export(
            pair: ComparisonPair,
            configuration: ComparisonVideoExportConfiguration,
            destinationURL: URL,
            policy: WorkoutVideoExportPolicy,
            primaryContext: WorkoutAnalysisContext,
            comparisonContext: WorkoutAnalysisContext,
            alignmentSeed: ComparisonVideoAlignmentSeed?,
            mapPreparation: ComparisonVideoMapPreparation?,
            progress: @Sendable (WorkoutVideoExportProgress) async -> Void
        ) async throws -> ComparisonVideoExportResult {
            await progress(WorkoutVideoExportProgress(phase: .encoding, completedFrames: 1, totalFrames: 10))
            try Data([0]).write(to: destinationURL)
            return ComparisonVideoExportResult(
                url: destinationURL,
                filename: destinationURL.lastPathComponent,
                fileSizeBytes: 1,
                outputDurationSeconds: Double(configuration.duration.seconds),
                frameCount: 10,
                width: policy.width,
                height: policy.height,
                framesPerSecond: policy.framesPerSecond,
                alignmentMode: configuration.alignmentMode
            )
        }
    }

    private func makeWorkout(
        distanceMeters: Double,
        name: String,
        latOffset: Double = 0
    ) -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var d = 0.0
        while d <= distanceMeters {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(d / 3),
                latitude: 37.7749 + latOffset + d / 111_000,
                longitude: -122.4194,
                distanceFromStartMeters: d,
                elapsedSeconds: d / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if d >= distanceMeters { break }
            d = min(distanceMeters, d + 25)
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: name),
            routePoints: points
        )
    }
}
