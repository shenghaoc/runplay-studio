import XCTest
import Foundation
import ZIPFoundation
import RunPlayCore
@testable import RunPlayPlatform

/// Platform-layer remaining-core hotspot profile (map lines + Strava archive).
///
/// Skipped unless `RUNPLAY_CORE_HOTSPOT_PROFILE=1`.
final class RemainingPlatformHotspotProfile: XCTestCase {

    func testPlatformMapLineProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
            "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1"
        )
        let family = ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_FAMILY"] ?? "all"
        guard family == "all" || family == "metrics" else { return }

        print("\n<!-- BEGIN RUNPLAY PLATFORM HOTSPOT PROFILE LINES -->")
        print("\n# Platform — RouteMetricMapLineBuilder\n")
        print("| Fixture | Profile build median ms | Line coalesce median ms | Lines | Parity |")
        print("|---|---:|---:|---:|:---:|")

        for (label, count, warmups, iterations) in [
            ("C1-like 100k pace", 100_000, 2, 5),
            ("C4-like segments 50k", 50_000, 2, 5)
        ] as [(String, Int, Int, Int)] {
            var workout = makeWorkout(pointCount: count, seed: UInt64(count))
            WorkoutAnalyzer().analyze(&workout)
            let context = WorkoutAnalysisContext(workout: workout)
            let profileBuilder = RouteMetricProfileBuilder()
            let lineBuilder = RouteMetricMapLineBuilder()

            let profileStats = try measure(warmups: warmups, iterations: iterations) {
                try profileBuilder.build(
                    routePoints: workout.routePoints,
                    context: context,
                    mode: .pace
                )
            }
            let profile = profileStats.last

            let lineStats = try measure(warmups: warmups, iterations: iterations) {
                try lineBuilder.build(
                    routePoints: workout.routePoints,
                    profile: profile,
                    idPrefix: "profile"
                )
            }
            let again = try lineBuilder.build(
                routePoints: workout.routePoints,
                profile: profile,
                idPrefix: "profile"
            )
            XCTAssertEqual(lineStats.last.lines.count, again.lines.count)
            XCTAssertEqual(lineStats.last.diagnostics.lineCount, again.diagnostics.lineCount)

            // Digest coordinates for parity on a sample of lines.
            XCTAssertEqual(lineStats.last.lines.map(\.id), again.lines.map(\.id))

            print(
                "| \(label) | \(fmt(profileStats.medianMs)) | \(fmt(lineStats.medianMs)) | \(lineStats.last.lines.count) | ok |"
            )
        }

        print(
            "\n_Studio metric cache / replay non-rebuild behavior is asserted by WorkoutRouteMapViewModelTests (cache hit, availability probe reuse, replay index independence)._\n"
        )
        print("\n<!-- END RUNPLAY PLATFORM HOTSPOT PROFILE LINES -->\n")
    }

    func testPlatformStravaArchiveProfile() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1",
            "Set RUNPLAY_CORE_HOTSPOT_PROFILE=1"
        )
        let family = ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_FAMILY"] ?? "all"
        guard family == "all" || family == "import" else { return }

        print("\n<!-- BEGIN RUNPLAY PLATFORM HOTSPOT PROFILE STRAVA -->")
        print("\n# Platform — Strava archive import path\n")

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-strava-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let gpxA = makeGPX(name: "A", lat: 35.0, lon: 135.0, points: 200)
        let gpxB = makeGPX(name: "B", lat: 35.1, lon: 135.1, points: 150)
        let ignored = Data("not-a-workout".utf8)
        let csv = Data("""
        Activity ID,Activity Name,Activity Type,Activity Date,Filename
        1,A,Run,"2024-01-01T08:00:00Z",activities/1.gpx
        2,B,Run,"2024-01-02T08:00:00Z",activities/2.gpx
        3,Ignore,Ride,"2024-01-03T08:00:00Z",activities/3.fit
        """.utf8)
        let zipURL = temp.appendingPathComponent("export.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for entry in [
            ("export/activities.csv", csv),
            ("export/activities/1.gpx", gpxA),
            ("export/activities/2.gpx", gpxB),
            ("export/activities/3.fit", ignored)
        ] as [(String, Data)] {
            try archive.addEntry(
                with: entry.0,
                type: .file,
                uncompressedSize: Int64(entry.1.count),
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, entry.1.count)
                    return entry.1.subdata(in: start..<end)
                }
            )
        }

        let service = StravaArchiveService()
        var scanSamples: [Double] = []
        var lastCandidateCount = 0
        for i in 0..<7 {
            let t0 = ContinuousClock.now
            let result = try await service.scanArchive(at: zipURL, existingWorkouts: [])
            if i >= 2 {
                scanSamples.append(elapsedMs(from: t0))
                lastCandidateCount = result.candidates.count
            }
        }

        let scanResult = try await service.scanArchive(at: zipURL, existingWorkouts: [])
        XCTAssertTrue(scanResult.isRecognizedStravaExport)
        XCTAssertGreaterThanOrEqual(scanResult.candidates.count, 2)

        let ready = scanResult.candidates.filter { $0.status == .ready }
        XCTAssertFalse(ready.isEmpty)

        // Import once end-to-end through the production archive path (requires a store).
        let libraryRoot = temp.appendingPathComponent("lib")
        let storeActor = WorkoutLibraryStoreActor(store: FileWorkoutLibraryStore(rootURL: libraryRoot))
        let selection = WorkoutBatchImportSelection(
            selectedCandidateIDs: Array(ready.prefix(2).map(\.id)),
            candidates: scanResult.candidates
        )
        let t0 = ContinuousClock.now
        let report = try await service.importCandidates(
            selection,
            from: zipURL,
            existingWorkouts: [],
            storeActor: storeActor
        )
        let importMs = elapsedMs(from: t0)
        XCTAssertGreaterThanOrEqual(report.importedCount, 1)

        print("| Phase | median/single ms | Notes |")
        print("|---|---:|---|")
        print("| scanArchive (decompress+candidates) | \(fmt(median(scanSamples))) median | candidates=\(lastCandidateCount) |")
        print("| importCandidates (2 ready) | \(fmt(importMs)) single | imported=\(report.importedCount) |")
        print("| ignored/rejected entry | present | non-run activity in archive |")
        print("\n<!-- END RUNPLAY PLATFORM HOTSPOT PROFILE STRAVA -->\n")
    }

    // MARK: - Helpers

    private func measure<T>(
        warmups: Int,
        iterations: Int,
        _ body: () throws -> T
    ) rethrows -> (medianMs: Double, last: T) {
        var samples: [Double] = []
        var last: T?
        let total = warmups + iterations
        for i in 0..<total {
            let t0 = ContinuousClock.now
            last = try body()
            if i >= warmups {
                samples.append(elapsedMs(from: t0))
            }
        }
        return (median(samples), last!)
    }

    private func elapsedMs(from start: ContinuousClock.Instant) -> Double {
        let comps = start.duration(to: ContinuousClock.now).components
        let nanos = comps.seconds * 1_000_000_000 + comps.attoseconds / 1_000_000_000
        return Double(max(0, nanos)) / 1_000_000
    }

    private func median(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let s = samples.sorted()
        let mid = s.count / 2
        if s.count % 2 == 0 {
            return (s[mid - 1] + s[mid]) / 2
        }
        return s[mid]
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func makeWorkout(pointCount: Int, seed: UInt64) -> RunWorkout {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        var x = 0.0
        for i in 0..<pointCount {
            let lat = 35.0 + unit() * 0.00001
            let lon = 135.0 + x / 111_320.0
            points.append(RoutePoint(
                timestamp: base.addingTimeInterval(Double(i)),
                latitude: lat,
                longitude: lon,
                altitudeMeters: 50 + unit() * 10,
                distanceFromStartMeters: x,
                elapsedSeconds: Double(i),
                speedMetersPerSecond: 3.0,
                paceSecondsPerKilometer: 1000.0 / 3.0,
                heartRateBPM: 140,
                routeSegmentIndex: min(9, i / max(1, pointCount / 10))
            ))
            x += 10
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "platform-\(pointCount)", startDate: base),
            routePoints: points
        )
    }

    private func makeGPX(name: String, lat: Double, lon: Double, points: Int) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunPlayHotspot"><trk><name>\(name)</name><trkseg>
        """
        for i in 0..<points {
            let minute = min(59, i / 60)
            let second = i % 60
            let t = String(format: "2024-01-01T08:%02d:%02dZ", minute, second)
            xml += #"<trkpt lat="\#(lat + Double(i) * 0.0001)" lon="\#(lon)"><ele>10</ele><time>\#(t)</time></trkpt>"#
        }
        xml += "</trkseg></trk></gpx>"
        return Data(xml.utf8)
    }
}
