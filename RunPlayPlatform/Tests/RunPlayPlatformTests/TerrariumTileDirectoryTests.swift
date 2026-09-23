import CoreGraphics
import Foundation
import ImageIO
import XCTest
import zlib
import RunPlayCore
@testable import RunPlayPlatform

/// Terrarium PNG tiles built byte by byte in the test, so every chunk and
/// pixel format is exactly what the decoder sees.
final class TerrariumTileDirectoryTests: XCTestCase {
    private var root: URL!
    private let tileSet = DEMTileSetIdentity(folderID: UUID(), zoom: 12, tileSize: 4)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerrariumTileDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Decoding

    func testHeightsDecodeExactlyRowByRowFromTheNorthWest() throws {
        let heights: [Float] = (0..<16).map { -432.25 + Float($0) * 611.5 + Float($0 % 3) / 256 }
        let png = TerrariumPNG.rgb(size: 4, heights: heights)

        XCTAssertEqual(TerrariumTileDirectory.decodeTerrarium(png, tileSize: 4), heights)
    }

    func testColourChunksNeverChangeHeights() throws {
        let heights: [Float] = (0..<16).map { 8_848 - Float($0) * 97.75 }
        for chunk in [TerrariumPNG.gammaChunk(45_455), TerrariumPNG.gammaChunk(100_000), TerrariumPNG.sRGBChunk] {
            let png = TerrariumPNG.rgb(size: 4, heights: heights, ancillary: [chunk])
            XCTAssertEqual(TerrariumTileDirectory.decodeTerrarium(png, tileSize: 4), heights)
        }
    }

    func testTransparentPixelsHaveNoHeight() throws {
        let png = TerrariumPNG.rgba(size: 4, heights: Array(repeating: 250, count: 16)) { $0 == 5 ? 0 : ($0 == 6 ? 254 : 255) }
        let decoded = try XCTUnwrap(TerrariumTileDirectory.decodeTerrarium(png, tileSize: 4))

        XCTAssertTrue(decoded[5].isNaN)
        XCTAssertTrue(decoded[6].isNaN)
        XCTAssertEqual(decoded.filter { $0 == 250 }.count, 14)
    }

    func testTilesOfAnyOtherShapeAreUnreadable() throws {
        let rgb = TerrariumPNG.rgb(size: 4, heights: Array(repeating: 10, count: 16))
        let cases: [(String, Data, Int)] = [
            ("wrong size", rgb, 8),
            ("16-bit", TerrariumPNG.png(size: 4, colorType: 2, bitDepth: 16, pixel: { _ in [0, 1, 0, 2, 0, 3] }), 4),
            ("grayscale", TerrariumPNG.png(size: 4, colorType: 0, bitDepth: 8, pixel: { _ in [9] }), 4),
            ("not an image", Data("x,y,height".utf8), 4),
            ("a JPEG", try TerrariumPNG.jpeg(size: 4), 4),
        ]
        for (name, data, size) in cases {
            XCTAssertNil(TerrariumTileDirectory.decodeTerrarium(data, tileSize: size), name)
        }
    }

    func testEveryByteOrderAndAlphaLayoutLocatesTheChannels() {
        typealias Layout = TerrariumTileDirectory.PixelLayout
        let big: CGImageByteOrderInfo = .order32Big
        let little: CGImageByteOrderInfo = .order32Little
        let expectations: [(Int, CGImageAlphaInfo, CGImageByteOrderInfo, [Int?])] = [
            (24, .none, .orderDefault, [0, 1, 2, nil]),
            (32, .noneSkipLast, big, [0, 1, 2, nil]),
            (32, .noneSkipLast, little, [3, 2, 1, nil]),
            (32, .last, .orderDefault, [0, 1, 2, 3]),
            (32, .premultipliedLast, little, [3, 2, 1, 0]),
            (32, .noneSkipFirst, big, [1, 2, 3, nil]),
            (32, .first, little, [2, 1, 0, 3]),
        ]
        for (bits, alpha, order, channels) in expectations {
            let layout = Layout(bitsPerPixel: bits, alphaInfo: alpha, byteOrder: order)
            XCTAssertEqual(layout.map { [$0.red, $0.green, $0.blue, $0.alpha] }, channels, "\(bits) \(alpha.rawValue) \(order.rawValue)")
        }
        XCTAssertNil(Layout(bitsPerPixel: 24, alphaInfo: .none, byteOrder: little))
        XCTAssertNil(Layout(bitsPerPixel: 32, alphaInfo: .alphaOnly, byteOrder: big))
        XCTAssertNil(Layout(bitsPerPixel: 48, alphaInfo: .none, byteOrder: .orderDefault))
        XCTAssertNil(Layout(bitsPerPixel: 32, alphaInfo: .last, byteOrder: .order16Little))
    }

    // MARK: - Loading tiles from the folder

