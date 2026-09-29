import Foundation
import ZIPFoundation
import RunPlayCore

// MARK: - Errors

/// Failures specific to reading an Apple Health `export.zip`.
public enum AppleHealthArchiveError: Error, LocalizedError, Equatable, Sendable {

    /// The URL is not a local file. Apple Health exports are read from disk;
    /// nothing here fetches anything.
    case notALocalFile

    /// The file could not be opened as a ZIP archive.
    case cannotOpenArchive(String)

    /// The archive file is larger than the security policy allows.
    case archiveTooLarge(limitBytes: Int64)

    /// The archive holds more entries than the security policy allows.
    case tooManyEntries(limit: Int)

    /// No export document was found in the archive.
    case exportXMLNotFound

    /// An entry's uncompressed content exceeded the byte cap.
    case entryTooLarge(path: String, limitBytes: Int64)

    /// The requested entry is not a route file in this archive.
    case routeEntryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notALocalFile:
            return "Only local files can be read. Choose an export.zip saved on this Mac."
        case .cannotOpenArchive(let detail):
            return "This file could not be opened as a ZIP archive. \(detail)"
        case .archiveTooLarge(let limitBytes):
            return "This archive is larger than the \(Self.formatted(limitBytes)) limit."
        case .tooManyEntries(let limit):
            return "This archive holds more than \(limit) entries."
        case .exportXMLNotFound:
            return "This ZIP does not contain an Apple Health export. "
                + "It should hold \(AppleHealthExportParser.archiveRoot)/export.xml."
        case .entryTooLarge(let path, let limitBytes):
            return "\(path) is larger than the \(Self.formatted(limitBytes)) limit."
        case .routeEntryNotFound(let path):
            return "The archive has no route file at \(path)."
        }
    }

    private static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Result

/// Everything one read of `export.zip` produced.
public struct AppleHealthArchiveScanResult: Sendable {

    /// The streaming scan of the export document.
    public var scan: AppleHealthExportScan

    /// Candidates built from the scan, with duplicates already flagged.
    public var candidates: [AppleHealthWorkoutCandidate]

    /// Normalized archive path of the document that was read.
    public var exportXMLEntryPath: String

    /// True when the document was found only by case-insensitive match.
    public var usedCaseInsensitiveXMLLookup: Bool

    /// Uncompressed bytes of the document, as written to disk before parsing.
    public var uncompressedXMLBytes: Int64

    /// Entries the archive holds, including ones this reader ignores.
    public var entryCount: Int

    /// Archive entries under the export's `workout-routes` directory.
    public var routeEntryCount: Int

    /// Workouts naming a route the archive does not contain.
    ///
    /// Counted rather than resolved silently: a workout whose route is missing
    /// is still importable as a route-less run, but the user is entitled to know
    /// that its route was referenced and absent.
    public var unmatchedRouteReferenceCount: Int

    public init(
        scan: AppleHealthExportScan,
        candidates: [AppleHealthWorkoutCandidate],
        exportXMLEntryPath: String,
        usedCaseInsensitiveXMLLookup: Bool,
        uncompressedXMLBytes: Int64,
        entryCount: Int,
        routeEntryCount: Int,
        unmatchedRouteReferenceCount: Int
    ) {
        self.scan = scan
        self.candidates = candidates
        self.exportXMLEntryPath = exportXMLEntryPath
        self.usedCaseInsensitiveXMLLookup = usedCaseInsensitiveXMLLookup
        self.uncompressedXMLBytes = uncompressedXMLBytes
        self.entryCount = entryCount
        self.routeEntryCount = routeEntryCount
        self.unmatchedRouteReferenceCount = unmatchedRouteReferenceCount
    }
}

// MARK: - Service

