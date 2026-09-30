import Foundation
import ZIPFoundation
import RunPlayCore

// MARK: - Errors

/// Why a route archive path was refused.
///
/// A route path is untrusted input: it arrives from the export document, which
/// is the very thing being validated. Each reason is distinct so a caller (and a
/// test) can tell a traversal attempt from a plain malformed name.
public enum AppleHealthRoutePathRejection: String, Equatable, Sendable {
    /// The path was empty after trimming, or too long for the policy.
    case empty
    /// The path exceeded the policy's maximum length.
    case tooLong
    /// The path began with `/`.
    case absolute
    /// The path contained a backslash, a Windows-style separator that no Apple
    /// Health export produces.
    case backslash
    /// The path contained a `.` or `..` component.
    case traversal
    /// The path had an empty component, e.g. a doubled separator.
    case malformedSeparator
    /// The path was well formed but not under the export's route directory.
    case notUnderRouteDirectory
}

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

    /// More than one document in the export directory could be the export.
    ///
    /// Only the fallback lookup can produce this: the exact `export.xml` path and
    /// its case-insensitive match are unambiguous by definition. The count is
    /// carried so the message can say how many candidates were seen.
    case ambiguousExportXML(candidateCount: Int)

    /// The single fallback candidate's root element was not `HealthData`.
    ///
    /// Guards against importing an unrelated `.xml` that merely happens to sit in
    /// the export directory.
    case documentIsNotAHealthExport(path: String)

    /// An entry's uncompressed content exceeded the byte cap.
    case entryTooLarge(path: String, limitBytes: Int64)

    /// The central-directory metadata is missing, inconsistent, or unsupported.
    case invalidCentralDirectory

    /// Decompression would write more bytes than the central directory declares.
    case entryExceedsDeclaredSize(path: String, declaredBytes: UInt64)

    /// The requested entry is not a readable route file in this archive.
    case routeEntryNotFound(String)

    /// The requested route path was refused before any lookup happened.
    case routePathRejected(path: String, reason: AppleHealthRoutePathRejection)

    /// The route entry is a symbolic link.
    ///
    /// A symlink is followed by the filesystem, so reading one would let the
    /// archive reach outside itself. Even under `workout-routes/` it is refused.
    case routeEntryIsSymlink(path: String)

    /// There is not enough free space to extract the document.
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)

    /// The private extraction directory or file could not be prepared.
    case extractionUnavailable(String)

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
        case .ambiguousExportXML(let candidateCount):
            return "This ZIP holds \(candidateCount) possible Apple Health export documents. "
                + "It should hold exactly one: \(AppleHealthExportParser.archiveRoot)/export.xml."
        case .documentIsNotAHealthExport(let path):
            return "The file \(path) is not an Apple Health export document."
        case .entryTooLarge(let path, let limitBytes):
            return "\(path) is larger than the \(Self.formatted(limitBytes)) limit."
        case .invalidCentralDirectory:
            return "This archive has an unreadable central directory."
        case .entryExceedsDeclaredSize:
            return "The export document expands beyond the size declared by its archive. It was not imported."
        case .routeEntryNotFound(let path):
            return "The archive has no route file at \(path)."
        case .routePathRejected(let path, let reason):
            return "The archive path \(path) is not usable as a route file (\(Self.describe(reason)))."
        case .routeEntryIsSymlink(let path):
            return "The route file \(path) is a symbolic link, which is not read."
        case .insufficientFreeSpace(let requiredBytes, let availableBytes):
            return "Importing needs about \(Self.formatted(requiredBytes)) of free space, "
                + "but only \(Self.formatted(availableBytes)) is available."
        case .extractionUnavailable(let detail):
            return "The import could not prepare a private working file. \(detail)"
        }
    }

    private static func describe(_ reason: AppleHealthRoutePathRejection) -> String {
        switch reason {
        case .empty: return "it is empty"
        case .tooLong: return "it is too long"
        case .absolute: return "it is an absolute path"
        case .backslash: return "it contains a backslash separator"
        case .traversal: return "it contains a parent-directory segment"
        case .malformedSeparator: return "it has an empty path component"
        case .notUnderRouteDirectory: return "it is not under the route directory"
        }
    }

    private static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Report

