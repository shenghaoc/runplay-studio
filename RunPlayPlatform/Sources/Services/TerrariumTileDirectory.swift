import CoreGraphics
import Foundation
import ImageIO
import RunPlayCore

/// A folder of Terrarium PNG DEM tiles laid out `z/x/y.png`, with `y` counted
/// from the north (slippy-map folders, not TMS), read with ImageIO.
///
/// Terrarium stores height in metres across the red, green and blue channels
/// as `(R × 256 + G + B / 256) − 32768`, exact in single precision. Only 8-bit
/// RGB or RGBA PNGs of exactly the tile set's size decode; a present tile in
/// any other form is unreadable, and a pixel that is not fully opaque has no
/// height. The pixel bytes are read as stored, never drawn, so no colour
/// management or gamma touches them. Files are local; nothing is downloaded.
public final class TerrariumTileDirectory: DEMTileSource, @unchecked Sendable {
    /// A tile file larger than this is unreadable. Terrarium tiles are well
    /// under a megabyte even at 512 pixels.
    public static let maximumTileFileBytes = 16 << 20

    public let tileSet: DEMTileSetIdentity
    public let rootURL: URL
    private let cache: DecodedTileCache

    /// - Parameter cacheBytes: decoded heights kept between corrections, so a
    ///   library pass over runs in one area decodes each tile once.
    public init(rootURL: URL, tileSet: DEMTileSetIdentity, cacheBytes: Int = 64 << 20) {
        self.rootURL = rootURL
        self.tileSet = tileSet
        self.cache = DecodedTileCache(capacityBytes: cacheBytes)
    }

    public func loadTiles(
        _ keys: [DEMTileKey],
        isCancelled: @Sendable () -> Bool
    ) throws -> DEMTileLoadResult {
        var result = DEMTileLoadResult()
        for key in keys {
            if isCancelled() { throw CancellationError() }
            if let heights = cache.heights(for: key) {
                result.tiles.append(DEMDecodedTile(key: key, heightsMeters: heights))
                continue
            }
            let url = tileURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let heights = Self.readTile(at: url, tileSize: tileSet.tileSize) else {
                result.unreadableTiles.append(key)
                continue
            }
            cache.insert(heights, for: key)
            result.tiles.append(DEMDecodedTile(key: key, heightsMeters: heights))
        }
        return result
    }

    /// `<root>/<zoom>/<x>/<y>.png`, built from integers only.
    func tileURL(for key: DEMTileKey) -> URL {
        rootURL
            .appendingPathComponent(String(tileSet.zoom), isDirectory: true)
            .appendingPathComponent(String(key.x), isDirectory: true)
            .appendingPathComponent("\(key.y).png", isDirectory: false)
    }

    /// Decoded tiles served from memory rather than decoded from disk.
    var cachedTileCount: Int { cache.count }

    // MARK: - Scanning a chosen folder

    /// Zoom levels the folder has a directory for, ascending: names that are
    /// plain decimal integers the engine can sample.
    public static func availableZooms(in rootURL: URL) -> [Int] {
        integerNames(in: rootURL, as: \.isDirectory)
            .filter { (0...24).contains($0) }
            .sorted()
    }

    /// The tile size at `zoom`, from the first of up to `probeLimit` tiles that
    /// decodes as a square Terrarium tile whose side is a power of two;
    /// `nil` when none does. Buffered 260- and 516-pixel Terrarium variants
    /// overlap their neighbours by two pixels on each edge, so reading them
    /// as a plain grid would misplace every height; they never qualify.
    public static func tileSize(in rootURL: URL, zoom: Int, probeLimit: Int = 8) -> Int? {
        let zoomURL = rootURL.appendingPathComponent(String(zoom), isDirectory: true)
        var probed = 0
        for x in integerNames(in: zoomURL, as: \.isDirectory).sorted() {
            let columnURL = zoomURL.appendingPathComponent(String(x), isDirectory: true)
            for y in pngTileRows(in: columnURL).sorted() {
                guard probed < probeLimit else { return nil }
                probed += 1
                let url = columnURL.appendingPathComponent("\(y).png", isDirectory: false)
                if let size = squareSize(ofImageAt: url), readTile(at: url, tileSize: size) != nil {
                    return size
                }
            }
        }
        return nil
    }

