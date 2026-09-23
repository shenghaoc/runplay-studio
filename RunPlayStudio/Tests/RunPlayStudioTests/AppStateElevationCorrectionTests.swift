import CoreGraphics
import Foundation
import ImageIO
import XCTest
import RunPlayCore
import RunPlayPlatform
@testable import RunPlayStudio

/// Settings → Elevation: choosing the tile folder, correcting new imports,
/// the library pass, and refreshing what shows elevation. Tiles are real
/// Terrarium PNGs on disk; the route sits in tile (2131, 1450) at zoom 12.
@MainActor
final class AppStateElevationCorrectionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppStateElevation-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Folder

    func testChoosingAFolderSavesItOpensItAndArmsImports() throws {
        let tiles = try writeTileBlock(height: 612)
        let settingsStore = FileDEMTileSettingsStore(rootURL: root.appendingPathComponent("library"))
        let appState = AppState(demSettingsStore: settingsStore)

        XCTAssertNil(appState.chooseDEMTileFolder(at: tiles))

        XCTAssertEqual(appState.demFolderStatus, .ready)
        let folder = try XCTUnwrap(appState.demTileSettings.folder)
        XCTAssertEqual(folder.availableZooms, [12])
        XCTAssertEqual(folder.zoom, 12)
        XCTAssertEqual(folder.tileSize, 4)
        XCTAssertEqual(settingsStore.loadOrDefault(), appState.demTileSettings, "saved beside the library")
        XCTAssertNotNil(appState.demImportCorrection, "new imports are corrected by default")

        appState.setDEMCorrectsNewImports(false)
        XCTAssertNil(appState.demImportCorrection)
        XCTAssertFalse(settingsStore.loadOrDefault().correctsNewImports)

        appState.forgetDEMTileFolder()
        XCTAssertEqual(appState.demFolderStatus, .notChosen)
        XCTAssertNil(settingsStore.loadOrDefault().folder)
    }

    func testAFolderWithoutTilesIsRefusedAndAMissingOneIsReported() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appState = AppState()
        XCTAssertNotNil(appState.chooseDEMTileFolder(at: root))
        XCTAssertNil(appState.demTileSettings.folder)

        let tiles = try writeTileBlock(height: 5)
        XCTAssertNil(appState.chooseDEMTileFolder(at: tiles))
        try FileManager.default.removeItem(at: tiles)
        appState.openDEMTileFolder()
        guard case .unavailable = appState.demFolderStatus else {
            return XCTFail("a vanished folder is reported, not silently dropped")
        }
        XCTAssertNil(appState.demImportCorrection)
    }

    // MARK: - Imports

    func testImportedRunsAreCorrectedBeforeTheyAreSaved() async throws {
        let (appState, store, recorder) = try makeLibraryAppState()
        XCTAssertNil(appState.chooseDEMTileFolder(at: try writeTileBlock(height: 612)))

        await appState.importWorkout(from: try writeGPX())

        let workout = try XCTUnwrap(appState.workouts.first)
        XCTAssertEqual(workout.demElevationCorrection?.outcome, .applied)
        XCTAssertTrue(workout.routePoints.allSatisfy { $0.demAltitudeMeters == 612 })
        XCTAssertEqual(try store.loadWorkout(id: workout.id).demElevationCorrection?.outcome, .applied)
        XCTAssertEqual(
            recorder.messages.last,
            "Imported run.gpx. Elevation corrected from DEM tiles covering 100% of the route, "
                + "replacing recorded altitude from an unstated sensor."
        )
    }

    func testWatchFolderImportsCarryTheElevationSummaryOnTheirRow() async throws {
        let (appState, _, _) = try makeLibraryAppState()
        XCTAssertNil(appState.chooseDEMTileFolder(at: try writeTileBlock(height: 612)))

        let result = await appState.performWatchFolderImport(
            from: try writeGPX(),
            configuration: WatchFolderConfiguration(displayName: "Inbox", bookmarkData: Data())
        )

        XCTAssertEqual(result.outcome, .imported)
        XCTAssertEqual(
            result.detail,
            "Elevation corrected from DEM tiles covering 100% of the route, replacing recorded altitude from an unstated sensor."
        )
        XCTAssertEqual(appState.workouts.first?.demElevationCorrection?.outcome, .applied)
    }

    // MARK: - Library pass

    func testLibraryPassCorrectsEarlierImportsAndRefreshesTheSelectedRun() async throws {
        let (appState, store, recorder) = try makeLibraryAppState()
        await appState.importWorkout(from: try writeGPX())
        let imported = try XCTUnwrap(appState.workouts.first)
        XCTAssertNil(imported.demElevationCorrection, "no folder at import time")
        let staleContext = appState.analysisContext(for: imported)
        XCTAssertEqual(staleContext.elevationProfile.sourceCounts.demPointCount, 0)

        XCTAssertNil(appState.chooseDEMTileFolder(at: try writeTileBlock(height: 612)))
        XCTAssertEqual(appState.demUncorrectedCount, 1)
        appState.correctLibraryElevation()
        try await waitForPass(appState)

        guard case .finished(let summary) = appState.demCorrectionPassState else {
            return XCTFail("the pass reports what it did")
        }
        XCTAssertEqual(summary, "Corrected 1 run; 0 runs needed no change.")
        XCTAssertEqual(recorder.messages.last, "Elevation correction finished. Corrected 1 run; 0 runs needed no change.")
        let corrected = try XCTUnwrap(appState.workouts.first)
        XCTAssertEqual(corrected.demElevationCorrection?.outcome, .applied)
        XCTAssertEqual(appState.selectedWorkout?.demElevationCorrection, corrected.demElevationCorrection)
        XCTAssertEqual(appState.demUncorrectedCount, 0)
        XCTAssertEqual(
            appState.analysisContext(for: corrected).elevationProfile.sourceCounts.demPointCount,
            corrected.routePoints.count,
            "the cached context is rebuilt from DEM elevation"
        )
        XCTAssertEqual(try store.loadWorkout(id: corrected.id).demElevationCorrection?.outcome, .applied)
    }

    func testCachedContextNeverOutlivesAnElevationChange() throws {
        let appState = AppState()
        let points = (0..<20).map { index in
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                latitude: 46.44 + Double(index) * 0.0001,
                longitude: 7.3,
                altitudeMeters: 100,
                distanceFromStartMeters: Double(index) * 11,
                elapsedSeconds: Double(index)
            )
        }
        let recorded = RunWorkout(routePoints: points)
        _ = appState.analysisContext(for: recorded)
        XCTAssertNotNil(appState.cachedAnalysisContext(for: recorded))

        var corrected = recorded
        for index in corrected.routePoints.indices { corrected.routePoints[index].demAltitudeMeters = 300 }
        corrected.demElevationCorrection = DEMElevationCorrection(
            outcome: .applied,
            tileSet: DEMTileSetIdentity(folderID: UUID(), zoom: 12, tileSize: 4),
            correctedAt: Date()
        )
        XCTAssertNil(appState.cachedAnalysisContext(for: corrected), "same point IDs, different elevation")
    }

    // MARK: - Report wording

    func testReportTextNamesCoverageOnlyWhenTheImportCorrected() {
        var coverage = DEMElevationCoverage()
        coverage.pointCount = 10
        coverage.sampledPointCount = 9
        coverage.missingTilePointCount = 1
        let applied = DEMElevationCorrection(outcome: .applied, tileSet: nil, correctedAt: Date(), coverage: coverage)

        XCTAssertEqual(DEMImportReportText.itemDetail(applied, correctsElevation: true), "DEM tiles cover 90%")
        XCTAssertEqual(DEMImportReportText.itemDetail(nil, correctsElevation: true), "Elevation not corrected")
        XCTAssertNil(DEMImportReportText.itemDetail(applied, correctsElevation: false))
        XCTAssertNil(DEMImportReportText.summary(records: [applied], correctsElevation: false, commitFailed: false))
        XCTAssertNil(DEMImportReportText.summary(records: [applied], correctsElevation: true, commitFailed: true))
        XCTAssertEqual(
            DEMImportReportText.summary(records: [applied, nil], correctsElevation: true, commitFailed: false),
            "DEM elevation for 2 runs: 1 corrected, 1 not corrected after an error."
        )
    }

    // MARK: - Helpers

    private func makeLibraryAppState() throws -> (AppState, FileWorkoutLibraryStore, RecordingAccessibilityAnnouncer) {
        let library = root.appendingPathComponent("library", isDirectory: true)
        let store = FileWorkoutLibraryStore(rootURL: library)
        let recorder = RecordingAccessibilityAnnouncer()
        let appState = AppState(
            storeActor: WorkoutLibraryStoreActor(store: store),
            importService: WorkoutImportService(),
            demSettingsStore: FileDEMTileSettingsStore(rootURL: library),
            accessibilityAnnouncer: recorder
        )
        return (appState, store, recorder)
    }

    private func waitForPass(_ appState: AppState) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .finished = appState.demCorrectionPassState { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the elevation pass did not finish")
    }

    /// A 3×3 block of 4-pixel Terrarium tiles around (2131, 1450) at zoom 12.
    private func writeTileBlock(height: Float) throws -> URL {
        let folder = root.appendingPathComponent("tiles", isDirectory: true)
        for x in 2_130...2_132 {
            let column = folder.appendingPathComponent("12/\(x)", isDirectory: true)
            try FileManager.default.createDirectory(at: column, withIntermediateDirectories: true)
            for y in 1_449...1_451 {
                try terrariumPNG(height: height).write(to: column.appendingPathComponent("\(y).png"))
            }
        }
        return folder
    }

    private func terrariumPNG(height: Float) throws -> Data {
        let value = Double(height) + 32_768
        let whole = Int(value.rounded(.down))
        let pixel: [UInt8] = [UInt8(whole / 256), UInt8(whole % 256), UInt8((value - Double(whole)) * 256), 255]
        let bytes = Array((0..<16).map { _ in pixel }.joined())
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let buffer = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: bytes.count)
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A short run inside tile (2131, 1450) with recorded altitude from an
    /// unstated sensor.
    private func writeGPX() throws -> URL {
        var points = ""
        for index in 0..<30 {
            let latitude = 46.4400 + Double(index) * 0.0002
            let time = Date(timeIntervalSince1970: 1_767_225_600 + Double(index) * 8)
            points += "<trkpt lat=\"\(latitude)\" lon=\"7.3000\"><ele>100</ele><time>\(ISO8601DateFormatter().string(from: time))</time></trkpt>\n"
        }
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RunPlayTest"><trk><name>Run</name><trkseg>
        \(points)</trkseg></trk></gpx>
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run.gpx")
        try Data(gpx.utf8).write(to: url)
        return url
    }
}
