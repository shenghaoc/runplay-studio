import Foundation
import RunPlayCore

/// Creates and resolves security-scoped bookmarks for watched folders.
///
/// The app currently ships without App Sandbox, where these APIs are
/// functional no-ops that still round-trip correctly; they become load
/// bearing the moment sandbox entitlements land (planned follow-up). Using
/// them now means persistence already survives that switch unchanged.
///
/// Bookmark resolution is *stale-tolerant*: a bookmark whose target moved
/// (volume renamed, folder relocated) is re-resolved against the live
/// filesystem, and `ResolvedFolder` reports the current path so callers can
/// update their display without re-prompting.
public struct SecurityScopedBookmarkStore: Sendable {

    public struct ResolvedFolder: Equatable, Sendable {
        public let url: URL
        /// True when resolution needed a stale-bookmark round-trip; callers
        /// may persist the fresh bookmark data.
        public let wasStale: Bool

        public init(url: URL, wasStale: Bool) {
            self.url = url
            self.wasStale = wasStale
        }
    }

    public enum BookmarkError: Error, Equatable, Sendable {
        /// Bookmark creation failed (folder vanished, sandbox refused).
        case creationFailed
        /// Bookmark data could not be resolved to a folder URL.
        case resolutionFailed
    }

    public init() {}

    /// Create a security-scoped bookmark for `folderURL`.
    ///
    /// Throws `creationFailed` when the system cannot produce bookmark data.
    public func createBookmark(for folderURL: URL) throws -> Data {
        do {
            return try folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.creationFailed
        }
    }

    /// Resolve bookmark data back to a folder URL.
    ///
    /// Uses stale-tolerant resolution: when the system reports the bookmark
    /// stale, the returned URL still points at the current target and
    /// `wasStale` is true so the caller can persist the refreshed bookmark.
    public func resolve(_ bookmarkData: Data) throws -> ResolvedFolder {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw BookmarkError.resolutionFailed
        }
        return ResolvedFolder(url: url, wasStale: stale)
    }

    /// Begin accessing a resolved folder's security scope.
    ///
    /// Returns an opaque handle that stops access on release, matching the
    /// repo's `SecurityScopedURL` lifetime convention: scope is held for the
    /// whole time the folder is watched, not per import.
    public func beginAccess(to folderURL: URL) -> ScopedAccess? {
        guard folderURL.startAccessingSecurityScopedResource() else {
            return nil
        }
        return ScopedAccess(folderURL: folderURL)
    }

    /// Holds one folder's security scope until released.
    public final class ScopedAccess: @unchecked Sendable {
        private let folderURL: URL
        private var released = false

        fileprivate init(folderURL: URL) {
            self.folderURL = folderURL
        }

        deinit {
            stop()
        }

        public func stop() {
            guard !released else { return }
            released = true
            folderURL.stopAccessingSecurityScopedResource()
        }
    }
}

/// Watched-directory event delivery.
///
/// The coordinator's periodic poll stays the authoritative detector (FSEvents
/// coalescing and mounted-volume edge cases make event streams advisory). A
/// watcher's job is to wake the poll early when files arrive, so imports feel
/// immediate without trusting the stream alone.
public protocol DirectoryWatching: Sendable {
    /// Start watching `directoryURL`. Events are coalesced; the handler may
    /// fire zero or more times per filesystem change and must never block.
    func start(
        directoryURL: URL,
        onEvent: @escaping @Sendable () -> Void
    ) -> DirectoryWatchHandle?
}

/// Opaque handle for one active watch.
public protocol DirectoryWatchHandle: Sendable {
    /// Stop delivering events and release filesystem resources.
    func cancel()
}

/// DispatchSource-backed directory watcher using the directory-FD `.write`
/// event mask: the directory's own contents changed.
public struct DispatchSourceDirectoryWatcher: DirectoryWatching {

    public init() {}

    public func start(
        directoryURL: URL,
        onEvent: @escaping @Sendable () -> Void
    ) -> DirectoryWatchHandle? {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue(label: "runplay.watchfolder.events", qos: .utility)
        )
        let handle = Handle(fd: fd, source: source)
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler { [weak handle] in
            handle?.closeFD()
        }
        source.resume()
        return handle
    }

    private final class Handle: DirectoryWatchHandle, @unchecked Sendable {
        private let fd: Int32
        private let source: DispatchSourceFileSystemObject
        private var closed = false

        init(fd: Int32, source: DispatchSourceFileSystemObject) {
            self.fd = fd
            self.source = source
        }

        func cancel() {
            source.cancel()
        }

        fileprivate func closeFD() {
            guard !closed else { return }
            closed = true
            close(fd)
        }
    }
}