    private static func integerNames(in directory: URL, as kind: KeyPath<URLResourceValues, Bool?>) -> [Int] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?[keyPath: kind] == true else { return nil }
            return canonicalInteger(url.lastPathComponent)
        }
    }

    private static func pngTileRows(in columnURL: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: columnURL.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".png") else { return nil }
            return canonicalInteger(String(name.dropLast(4)))
        }
    }

    /// A non-negative decimal integer written the one way `String(Int)` would.
    static func canonicalInteger(_ name: String) -> Int? {
        guard let value = Int(name), value >= 0, String(value) == name else { return nil }
        return value
    }

    private static func squareSize(ofImageAt url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == height,
              (2...4_096).contains(width),
              width & (width - 1) == 0
        else {
            return nil
        }
        return width
    }

    // MARK: - Decoding

    static func readTile(at url: URL, tileSize: Int) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumTileFileBytes
        else {
            return nil
        }
        return decodeTerrarium(data, tileSize: tileSize)
    }

    static func decodeTerrarium(_ data: Data, tileSize: Int) -> [Float]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              (CGImageSourceGetType(source) as String?) == "public.png",
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == tileSize,
              image.height == tileSize,
              image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb,
              let layout = PixelLayout(image),
              let pixels = image.dataProvider?.data,
              image.bytesPerRow >= tileSize * layout.bytesPerPixel,
              CFDataGetLength(pixels) >= image.bytesPerRow * tileSize,
              let base = CFDataGetBytePtr(pixels)
        else {
            return nil
        }

        var heights: [Float] = []
        heights.reserveCapacity(tileSize * tileSize)
        for row in 0..<tileSize {
            let rowStart = base + row * image.bytesPerRow
            for column in 0..<tileSize {
                let pixel = rowStart + column * layout.bytesPerPixel
                if let alpha = layout.alpha, pixel[alpha] != 255 {
                    heights.append(.nan)
                    continue
                }
                // Every step is exact in Float: at most 16 integer and 8
                // fractional bits.
                let whole = Float(pixel[layout.red]) * 256 + Float(pixel[layout.green])
                let height = whole + Float(pixel[layout.blue]) / 256 - 32_768
                heights.append(height)
            }
        }
        withExtendedLifetime(pixels) {}
        return heights
    }

    /// Where red, green, blue and alpha sit in one decoded pixel.
    struct PixelLayout: Equatable {
        let bytesPerPixel: Int
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int?

        init?(_ image: CGImage) {
            self.init(
                bitsPerPixel: image.bitsPerPixel,
                alphaInfo: image.alphaInfo,
                byteOrder: image.byteOrderInfo
            )
        }

        init?(bitsPerPixel: Int, alphaInfo: CGImageAlphaInfo, byteOrder: CGImageByteOrderInfo) {
            let little = byteOrder == .order32Little
            guard byteOrder == .orderDefault || byteOrder == .order32Big || little else { return nil }
            switch (bitsPerPixel, alphaInfo) {
            case (24, .none) where !little:
                (bytesPerPixel, red, green, blue, alpha) = (3, 0, 1, 2, nil)
            case (32, .noneSkipLast):
                (bytesPerPixel, red, green, blue, alpha) = little ? (4, 3, 2, 1, nil) : (4, 0, 1, 2, nil)
            case (32, .last), (32, .premultipliedLast):
                (bytesPerPixel, red, green, blue, alpha) = little ? (4, 3, 2, 1, 0) : (4, 0, 1, 2, 3)
            case (32, .noneSkipFirst):
                (bytesPerPixel, red, green, blue, alpha) = little ? (4, 2, 1, 0, nil) : (4, 1, 2, 3, nil)
            case (32, .first), (32, .premultipliedFirst):
                (bytesPerPixel, red, green, blue, alpha) = little ? (4, 2, 1, 0, 3) : (4, 1, 2, 3, 0)
            default:
                return nil
            }
        }
    }
}

/// Decoded tiles, least recently used evicted first once over capacity.
final class DecodedTileCache: @unchecked Sendable {
    private let lock = NSLock()
    private let capacityBytes: Int
    private var entries: [DEMTileKey: (heights: [Float], lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var storedBytes = 0

    init(capacityBytes: Int) {
        self.capacityBytes = max(0, capacityBytes)
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    func heights(for key: DEMTileKey) -> [Float]? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            clock += 1
            entries[key] = (entry.heights, clock)
            return entry.heights
        }
    }

    func insert(_ heights: [Float], for key: DEMTileKey) {
        let bytes = heights.count * MemoryLayout<Float>.size
        lock.withLock {
            guard bytes <= capacityBytes, entries[key] == nil else { return }
            while storedBytes + bytes > capacityBytes,
                  let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                storedBytes -= oldest.value.heights.count * MemoryLayout<Float>.size
                entries.removeValue(forKey: oldest.key)
            }
            clock += 1
            entries[key] = (heights, clock)
            storedBytes += bytes
        }
    }
}
