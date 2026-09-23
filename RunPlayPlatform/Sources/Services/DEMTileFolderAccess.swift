import Foundation
import RunPlayCore

/// The chosen DEM tile folder, opened: its bookmark resolved, its security
/// scope held, and its tiles readable for as long as this value lives.
///
/// Resolution reuses the watch folders' stale-tolerant bookmarks: a folder
/// that moved still opens, and `refreshedBookmark` carries fresh bookmark
/// data for the caller to save into the settings.
public final class DEMTileFolderAccess: @unchecked Sendable {
    public let directory: TerrariumTileDirectory
    /// New bookmark data when the stored bookmark was stale; `nil` otherwise.
    public let refreshedBookmark: Data?
    private let scope: SecurityScopedBookmarkStore.ScopedAccess?

    public init(
        folder: DEMTileFolder,
        bookmarks: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore()
    ) throws {
        let resolved = try bookmarks.resolve(folder.bookmark)
        // Outside App Sandbox no scope is needed and `beginAccess` may
        // decline; the folder is still readable.
        scope = bookmarks.beginAccess(to: resolved.url)
        refreshedBookmark = resolved.wasStale ? try? bookmarks.createBookmark(for: resolved.url) : nil
        directory = TerrariumTileDirectory(rootURL: resolved.url, tileSet: folder.tileSet)
    }

    deinit {
        scope?.stop()
    }

    /// Scans a folder the user just chose and describes it for the settings,
    /// with a bookmark to reopen it. The zoom is the default zoom when its
    /// tiles decode, else the next zoom in the same order of preference;
    /// `nil` when no zoom holds a decodable Terrarium tile.
    public static func describeFolder(
        at url: URL,
        id: UUID = UUID(),
        bookmarks: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore()
    ) throws -> DEMTileFolder? {
        let zooms = TerrariumTileDirectory.availableZooms(in: url)
        let limit = DEMTileFolder.preferredMaximumZoom
        let preference = zooms.filter { $0 <= limit }.sorted(by: >) + zooms.filter { $0 > limit }.sorted()
        for zoom in preference {
            guard let tileSize = TerrariumTileDirectory.tileSize(in: url, zoom: zoom) else { continue }
            return DEMTileFolder(
                id: id,
                displayName: url.lastPathComponent,
                bookmark: try bookmarks.createBookmark(for: url),
                availableZooms: zooms,
                zoom: zoom,
                tileSize: tileSize
            )
        }
        return nil
    }
}
