import Foundation
import XCTest
@testable import RunPlayCore

final class DEMTileSettingsStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DEMTileSettingsStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: rootURL)
        super.tearDown()
    }

    private let folder = DEMTileFolder(
        id: UUID(uuidString: "3C1E9A57-2B7D-4E0F-9C44-8A1D2E3F4B5C")!,
        displayName: "Terrarium z12–z14",
        bookmark: Data([0x62, 0x6F, 0x6F, 0x6B, 0x00, 0xFF]),
        availableZooms: [12, 13, 14],
        zoom: 13,
        tileSize: 256
    )

    func testFirstRunHasNoFolderAndCorrectsNothing() {
        let store = FileDEMTileSettingsStore(rootURL: rootURL)
        XCTAssertEqual(store.load(), .missing)

        let settings = store.loadOrDefault()
        XCTAssertNil(settings.folder)
        XCTAssertTrue(settings.correctsNewImports, "on by default once a folder is chosen")
        XCTAssertFalse(settings.correctsImports, "but nothing to correct with yet")
        XCTAssertNil(settings.tileSet)
    }

    func testSettingsRoundTripBesideTheManifest() throws {
        let store = FileDEMTileSettingsStore(rootURL: rootURL)
        let settings = DEMTileSettings(folder: folder, correctsNewImports: false)
        try store.save(settings)

        XCTAssertEqual(store.load(), .loaded(settings))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("dem-tiles.json").path))
        XCTAssertEqual(settings.tileSet, DEMTileSetIdentity(folderID: folder.id, zoom: 13, tileSize: 256))
        XCTAssertFalse(settings.correctsImports)
        XCTAssertTrue(DEMTileSettings(folder: folder).correctsImports)
    }

    func testFileRecordsItsVersionAndNoPath() throws {
        let store = FileDEMTileSettingsStore(rootURL: rootURL)
        try store.save(DEMTileSettings(folder: folder))
        let data = try Data(contentsOf: rootURL.appendingPathComponent("dem-tiles.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["version"] as? Int, 1)
        let folderObject = try XCTUnwrap(object["folder"] as? [String: Any])
        XCTAssertEqual(
            Set(folderObject.keys),
            ["id", "displayName", "bookmark", "availableZooms", "zoom", "tileSize"],
            "the folder is reopened from its bookmark; no path is stored"
        )
    }

    func testDamagedFileLoadsAsDefaults() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: rootURL.appendingPathComponent("dem-tiles.json"))
        let store = FileDEMTileSettingsStore(rootURL: rootURL)

        XCTAssertEqual(store.load(), .corrupt)
        XCTAssertEqual(store.loadOrDefault(), DEMTileSettings())
    }

    func testDefaultZoomIsTheFinestUpToFourteen() {
        XCTAssertEqual(DEMTileFolder.defaultZoom(from: [10, 12, 13, 14, 15, 16]), 14)
        XCTAssertEqual(DEMTileFolder.defaultZoom(from: [9, 11]), 11)
        XCTAssertEqual(DEMTileFolder.defaultZoom(from: [15, 17]), 15, "only finer zooms: the coarsest of them")
        XCTAssertNil(DEMTileFolder.defaultZoom(from: []))
    }

    func testDecodingToleratesLaterAndPartialFiles() throws {
        let later = Data("""
        {"version": 7, "correctsNewImports": false, "somethingNew": [1, 2],
         "folder": {"id": "3C1E9A57-2B7D-4E0F-9C44-8A1D2E3F4B5C", "displayName": "Tiles",
                    "bookmark": "Ym9vaw==", "availableZooms": [12], "zoom": 12, "tileSize": 512,
                    "format": "terrarium-webp"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(DEMTileSettings.self, from: later)
        XCTAssertEqual(decoded.folder?.tileSize, 512)
        XCTAssertFalse(decoded.correctsNewImports)

        let unreadableFolder = Data("""
        {"version": 1, "correctsNewImports": false, "folder": {"id": 12}}
        """.utf8)
        let dropped = try JSONDecoder().decode(DEMTileSettings.self, from: unreadableFolder)
        XCTAssertNil(dropped.folder, "the folder is chosen again; the flag survives")
        XCTAssertFalse(dropped.correctsNewImports)

        let empty = try JSONDecoder().decode(DEMTileSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, DEMTileSettings())
    }
}
