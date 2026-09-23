import Foundation

/// The DEM tile folder the user chose and how it is used. Local-only: RunPlay
/// Studio reads tiles the user downloaded and never downloads any itself.
public struct DEMTileSettings: Hashable, Sendable {
    /// The chosen folder, or `nil` before the user chooses one.
    public var folder: DEMTileFolder?
    /// Correct each new import's elevation as it is imported. Has no effect
    /// without a folder; correcting the existing library is always an explicit
    /// action.
    public var correctsNewImports: Bool

    public init(folder: DEMTileFolder? = nil, correctsNewImports: Bool = true) {
        self.folder = folder
        self.correctsNewImports = correctsNewImports
    }

    /// The tile set corrections read now; `nil` without a folder.
    public var tileSet: DEMTileSetIdentity? {
        folder?.tileSet
    }

    /// Whether a new import should be corrected as it is imported.
    public var correctsImports: Bool {
        correctsNewImports && folder != nil
    }
}

/// A folder of `z/x/y` DEM tiles the user chose.
public struct DEMTileFolder: Hashable, Sendable {
    /// Minted each time the user chooses a folder, so corrections made from an
    /// earlier choice read as stale; never a path.
    public var id: UUID
    /// The folder's name, for display only.
    public var displayName: String
    /// Opaque platform data that reopens the folder across launches.
    public var bookmark: Data
    /// Zoom levels the folder held when it was scanned, ascending.
    public var availableZooms: [Int]
    /// The zoom corrections read.
    public var zoom: Int
    /// Tile width and height in pixels at `zoom`.
    public var tileSize: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data,
        availableZooms: [Int],
        zoom: Int,
        tileSize: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.availableZooms = availableZooms
        self.zoom = zoom
        self.tileSize = tileSize
    }

    public var tileSet: DEMTileSetIdentity {
        DEMTileSetIdentity(folderID: id, zoom: zoom, tileSize: tileSize)
    }
}

extension DEMTileFolder: Codable {}

extension DEMTileSettings: Codable {
    /// Written into every file so a later layout can migrate this one.
    static let currentVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version, folder, correctsNewImports
    }

    /// Tolerant: a missing flag reads as on, and a folder this build cannot
    /// read is dropped rather than failing the settings, so the user chooses
    /// the folder again instead of losing every setting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = (try? container.decodeIfPresent(DEMTileFolder.self, forKey: .folder)) ?? nil
        correctsNewImports = (try? container.decodeIfPresent(Bool.self, forKey: .correctsNewImports)) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encode(correctsNewImports, forKey: .correctsNewImports)
    }
}