/// The counts one read of `export.zip` produced, as a report presents them.
///
/// The two loss counts sit together deliberately. A dropped workout (one the
/// streaming scan could not build) and a route reference that named an absent
/// entry are the only ways an import can quietly come up short, so a caller that
/// shows one should be able to show the other without reaching into `scan`.
public struct AppleHealthArchiveReport: Hashable, Sendable {

    /// Workouts the export document described.
    public var workoutCount: Int

    /// Candidates built from those workouts, before any selection.
    public var candidateCount: Int

    /// Candidates flagged as an exact or possible duplicate of another window.
    public var duplicateCandidateCount: Int

    /// Workouts the scan could not build.
    public var droppedWorkoutCount: Int

    /// Workouts naming a route the archive does not contain.
    ///
    /// Counted rather than resolved silently: a workout whose route is missing is
    /// still importable as a route-less run, but the user is entitled to know
    /// that its route was referenced and absent.
    public var unmatchedRouteReferenceCount: Int

    /// Archive entries under the export's `workout-routes` directory.
    public var routeEntryCount: Int

    /// Entries the archive holds, including ones this reader ignores.
    public var entryCount: Int

    /// Uncompressed bytes of the document, as written to disk before parsing.
    public var uncompressedXMLBytes: Int64

    public init(
        workoutCount: Int,
        candidateCount: Int,
        duplicateCandidateCount: Int,
        droppedWorkoutCount: Int,
        unmatchedRouteReferenceCount: Int,
        routeEntryCount: Int,
        entryCount: Int,
        uncompressedXMLBytes: Int64
    ) {
        self.workoutCount = workoutCount
        self.candidateCount = candidateCount
        self.duplicateCandidateCount = duplicateCandidateCount
        self.droppedWorkoutCount = droppedWorkoutCount
        self.unmatchedRouteReferenceCount = unmatchedRouteReferenceCount
        self.routeEntryCount = routeEntryCount
        self.entryCount = entryCount
        self.uncompressedXMLBytes = uncompressedXMLBytes
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

    /// True when the document was found only by a fallback lookup.
    public var usedCaseInsensitiveXMLLookup: Bool

    /// Counts a review screen or report shows.
    public var report: AppleHealthArchiveReport

    public init(
        scan: AppleHealthExportScan,
        candidates: [AppleHealthWorkoutCandidate],
        exportXMLEntryPath: String,
        usedCaseInsensitiveXMLLookup: Bool,
        report: AppleHealthArchiveReport
    ) {
        self.scan = scan
        self.candidates = candidates
        self.exportXMLEntryPath = exportXMLEntryPath
        self.usedCaseInsensitiveXMLLookup = usedCaseInsensitiveXMLLookup
        self.report = report
    }

    /// Workouts the export document described.
    public var workoutCount: Int { report.workoutCount }

    /// Candidates built from those workouts.
    public var candidateCount: Int { report.candidateCount }
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
/// streaming it.
///
/// The file is written into a private directory this app owns, mode `0700`, with
/// the file itself mode `0600`, and it is removed on every exit path — success,
/// thrown error, cancellation, and a ceiling refusal alike. A crash can outlive a
/// `defer`, so each import first sweeps any stale extraction file a previous run
/// left behind.
public actor AppleHealthArchiveService {

    /// Finite limits for untrusted archives.
    public let policy: WorkoutArchiveSecurityPolicy

    /// Decompression and write chunk size.
    private static let extractionBufferSize = 64 * 1024

    /// Prefix identifying extraction files this service owns.
    private static let extractionFilePrefix = "runplay-health-extraction-"

    /// How old an extraction file must be before a sweep may delete it.
    ///
    /// Age-gated rather than "delete everything", so a second copy of the app
    /// reading its own archive cannot delete a live extraction under the first.
    /// An import takes seconds; an hour-old file is a crash in progress.
    private static let defaultStaleExtractionAge: TimeInterval = 3_600

    /// Bytes of the document read when peeking at its root element.
    private static let rootElementProbeBytes = 512 * 1024

    /// How far a fallback extraction may write before it is abandoned.
    private let extractionRootOverride: URL?

    /// Individual route payload limit; never applied to the streamed export document.
    private let sourcePayloadByteLimit: Int64

    /// Age after which a sweep may delete an extraction file.
    private let staleExtractionAge: TimeInterval

    /// Free space available at a location, or `nil` when it cannot be read.
    private let availableCapacity: @Sendable (URL) -> Int64?

    public init(policy: WorkoutArchiveSecurityPolicy = .default) {
        self.policy = policy
        self.sourcePayloadByteLimit = Int64(WorkoutImportResourceLimits.maxSourceFileBytes)
        self.extractionRootOverride = nil
        self.staleExtractionAge = 3_600
        self.availableCapacity = AppleHealthArchiveService.availableCapacityOnDisk
    }

    /// Test seam: point extraction at a scratch directory and fake free space.
    init(
        policy: WorkoutArchiveSecurityPolicy,
        extractionRoot: URL?,
        staleExtractionAge: TimeInterval,
        availableCapacity: @escaping @Sendable (URL) -> Int64?,
        sourcePayloadByteLimit: Int64 = Int64(WorkoutImportResourceLimits.maxSourceFileBytes)
    ) {
        self.policy = policy
        self.sourcePayloadByteLimit = max(0, sourcePayloadByteLimit)
        self.extractionRootOverride = extractionRoot
        self.staleExtractionAge = staleExtractionAge
        self.availableCapacity = availableCapacity
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

        let document = try locateExportXML(in: listing, archive: archive)

        let declaredXMLBytes = try HealthArchiveCentralDirectory.uncompressedSize(
            at: archiveURL,
            entryPath: document.entry.path,
            maximumEntries: policy.maxEntryCount
        )
        let temporaryURL = try extractToTemporaryFile(
            document.entry,
            path: document.path,
            from: archive,
            declaredBytes: declaredXMLBytes,
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

        let report = AppleHealthArchiveReport(
            workoutCount: scan.workouts.count,
            candidateCount: candidates.count,
            duplicateCandidateCount: candidates.count { $0.status != .ready },
            droppedWorkoutCount: scan.droppedWorkoutCount,
            unmatchedRouteReferenceCount: unmatched,
            routeEntryCount: listing.routePathsLowercased.count,
            entryCount: listing.entryCount,
            uncompressedXMLBytes: uncompressedBytes
        )

        return AppleHealthArchiveScanResult(
            scan: scan,
            candidates: candidates,
            exportXMLEntryPath: document.path,
            usedCaseInsensitiveXMLLookup: document.caseInsensitive,
            report: report
        )
    }

    /// Read one route file, by the archive-relative path a scan reported.
    ///
    /// The path must be a normalized route file under the export's
    /// `workout-routes` directory. Restricting it keeps this from becoming a
    /// general "read any entry" API, which is the shape a path-traversal bug
    /// needs. The checks are explicit — absolute paths, `..`, and backslashes are
    /// refused rather than normalized away — and a symbolic link is refused even
    /// when it sits under the route directory, because following one would let
    /// the archive read outside itself.
    public func routeGPXData(
        forArchivePath archivePath: String,
        archiveAt archiveURL: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> Data {
        guard archiveURL.isFileURL else { throw AppleHealthArchiveError.notALocalFile }

        let normalized = try Self.validatedRoutePath(archivePath, maxLength: policy.maxPathLength)

        let archive = try openArchive(archiveURL)
        let listing = try listEntries(in: archive)
        guard !isCancelled() else { throw CancellationError() }

        guard let entry = entry(matching: normalized, in: listing) else {
            throw AppleHealthArchiveError.routeEntryNotFound(archivePath)
        }
        guard entry.type != .symlink else {
            throw AppleHealthArchiveError.routeEntryIsSymlink(path: normalized)
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

    // MARK: - Route path validation

    /// Normalize and vet a route path, refusing anything that could escape.
    ///
    /// Unlike the listing's validator, this one does not unify backslashes to
    /// slashes: a route path is produced by this codebase, so a backslash is not
    /// noise to be normalized but a second separator to be refused. Nothing is
    /// returned unless the input is already normalized.
    static func validatedRoutePath(_ raw: String, maxLength: Int) throws -> String {
        guard !raw.isEmpty else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .empty)
        }
        guard raw.count <= maxLength else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .tooLong)
        }
        guard !raw.hasPrefix("/") else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .absolute)
        }
        guard !raw.contains("\\") else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .backslash)
        }

        // Split without dropping empties, so a doubled separator stays visible.
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: \.isEmpty) else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .malformedSeparator)
        }
        guard !components.contains(".") && !components.contains("..") else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .traversal)
        }
        guard isRoutePath(raw) else {
            throw AppleHealthArchiveError.routePathRejected(path: raw, reason: .notUnderRouteDirectory)
        }
        return raw
    }

    // MARK: - Archive opening and listing

    /// The product limit on one route GPX payload. The streamed XML is exempt.
    ///
    /// Shared with every other importer rather than restated, so the app accepts
    /// exactly one payload size everywhere.
    private var sourceByteLimit: Int64 {
        min(policy.maxUncompressedEntryBytes, sourcePayloadByteLimit)
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
            // Only regular files count as available routes. A symlink is a
            // refusal in `routeGPXData`, so it must not make a workout's route
            // reference look satisfied here.
            if Self.isRoutePath(normalized), entry.type == .file {
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
        in listing: EntryListing,
        archive: Archive
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

        // Apple translates the document's filename for some locales, so one `.xml`
        // sitting directly inside the export directory is also accepted — but
        // only as a fallback with two independent guards, because a directory can
        // hold any number of unrelated `.xml` files:
        //
        //   1. Exactly one candidate, or the import is refused and the message
        //      names how many were seen. Picking one of several would be a guess
        //      that silently decides which workouts the user gets.
        //   2. Its root element must be `HealthData`, so an unrelated document
        //      that merely shares the directory is not imported.
        let root = AppleHealthExportParser.archiveRoot
        let directCandidates = listing.paths.filter { path in
            (path as NSString).deletingLastPathComponent == root
                && (path as NSString).pathExtension.lowercased() == "xml"
        }.sorted()

        guard directCandidates.count <= 1 else {
            throw AppleHealthArchiveError.ambiguousExportXML(candidateCount: directCandidates.count)
        }
        guard let path = directCandidates.first, let entry = listing.byPath[path] else {
            throw AppleHealthArchiveError.exportXMLNotFound
        }
        guard try isHealthDataDocument(entry, in: archive) else {
            throw AppleHealthArchiveError.documentIsNotAHealthExport(path: path)
        }
        return (path, entry, true)
    }

    /// Whether the entry's first element is `HealthData`.
    ///
    /// Reads only the head of the entry: the answer is in its first bytes, and a
    /// translated export document can be hundreds of megabytes.
    private func isHealthDataDocument(_ entry: Entry, in archive: Archive) throws -> Bool {
        var head = Data()
        head.reserveCapacity(Self.rootElementProbeBytes)

        /// Stops the push-based extractor once the head is large enough.
        struct ProbeComplete: Error {}

        do {
            _ = try archive.extract(
                entry,
                bufferSize: Self.extractionBufferSize,
                skipCRC32: true
            ) { chunk in
                head.append(chunk)
                if head.count >= Self.rootElementProbeBytes { throw ProbeComplete() }
            }
        } catch is ProbeComplete {
            // The head is complete; the rest of the entry was never needed.
        } catch {
            throw AppleHealthArchiveError.cannotOpenArchive(error.localizedDescription)
        }

        guard let name = Self.firstElementName(in: head) else { return false }
        return name.caseInsensitiveCompare("HealthData") == .orderedSame
    }

    /// The first element name in an XML head, skipping declaration, comment and
    /// doctype prologue.
    static func firstElementName(in data: Data) -> String? {
        var searchStart = data.startIndex
        while searchStart < data.endIndex {
            guard let open = data[searchStart...].firstIndex(of: UInt8(ascii: "<")) else {
                return nil
            }
            var cursor = data.index(after: open)
            guard cursor < data.endIndex else { return nil }

            if data[cursor] == UInt8(ascii: "?") || data[cursor] == UInt8(ascii: "!") {
                // `<?xml …?>`, `<!-- … -->`, `<!DOCTYPE …>`: skip to the next `>`.
                guard let close = data[cursor...].firstIndex(of: UInt8(ascii: ">")) else {
                    return nil
                }
                searchStart = data.index(after: close)
                continue
            }

            var nameBytes: [UInt8] = []
            while cursor < data.endIndex {
                let byte = data[cursor]
                let isTerminator = byte == UInt8(ascii: ">")
                    || byte == UInt8(ascii: "/")
                    || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                if isTerminator { break }
                nameBytes.append(byte)
                cursor = data.index(after: cursor)
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Extraction

    /// Extract the document into a private file this app owns.
    ///
    /// - Returns: The file's URL. The caller owns its lifetime and removes it.
    private func extractToTemporaryFile(
        _ entry: Entry,
        path: String,
        from archive: Archive,
        declaredBytes: UInt64,
        isCancelled: @Sendable () -> Bool
    ) throws -> URL {
        // Entry.uncompressedSize can prefer the data descriptor; the central
        // directory is the authority for this precheck and the write guard.
        guard let requiredBytes = Int64(exactly: declaredBytes) else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        let directory = try prepareExtractionDirectory()
        sweepStaleExtractions(in: directory)
        if let available = availableCapacity(directory), requiredBytes > available {
            throw AppleHealthArchiveError.insufficientFreeSpace(
                requiredBytes: requiredBytes,
                availableBytes: available
            )
        }

        let fileURL = directory.appendingPathComponent(
            "\(Self.extractionFilePrefix)\(UUID().uuidString).xml"
        )

        var needsCleanup = true
        defer {
            if needsCleanup { try? FileManager.default.removeItem(at: fileURL) }
        }

        let fileManager = FileManager.default
        do {
            // `FileManager.createFile` returns a `Bool` that corelibs-foundation
            // does not mark discardable, so an empty write is used to create it.
            try Data().write(to: fileURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw AppleHealthArchiveError.extractionUnavailable(error.localizedDescription)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw AppleHealthArchiveError.extractionUnavailable(error.localizedDescription)
        }
        defer { try? handle.close() }

        var written: UInt64 = 0
        _ = try archive.extract(entry, bufferSize: Self.extractionBufferSize) { chunk in
            // Check before writing and subtract before adding, avoiding overflow
            // while guaranteeing the on-disk file never exceeds its declaration.
            guard UInt64(chunk.count) <= declaredBytes - written else {
                throw AppleHealthArchiveError.entryExceedsDeclaredSize(path: path, declaredBytes: declaredBytes)
            }
            if isCancelled() { throw CancellationError() }
            try handle.write(contentsOf: chunk)
            written += UInt64(chunk.count)
        }

        needsCleanup = false
        return fileURL
    }

    /// The private directory extraction writes into.
    ///
    /// The app's caches directory, not a shared temporary path, and mode `0700`.
    /// A caches directory already belongs to this user, but the explicit mode
    /// keeps the export unreadable to other accounts and to any process that
    /// walks shared temporary storage.
    private func prepareExtractionDirectory() throws -> URL {
        let directory = extractionRootOverride ?? Self.defaultExtractionDirectory()
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            // Tighten the mode even when the directory already existed, since a
            // directory created by another code path could be more permissive.
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw AppleHealthArchiveError.extractionUnavailable(error.localizedDescription)
        }
        return directory
    }

    /// Delete extraction files a previous run left behind.
    ///
    /// A crash or a kill skips `defer`, so the file survives with the export's
    /// contents. Only files this service named, and only ones older than
    /// `staleExtractionAge`, are removed, so a concurrent import's live file is
    /// never taken.
    private func sweepStaleExtractions(in directory: URL) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-staleExtractionAge)
        for url in contents {
            guard url.lastPathComponent.hasPrefix(Self.extractionFilePrefix) else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            guard let modified = values?.contentModificationDate, modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// The app-owned directory extraction files live in.
    ///
    /// Internal rather than private so a test can assert the location is the
    /// app's own directory and not a shared temporary path.
    static func defaultExtractionDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("RunPlayStudio", isDirectory: true)
            .appendingPathComponent("AppleHealthExtractions", isDirectory: true)
    }

    /// Free space at a location, preferring the figure that accounts for purgeable
    /// space, or `nil` when the volume cannot report one.
    private static func availableCapacityOnDisk(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }

    private func fileSize(of url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size)
    }
}