/// Reads an Apple Health `export.zip` into a scan and its candidates.
///
/// This is the only type that opens the ZIP. `RunPlayCore` handles XML supplied
/// as a stream and never sees ZIPFoundation; every other layer asks this service
/// for archive content. That keeps the archive format in one place and keeps
/// `RunPlayCore` free of an archiving dependency.
///
/// The export document is extracted to a temporary file before parsing rather
/// than held in memory. Two facts make that the right trade: `ZIPFoundation`
/// extracts by push (`extract(_:consumer:)`) while the parser reads by pull
/// through an `InputStream`, and the parser's heart-rate ceiling fallback needs
/// to read the document twice. A file URL satisfies both and keeps memory
/// bounded regardless of how large the export is, which is the whole point of
/// streaming it. The file is deleted before this method returns.
public actor AppleHealthArchiveService {

    /// Finite limits for untrusted archives.
    public let policy: WorkoutArchiveSecurityPolicy

    /// Decompression and write chunk size.
    private static let extractionBufferSize = 64 * 1024

    public init(policy: WorkoutArchiveSecurityPolicy = .default) {
        self.policy = policy
    }

    /// Scan the archive and build candidates.
    ///
    /// - Parameters:
    ///   - archiveURL: A local `export.zip`.
    ///   - existingLibraryRuns: Windows of runs already stored, used to flag
    ///     incoming workouts that overlap something the user already has.
    ///   - isCancelled: Consulted between phases and during extraction. A
    ///     cancellation throws `CancellationError` and returns nothing, so a
    ///     caller never receives a partial scan.
    public func scan(
        archiveAt archiveURL: URL,
        existingLibraryRuns: [AppleHealthLibraryRunWindow] = [],
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> AppleHealthArchiveScanResult {
        guard archiveURL.isFileURL else { throw AppleHealthArchiveError.notALocalFile }

        let archive = try openArchive(archiveURL)
        let listing = try listEntries(in: archive)
        guard !isCancelled() else { throw CancellationError() }

        let document = try locateExportXML(in: listing)

        let temporaryURL = try extractToTemporaryFile(
            document.entry,
            path: document.path,
            from: archive,
            limitBytes: sourceByteLimit,
            isCancelled: isCancelled
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard !isCancelled() else { throw CancellationError() }
        let uncompressedBytes = fileSize(of: temporaryURL)

        // A file URL can be opened again, so the parser's ceiling fallback can
        // run its second pass without this service touching the archive twice.
        let scan = try AppleHealthExportParser().parse(
            openStream: {
                guard let stream = InputStream(url: temporaryURL) else {
                    throw AppleHealthArchiveError.cannotOpenArchive(
                        "the extracted export could not be reopened for reading"
                    )
                }
                return stream
            },
            isCancelled: isCancelled
        )

        let candidates = AppleHealthWorkoutCandidateBuilder.candidates(
            from: scan,
            existingLibraryRuns: existingLibraryRuns
        )
        let unmatched = candidates.count { candidate in
            guard let path = candidate.routeArchivePath else { return false }
            return !listing.routePathsLowercased.contains(path.lowercased())
        }

        return AppleHealthArchiveScanResult(
            scan: scan,
            candidates: candidates,
            exportXMLEntryPath: document.path,
            usedCaseInsensitiveXMLLookup: document.caseInsensitive,
            uncompressedXMLBytes: uncompressedBytes,
            entryCount: listing.entryCount,
            routeEntryCount: listing.routePathsLowercased.count,
            unmatchedRouteReferenceCount: unmatched
        )
    }

    /// Read one route file, by the archive-relative path a scan reported.
    ///
    /// The path must be a route file under the export's `workout-routes`
    /// directory. Restricting it keeps this from becoming a general
    /// "read any entry" API, which is the shape a path-traversal bug needs.
    public func routeGPXData(
        forArchivePath archivePath: String,
        archiveAt archiveURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> Data {
        guard archiveURL.isFileURL else { throw AppleHealthArchiveError.notALocalFile }

        let archive = try openArchive(archiveURL)
        let listing = try listEntries(in: archive)
        guard !isCancelled() else { throw CancellationError() }

        guard case .valid(let normalized) = WorkoutArchivePathValidator.validate(
            archivePath,
            maxLength: policy.maxPathLength
        ) else {
            throw AppleHealthArchiveError.routeEntryNotFound(archivePath)
        }
        guard Self.isRoutePath(normalized) else {
            throw AppleHealthArchiveError.routeEntryNotFound(archivePath)
        }
        guard let entry = entry(matching: normalized, in: listing) else {
            throw AppleHealthArchiveError.routeEntryNotFound(archivePath)
        }

        let limitBytes = sourceByteLimit
        guard entry.uncompressedSize <= UInt64(max(0, limitBytes)) else {
            throw AppleHealthArchiveError.entryTooLarge(
                path: normalized,
                limitBytes: limitBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(min(entry.uncompressedSize, UInt64(limitBytes))))
        _ = try archive.extract(entry, bufferSize: Self.extractionBufferSize) { chunk in
            guard Int64(data.count) + Int64(chunk.count) <= limitBytes else {
                throw AppleHealthArchiveError.entryTooLarge(
                    path: normalized,
                    limitBytes: limitBytes
                )
            }
            if isCancelled() { throw CancellationError() }
            data.append(chunk)
        }
        return data
    }

    // MARK: - Archive opening and listing

    /// The product limit on one source payload, applied to the export document.
    ///
    /// Shared with every other importer rather than restated, so the app accepts
    /// exactly one payload size everywhere.
    private var sourceByteLimit: Int64 {
        min(policy.maxUncompressedEntryBytes, Int64(WorkoutImportResourceLimits.maxSourceFileBytes))
    }

    private func openArchive(_ url: URL) throws -> Archive {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > policy.maxArchiveFileBytes {
            throw AppleHealthArchiveError.archiveTooLarge(limitBytes: policy.maxArchiveFileBytes)
        }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw AppleHealthArchiveError.cannotOpenArchive(error.localizedDescription)
        }
    }

    /// A validated, de-duplicated view of the archive's entries.
    private struct EntryListing {
        /// First entry per normalized path.
        var byPath: [String: Entry]
        /// Normalized paths in archive order.
        var paths: [String]
        /// Every entry the archive holds, ignored ones included.
        var entryCount: Int
        /// Lowercased normalized paths under the export's route directory.
        var routePathsLowercased: Set<String>
    }

    private func listEntries(in archive: Archive) throws -> EntryListing {
        var byPath: [String: Entry] = [:]
        var paths: [String] = []
        var routePaths: Set<String> = []
        var count = 0

        for entry in archive {
            count += 1
            if count > policy.maxEntryCount {
                throw AppleHealthArchiveError.tooManyEntries(limit: policy.maxEntryCount)
            }
            guard entry.type != .directory else { continue }

            // An entry name is untrusted input: a traversal path or an absolute
            // path is dropped here rather than resolved. `shouldIgnore` drops the
            // JPEG/HEIC/__MACOSX noise a real export carries.
            guard case .valid(let normalized) = WorkoutArchivePathValidator.validate(
                entry.path,
                maxLength: policy.maxPathLength
            ) else { continue }
            guard !WorkoutArchivePathValidator.shouldIgnore(normalized) else { continue }

            // Two entries can normalize to one path; the first wins so a later
            // duplicate cannot quietly replace an entry already listed.
            if byPath[normalized] == nil {
                byPath[normalized] = entry
                paths.append(normalized)
            }
            if Self.isRoutePath(normalized) {
                routePaths.insert(normalized.lowercased())
            }
        }

        return EntryListing(
            byPath: byPath,
            paths: paths,
            entryCount: count,
            routePathsLowercased: routePaths
        )
    }

    private func entry(matching normalizedPath: String, in listing: EntryListing) -> Entry? {
        if let exact = listing.byPath[normalizedPath] { return exact }
        let lowered = normalizedPath.lowercased()
        guard let path = listing.paths.first(where: { $0.lowercased() == lowered }) else {
            return nil
        }
        return listing.byPath[path]
    }

    private static func isRoutePath(_ normalizedPath: String) -> Bool {
        normalizedPath.hasPrefix("\(AppleHealthExportParser.archiveRoot)/workout-routes/")
    }

    // MARK: - Locating the export document

    private func locateExportXML(
        in listing: EntryListing
    ) throws -> (path: String, entry: Entry, caseInsensitive: Bool) {
        let expectedPath = "\(AppleHealthExportParser.archiveRoot)/export.xml"

        if let entry = listing.byPath[expectedPath] {
            return (expectedPath, entry, false)
        }

        let loweredExpected = expectedPath.lowercased()
        if let path = listing.paths.first(where: { $0.lowercased() == loweredExpected }),
           let entry = listing.byPath[path] {
            return (path, entry, true)
        }

        // Apple translates the document's filename for some locales, so the
        // document is also recognized as the one `.xml` sitting directly inside
        // the export directory. Sorted so the choice is deterministic if an
        // archive somehow holds more than one.
        let root = AppleHealthExportParser.archiveRoot
        let directCandidates = listing.paths.filter { path in
            (path as NSString).deletingLastPathComponent == root
                && (path as NSString).pathExtension.lowercased() == "xml"
        }.sorted()

        if let path = directCandidates.first, let entry = listing.byPath[path] {
            return (path, entry, true)
        }

        throw AppleHealthArchiveError.exportXMLNotFound
    }

    // MARK: - Extraction

    private func extractToTemporaryFile(
        _ entry: Entry,
        path: String,
        from archive: Archive,
        limitBytes: Int64,
        isCancelled: @Sendable () -> Bool
    ) throws -> URL {
        // The header states the uncompressed size before a byte is read, so a
        // declared-oversize entry never costs a decompression pass. The cap is
        // still enforced while writing, because the header is not trusted.
        if entry.uncompressedSize > UInt64(max(0, limitBytes)) {
            throw AppleHealthArchiveError.entryTooLarge(path: path, limitBytes: limitBytes)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runplay-health-\(UUID().uuidString).xml")
        // `FileManager.createFile` returns a `Bool` that corelibs-foundation does
        // not mark discardable, so an empty write is used to create the file.
        try Data().write(to: temporaryURL)

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            var written: Int64 = 0
            _ = try archive.extract(entry, bufferSize: Self.extractionBufferSize) { chunk in
                written += Int64(chunk.count)
                guard written <= limitBytes else {
                    throw AppleHealthArchiveError.entryTooLarge(
                        path: path,
                        limitBytes: limitBytes
                    )
                }
                if isCancelled() { throw CancellationError() }
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }

        return temporaryURL
    }

    private func fileSize(of url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }
}
