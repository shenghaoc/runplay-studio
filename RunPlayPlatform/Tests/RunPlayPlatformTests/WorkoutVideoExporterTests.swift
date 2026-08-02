import AVFoundation
import CoreGraphics
import os
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform

final class WorkoutVideoExporterTests: XCTestCase {
    func testUnitPolicyExportWithMatchingDuration() async throws {
        // 15 s × 10 fps = 150 frames under a raised test ceiling.
        let exportPolicy = WorkoutVideoExportPolicy(
            width: 320,
            height: 180,
            framesPerSecond: 10,
            averageBitRate: 400_000,
            maximumFrameCount: 200,
            progressUpdateStride: 5
        )

        let workout = sampleWorkout()
        let exporter = WorkoutVideoExporter(
            mapPreparer: SyntheticWorkoutVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-video-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let progressBox = ProgressBox()
        let result = try await exporter.export(
            workout: workout,
            configuration: WorkoutVideoExportConfiguration(
                duration: .fifteenSeconds,
                appearance: .dark,
                routeColorMode: .solid
            ),
            destinationURL: destination,
            policy: exportPolicy,
            mapPreparation: nil
        ) { progress in
            progressBox.record(progress.completedFrames)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(result.fileSizeBytes, 0)
        XCTAssertEqual(result.frameCount, 150)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.framesPerSecond, 10)
        XCTAssertEqual(progressBox.maxCompleted, 150)
        XCTAssertEqual(result.filename, destination.lastPathComponent)

        let asset = AVURLAsset(url: destination)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertGreaterThan(seconds, 14.0)
        XCTAssertLessThan(seconds, 16.5)

        // Destination move leaves a playable file.
        let moved = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-video-moved-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: destination, to: moved)
        let movedAsset = AVURLAsset(url: moved)
        let movedTracks = try await movedAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(movedTracks.count, 1)
    }

    func testCancellationCleansTemporaryFile() async throws {
        let exportPolicy = WorkoutVideoExportPolicy(
            width: 320,
            height: 180,
            framesPerSecond: 10,
            averageBitRate: 400_000,
            maximumFrameCount: 200,
            progressUpdateStride: 1
        )
        let workout = sampleWorkout()
        let exporter = WorkoutVideoExporter(
            mapPreparer: SyntheticWorkoutVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-video-cancel-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let task = Task {
            try await exporter.export(
                workout: workout,
                configuration: WorkoutVideoExportConfiguration(
                    duration: .fifteenSeconds,
                    appearance: .light,
                    routeColorMode: .solid
                ),
                destinationURL: destination,
                policy: exportPolicy,
                mapPreparation: nil
            ) { _ in }
        }
        // Cancel quickly after start.
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do {
            _ = try await task.value
            // If encoding was very fast, file may exist — only assert cleanup on cancel path.
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch let error as WorkoutVideoExportError where error.isCancellation {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        } catch {
            // Completed before cancel is acceptable.
        }
    }

    func testMapFailureSurfacesStructuredError() async throws {
        let exporter = WorkoutVideoExporter(
            mapPreparer: FailingVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-video-fail-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try await exporter.export(
                workout: sampleWorkout(),
                configuration: WorkoutVideoExportConfiguration(
                    duration: .fifteenSeconds,
                    appearance: .light,
                    routeColorMode: .solid
                ),
                destinationURL: destination,
                policy: WorkoutVideoExportPolicy(
                    width: 320,
                    height: 180,
                    framesPerSecond: 10,
                    averageBitRate: 400_000,
                    maximumFrameCount: 200
                ),
                mapPreparation: nil
            ) { _ in }
            XCTFail("Expected map failure")
        } catch let error as WorkoutVideoExportError {
            guard case .mapPreparationFailed = error else {
                XCTFail("Unexpected error \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNoUsableRouteRejected() async {
        let exporter = WorkoutVideoExporter(
            mapPreparer: SyntheticWorkoutVideoMapPreparer()
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-video-empty-\(UUID().uuidString).mp4")
        do {
            _ = try await exporter.export(
                workout: RunWorkout(routePoints: []),
                configuration: WorkoutVideoExportConfiguration(),
                destinationURL: destination,
                policy: .unitTest,
                mapPreparation: nil
            ) { _ in }
            XCTFail("Expected eligibility failure")
        } catch let error as WorkoutVideoExportError {
            XCTAssertTrue(
                error == .noUsableRoute || error == .noPlayableTimeline
            )
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    private func sampleWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<30 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 4),
                    latitude: 37.77 + index * 0.00012,
                    longitude: -122.42 + index * 0.0001,
                    altitudeMeters: 15 + index * 0.1,
                    distanceFromStartMeters: index * 15,
                    elapsedSeconds: index * 4,
                    paceSecondsPerKilometer: 280,
                    heartRateBPM: 140
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Encoder Test", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 435,
                totalElapsedSeconds: 116,
                averagePaceSecondsPerKilometer: 280
            )
        )
    }
}

private struct FailingVideoMapPreparer: WorkoutVideoMapPreparing {
    func prepare(
        request: WorkoutVideoMapPreparationRequest
    ) async throws -> WorkoutVideoMapPreparation {
        throw WorkoutMapSnapshotError.snapshotFailed("synthetic map failure")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let box = OSAllocatedUnfairLock(initialState: 0)

    var maxCompleted: Int {
        box.withLock { $0 }
    }

    func record(_ completed: Int) {
        box.withLock { $0 = max($0, completed) }
    }
}