    func testLoadingReportsPresentMissingAndUnreadableTiles() throws {
        let present = DEMTileKey(x: 2_130, y: 1_450)
        let unreadable = DEMTileKey(x: 2_131, y: 1_450)
        let missing = DEMTileKey(x: 2_130, y: 1_451)
        try writeTile(present, TerrariumPNG.rgb(size: 4, heights: Array(repeating: 321.5, count: 16)))
        try writeTile(unreadable, Data("not a tile".utf8))
        let directory = TerrariumTileDirectory(rootURL: root, tileSet: tileSet)

        let result = try directory.loadTiles([present, unreadable, missing], isCancelled: { false })

        XCTAssertEqual(result.tiles.map(\.key), [present])
        XCTAssertEqual(result.tiles.first?.heightsMeters, Array(repeating: 321.5, count: 16))
        XCTAssertEqual(result.unreadableTiles, [unreadable])
        XCTAssertEqual(
            directory.tileURL(for: present).path,
            root.appendingPathComponent("12/2130/1450.png").path
        )
    }

    func testDecodedTilesAreServedFromMemoryUntilEvicted() throws {
        let key = DEMTileKey(x: 5, y: 6)
        try writeTile(key, TerrariumPNG.rgb(size: 4, heights: Array(repeating: 7, count: 16)))
        let directory = TerrariumTileDirectory(rootURL: root, tileSet: tileSet)
        _ = try directory.loadTiles([key], isCancelled: { false })
        try FileManager.default.removeItem(at: directory.tileURL(for: key))

        let again = try directory.loadTiles([key], isCancelled: { false })
        XCTAssertEqual(again.tiles.first?.heightsMeters, Array(repeating: 7, count: 16))

        let cache = DecodedTileCache(capacityBytes: 2 * 16 * MemoryLayout<Float>.size)
        let keys = (0..<3).map { DEMTileKey(x: $0, y: 0) }
        cache.insert(Array(repeating: 0, count: 16), for: keys[0])
        cache.insert(Array(repeating: 1, count: 16), for: keys[1])
        _ = cache.heights(for: keys[0])
        cache.insert(Array(repeating: 2, count: 16), for: keys[2])
        XCTAssertNotNil(cache.heights(for: keys[0]), "recently used")
        XCTAssertNil(cache.heights(for: keys[1]), "least recently used goes first")
        XCTAssertEqual(cache.count, 2)
    }

    func testLoadingStopsWhenCancelled() throws {
        let directory = TerrariumTileDirectory(rootURL: root, tileSet: tileSet)
        XCTAssertThrowsError(try directory.loadTiles([DEMTileKey(x: 0, y: 0)], isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: - Choosing a folder

    func testScanningFindsIntegerZoomsAndTheirTileSize() throws {
        for name in ["12", "13", "012", "abc", "25"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("14"))
        try writeTile(DEMTileKey(x: 9, y: 9), TerrariumPNG.rgb(size: 4, heights: Array(repeating: 1, count: 16)))

        XCTAssertEqual(TerrariumTileDirectory.availableZooms(in: root), [12, 13])
        XCTAssertEqual(TerrariumTileDirectory.tileSize(in: root, zoom: 12), 4)
        XCTAssertNil(TerrariumTileDirectory.tileSize(in: root, zoom: 13), "no tile at zoom 13")

        // A buffered tile (2 pixels of overlap on each edge) is never read as a grid.
        try writeTile(DEMTileKey(x: 3, y: 3), TerrariumPNG.rgb(size: 6, heights: Array(repeating: 1, count: 36)), zoom: 13)
        XCTAssertNil(TerrariumTileDirectory.tileSize(in: root, zoom: 13), "6 = 2 + 2 × 2 buffered pixels")
        XCTAssertEqual(TerrariumTileDirectory.canonicalInteger("2130"), 2_130)
        XCTAssertNil(TerrariumTileDirectory.canonicalInteger("-1"))
        XCTAssertNil(TerrariumTileDirectory.canonicalInteger("07"))
    }

    func testDescribingAFolderPrefersZoomFourteenAndReopensItFromTheBookmark() throws {
        for zoom in [12, 14, 16] {
            let tile = TerrariumPNG.rgb(size: 4, heights: Array(repeating: Float(zoom), count: 16))
            try writeTile(DEMTileKey(x: 1, y: 1), tile, zoom: zoom)
        }
        let folder = try XCTUnwrap(DEMTileFolderAccess.describeFolder(at: root))
        XCTAssertEqual(folder.availableZooms, [12, 14, 16])
        XCTAssertEqual(folder.zoom, 14)
        XCTAssertEqual(folder.tileSize, 4)
        XCTAssertEqual(folder.displayName, root.lastPathComponent)

        let access = try DEMTileFolderAccess(folder: folder)
        XCTAssertEqual(access.directory.rootURL.standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(access.directory.tileSet, folder.tileSet)
        let loaded = try access.directory.loadTiles([DEMTileKey(x: 1, y: 1)], isCancelled: { false })
        XCTAssertEqual(loaded.tiles.first?.heightsMeters.first, 14)
    }

    func testDescribingFallsBackFromAnUnreadableDefaultZoomAndRejectsEmptyFolders() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(try DEMTileFolderAccess.describeFolder(at: root))

        try writeTile(DEMTileKey(x: 1, y: 1), Data("corrupt".utf8), zoom: 14)
        try writeTile(DEMTileKey(x: 1, y: 1), TerrariumPNG.rgb(size: 4, heights: Array(repeating: 3, count: 16)), zoom: 11)
        XCTAssertEqual(try DEMTileFolderAccess.describeFolder(at: root)?.zoom, 11)
    }

    // MARK: - End to end through the corrector

    func testCorrectorReadsAPNGTileFolder() throws {
        let zoom = 12
        let origin = DEMTileKey(x: 2_130, y: 1_450)
        let tiles = [origin, DEMTileKey(x: origin.x + 1, y: origin.y)]
        for key in tiles {
            try writeTile(key, TerrariumPNG.rgb(size: 4, heights: Array(repeating: 612.25, count: 16)), zoom: zoom)
        }
        let points = (0..<60).map { index -> RoutePoint in
            // West to east across the boundary between the two tiles.
            let x = (Double(origin.x) + 0.2 + 1.6 * Double(index) / 59) / 4_096
            let y = (Double(origin.y) + 0.5) / 4_096
            return RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index) * 20),
                latitude: atan(sinh(Double.pi * (1 - 2 * y))) * 180 / .pi,
                longitude: x * 360 - 180,
                altitudeMeters: 400
            )
        }
        var workout = RunWorkout(routePoints: points)
        try WorkoutAnalyzer().normalizeAndAnalyze(&workout, distancePolicy: .computeFromCoordinates)
        let directory = TerrariumTileDirectory(
            rootURL: root,
            tileSet: DEMTileSetIdentity(folderID: UUID(), zoom: zoom, tileSize: 4)
        )

        let record = try DEMElevationCorrector().correct(&workout, using: directory)

        XCTAssertEqual(record.outcome, .applied)
        XCTAssertEqual(record.coverage.plannedTileCount, 2)
        XCTAssertEqual(record.coverage.sampledPointCount, workout.routePoints.count)
        XCTAssertTrue(workout.routePoints.allSatisfy { $0.demAltitudeMeters == 612.25 })
    }

    // MARK: - Helpers

    private func writeTile(_ key: DEMTileKey, _ data: Data, zoom: Int = 12) throws {
        let directory = root
            .appendingPathComponent(String(zoom), isDirectory: true)
            .appendingPathComponent(String(key.x), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(key.y).png"))
    }
}

/// Minimal PNG writer: signature, IHDR, optional ancillary chunks, one zlib
/// IDAT with filter byte 0 on every row, IEND.
enum TerrariumPNG {
    static func rgb(size: Int, heights: [Float], ancillary: [Data] = []) -> Data {
        png(size: size, colorType: 2, bitDepth: 8, ancillary: ancillary) { encode(heights[$0]) }
    }

    static func rgba(size: Int, heights: [Float], alpha: (Int) -> UInt8) -> Data {
        png(size: size, colorType: 6, bitDepth: 8) { encode(heights[$0]) + [alpha($0)] }
    }

    /// Terrarium: `value = height + 32768`, R = value / 256, G = value % 256,
    /// B = fraction × 256.
    static func encode(_ height: Float) -> [UInt8] {
        let value = Double(height) + 32_768
        let whole = value.rounded(.down)
        return [UInt8(Int(whole) / 256), UInt8(Int(whole) % 256), UInt8((value - whole) * 256)]
    }

    static func png(
        size: Int,
        colorType: UInt8,
        bitDepth: UInt8,
        ancillary: [Data] = [],
        pixel: (Int) -> [UInt8]
    ) -> Data {
        var raw: [UInt8] = []
        for row in 0..<size {
            raw.append(0)
            for column in 0..<size { raw += pixel(row * size + column) }
        }
        var compressedLength = compressBound(uLong(raw.count))
        var compressed = [UInt8](repeating: 0, count: Int(compressedLength))
        _ = compress(&compressed, &compressedLength, raw, uLong(raw.count))
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data += chunk("IHDR", bigEndian(UInt32(size)) + bigEndian(UInt32(size)) + [bitDepth, colorType, 0, 0, 0])
        for extra in ancillary { data += extra }
        data += chunk("IDAT", Array(compressed.prefix(Int(compressedLength))))
        data += chunk("IEND", [])
        return data
    }

    static func gammaChunk(_ gamma: UInt32) -> Data { chunk("gAMA", bigEndian(gamma)) }
    static let sRGBChunk = chunk("sRGB", [0])

    static func jpeg(size: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let typed = Array(type.utf8) + body
        let checksum = UInt32(typed.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
        return Data(bigEndian(UInt32(body.count)) + typed + bigEndian(checksum))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Every tile present at one height, for import tests.
final class UniformDEMTiles: DEMTileSource, @unchecked Sendable {
    let tileSet = DEMTileSetIdentity(folderID: UUID(), zoom: 12, tileSize: 4)
    let height: Float

    init(height: Float) {
        self.height = height
    }

    func loadTiles(_ keys: [DEMTileKey], isCancelled: @Sendable () -> Bool) throws -> DEMTileLoadResult {
        DEMTileLoadResult(tiles: keys.map { DEMDecodedTile(key: $0, heightsMeters: Array(repeating: height, count: 16)) })
    }
}
