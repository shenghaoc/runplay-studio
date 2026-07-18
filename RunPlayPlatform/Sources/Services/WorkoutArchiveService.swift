import Foundation
import ZIPFoundation
import RunPlayCore

/// Scans a bulk-export archive for importable activity candidates.
public protocol WorkoutArchiveScanning: Sendable {
    func scanArchive(
        at url: URL,
        existingWorkouts: [RunWorkout],
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void
    ) async throws -> WorkoutArchiveScanResult
}

/// Imports selected archive candidates into staged workouts via the library actor.
public protocol WorkoutArchiveImporting: Sendable {
    func importCandidates(
        _ selection: WorkoutBatchImportSelection,
        from archiveURL: URL,
        existingWorkouts: [RunWorkout],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void
    ) async throws -> WorkoutBatchImportReport
}

/// Errors raised by archive open / recognition.
public enum WorkoutArchiveError: Error, LocalizedError, Equatable, Sendable {
    case archiveTooLarge
    case cannotOpenArchive(String)
    case notSupportedExport
    case tooManyEntries
    case cancelled
    case batchConflict

    public var errorDescription: String? {
        switch self {
        case .archiveTooLarge:
            return "This archive exceeds the maximum supported size."
        case .cannotOpenArchive(let detail):
            return "Could not open the archive. \(detail)"
        case .notSupportedExport:
            return "This ZIP does not appear to be a supported Strava bulk export."
        case .tooManyEntries:
            return "This archive has too many entries to process safely."
        case .cancelled:
            return "Archive operation was cancelled."
        case .batchConflict:
            return "Another library change is already in progress."
        }
    }
}

/// Actor that owns ZIP access, GZIP unwrap, hashing, and activity parsing.
///
/// Never runs on the main actor. Does not extract the full archive to disk.
public actor StravaArchiveService: WorkoutArchiveScanning, WorkoutArchiveImporting {

    public let policy: WorkoutArchiveSecurityPolicy
    private let gzipDecoder: GZIPDecoder
    private let csvParser: WorkoutArchiveCSVParser

    public init(policy: WorkoutArchiveSecurityPolicy = .default) {
        self.policy = policy
        self.gzipDecoder = GZIPDecoder(
            maxOutputBytes: Int(policy.maxUncompressedEntryBytes),
            cancellationCheckStride: policy.cancellationCheckStride
        )
        self.csvParser = WorkoutArchiveCSVParser(policy: policy)
    }

    // MARK: - Scan

    public func scanArchive(
        at url: URL,
        existingWorkouts: [RunWorkout],
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void = { _ in }
    ) async throws -> WorkoutArchiveScanResult {
        await progress(WorkoutBatchImportProgress(phase: .openingArchive))
        try Task.checkCancellation()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > policy.maxArchiveFileBytes {
            throw WorkoutArchiveError.archiveTooLarge
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw WorkoutArchiveError.cannotOpenArchive(error.localizedDescription)
        }

        await progress(WorkoutBatchImportProgress(phase: .scanningEntries))

        var entryPaths: [String] = []
        var entrySizes: [String: (compressed: Int64?, uncompressed: Int64?)] = [:]
        var ignored = 0
        var unsafe = 0
        var entryCount = 0
        var activitiesCSVPath: String?
        var activitiesCSVData: Data?

        for entry in archive {
            entryCount += 1
            if entryCount > policy.maxEntryCount {
                throw WorkoutArchiveError.tooManyEntries
            }
            if entryCount % policy.cancellationCheckStride == 0 {
                try Task.checkCancellation()
            }

            // Skip directories.
            if entry.type == .directory {
                ignored += 1
                continue
            }
            // Reject symlinks and special types.
            if entry.type != .file {
                unsafe += 1
                continue
            }

            let pathResult = WorkoutArchivePathValidator.validate(
                entry.path,
                maxLength: policy.maxPathLength
            )
            guard case .valid(let normalized) = pathResult else {
                unsafe += 1
                continue
            }

            if WorkoutArchivePathValidator.shouldIgnore(normalized) {
                ignored += 1
                continue
            }

            // Nested zip is never extracted.
            if normalized.lowercased().hasSuffix(".zip") {
                ignored += 1
                continue
            }

            let compressed = Int64(entry.compressedSize)
            let uncompressed = Int64(entry.uncompressedSize)
            entryPaths.append(normalized)
            entrySizes[normalized] = (compressed, uncompressed)

            // Locate activities.csv (any depth, optional root folder).
            let last = (normalized as NSString).lastPathComponent.lowercased()
            if last == "activities.csv" {
                // Prefer shallowest path if multiple.
                if activitiesCSVPath == nil
                    || normalized.split(separator: "/").count
                    < (activitiesCSVPath?.split(separator: "/").count ?? Int.max) {
                    activitiesCSVPath = normalized
                }
            }
        }

        await progress(WorkoutBatchImportProgress(phase: .readingMetadata))

        var metadataTable = StravaActivityMetadataTable()
        var metadataFound = false
        let entryIndex = makeEntryIndex(for: archive)

        if let csvPath = activitiesCSVPath {
            let sizes = entrySizes[csvPath]
            if let uncompressed = sizes?.uncompressed, uncompressed > policy.maxMetadataCSVBytes {
                throw WorkoutArchiveError.cannotOpenArchive("activities.csv exceeds size limit.")
            }
            if let compressed = sizes?.compressed, compressed > policy.maxMetadataCSVBytes {
                throw WorkoutArchiveError.cannotOpenArchive("activities.csv compressed size exceeds limit.")
            }
            do {
                activitiesCSVData = try readEntry(
                    path: csvPath,
                    archive: archive,
                    entryIndex: entryIndex,
                    maxUncompressed: Int(policy.maxMetadataCSVBytes)
                )
                if let data = activitiesCSVData {
                    metadataTable = try csvParser.parseStravaActivitiesCSV(from: data)
                    metadataFound = true
                }
            } catch is CancellationError {
                throw WorkoutArchiveError.cancelled
            } catch {
                // Malformed CSV → not a supported export if we cannot parse it.
                metadataFound = false
            }
        }

        // Conservative recognition: need activities.csv with rows AND/OR mapped activity files.
        let activityFiles = entryPaths.filter {
            WorkoutArchiveActivityFormat.detect(fromPath: $0) != .unsupported
        }
        let pathIndex = WorkoutArchivePathValidator.PathIndex(entries: entryPaths)
        let hasMappedRows = metadataTable.rows.contains { row in
            guard let filename = row.filename, !filename.isEmpty else { return false }
            switch WorkoutArchivePathValidator.matchPath(filename, index: pathIndex) {
            case .exact, .caseInsensitive: return true
            default: return false
            }
        }

        let recognized = metadataFound
            && !metadataTable.rows.isEmpty
            && (hasMappedRows || !activityFiles.isEmpty)

        var diagnostics = WorkoutArchiveScanDiagnostics(
            archiveName: url.lastPathComponent,
            entryCount: entryCount,
            ignoredEntryCount: ignored,
            unsafeEntryCount: unsafe,
            metadataCSVFound: metadataFound,
            metadataFilenameColumnPresent: metadataTable.hasFilenameColumn,
            estimatedTotalSourceBytes: activityFiles.reduce(Int64(0)) { partial, path in
                partial + (entrySizes[path]?.uncompressed ?? entrySizes[path]?.compressed ?? 0)
            }
        )

        if !recognized {
            return WorkoutArchiveScanResult(
                candidates: [],
                diagnostics: diagnostics,
                isRecognizedStravaExport: false,
                rejectionMessage: "This ZIP does not appear to be a supported Strava bulk export."
            )
        }

        let built = WorkoutArchiveCandidateBuilder.buildCandidates(
            metadataRows: metadataTable.rows,
            entryPaths: entryPaths,
            entrySizes: entrySizes,
            existingWorkouts: existingWorkouts,
            hasFilenameColumn: metadataTable.hasFilenameColumn,
            policy: policy
        )
        diagnostics.warnings.append(contentsOf: built.diagnosticsExtras)
        if !metadataTable.hasFilenameColumn {
            diagnostics.warnings.append(
                "Filename column missing; metadata matching and deduplication are less complete."
            )
        }

        await progress(WorkoutBatchImportProgress(
            phase: .awaitingSelection,
            totalCount: built.candidates.count
        ))

        return WorkoutArchiveScanResult(
            candidates: built.candidates,
            diagnostics: diagnostics,
            isRecognizedStravaExport: true,
            rejectionMessage: nil
        )
    }

    // MARK: - Import

    public func importCandidates(
        _ selection: WorkoutBatchImportSelection,
        from archiveURL: URL,
        existingWorkouts: [RunWorkout],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void = { _ in }
    ) async throws -> WorkoutBatchImportReport {
        try Task.checkCancellation()
        await progress(WorkoutBatchImportProgress(
            phase: .importing,
            totalCount: selection.selectedCandidates.count
        ))

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw WorkoutArchiveError.cannotOpenArchive(error.localizedDescription)
        }
        let entryIndex = makeEntryIndex(for: archive)

        let batch: WorkoutLibraryBatchToken
        do {
            batch = try await storeActor.beginBatchImport()
        } catch {
            throw WorkoutArchiveError.batchConflict
        }

        var items: [WorkoutBatchImportItemResult] = []
        var stagedWorkouts: [(candidateID: String, workout: RunWorkout)] = []
        var seenHashes = Set(existingWorkouts.compactMap { $0.importProvenance?.contentSHA256?.lowercased() })
        var batchHashes = Set<String>()
        var completed = 0
        var failed = 0
        var skipped = 0

        do {
            for candidate in selection.selectedCandidates {
                try Task.checkCancellation()
                completed += 1
                await progress(WorkoutBatchImportProgress(
                    phase: .importing,
                    completedCount: completed,
                    totalCount: selection.selectedCandidates.count,
                    currentFilename: candidate.displayName,
                    stagedCount: stagedWorkouts.count,
                    skippedCount: skipped,
                    failedCount: failed
                ))

                // Skip non-ready statuses that may have been force-selected.
                if candidate.status == .duplicate || candidate.status == .providerConflict {
                    skipped += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: candidate.status,
                        detail: candidate.statusDetail
                    ))
                    continue
                }

                guard candidate.format != .unsupported,
                      !candidate.archiveRelativePath.isEmpty else {
                    failed += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .missingActivityFile,
                        detail: candidate.statusDetail ?? "Missing activity file"
                    ))
                    continue
                }

                let rawBytes: Data
                do {
                    rawBytes = try readEntry(
                        path: candidate.archiveRelativePath,
                        archive: archive,
                        entryIndex: entryIndex,
                        maxUncompressed: Int(policy.maxUncompressedEntryBytes)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                // Decompress one GZIP layer when needed.
                let activityBytes: Data
                do {
                    if candidate.format.isGzipWrapped {
                        activityBytes = try gzipDecoder.decode(rawBytes)
                    } else {
                        activityBytes = rawBytes
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                let hash = ContentHasher.sha256Hex(of: activityBytes)
                let refined = WorkoutArchiveCandidateBuilder.refineStatus(
                    for: candidate,
                    contentSHA256: hash,
                    existingWorkouts: existingWorkouts,
                    seenHashesInBatch: &batchHashes
                )
                if refined.0 == .duplicate || refined.0 == .providerConflict {
                    skipped += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: refined.0,
                        detail: refined.1
                    ))
                    continue
                }
                if seenHashes.contains(hash) {
                    skipped += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .duplicate,
                        detail: "Already imported (identical file content)"
                    ))
                    continue
                }

                let provenance = WorkoutImportProvenance(
                    provider: .stravaBulkExport,
                    providerActivityID: candidate.providerActivityID,
                    contentSHA256: hash,
                    originalFilename: (candidate.archiveRelativePath as NSString).lastPathComponent
                )

                let input = WorkoutImportInput(
                    data: activityBytes,
                    fileExtension: candidate.format.fileExtension,
                    suggestedName: candidate.activityName
                        ?? (candidate.archiveRelativePath as NSString).lastPathComponent,
                    provenance: provenance
                )

                let workout: RunWorkout
                do {
                    var parsed = try WorkoutImporterFactory.importWorkout(from: input)
                    let meta = StravaActivityMetadataRow(
                        activityID: candidate.providerActivityID,
                        activityName: candidate.activityName,
                        activityType: candidate.activityType,
                        activityDate: candidate.activityDate,
                        filename: candidate.archiveRelativePath
                    )
                    WorkoutArchiveMetadataApplier.apply(
                        metadata: meta,
                        to: &parsed,
                        provenance: provenance,
                        contentSHA256: hash
                    )
                    // Prefer provider activity name after parse.
                    if let name = candidate.activityName, !name.isEmpty {
                        parsed.metadata.name = name
                    }
                    workout = parsed
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkoutImportError {
                    failed += 1
                    let status: WorkoutArchiveCandidateStatus
                    switch error {
                    case .missingData:
                        status = .noGPSRoute
                    default:
                        status = .parseFailed
                    }
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: status,
                        detail: error.localizedDescription
                    ))
                    continue
                } catch {
                    failed += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                await progress(WorkoutBatchImportProgress(
                    phase: .staging,
                    completedCount: completed,
                    totalCount: selection.selectedCandidates.count,
                    currentFilename: candidate.displayName,
                    stagedCount: stagedWorkouts.count,
                    skippedCount: skipped,
                    failedCount: failed
                ))

                do {
                    try await storeActor.stageWorkout(workout, in: batch)
                    stagedWorkouts.append((candidate.id, workout))
                    seenHashes.insert(hash)
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: workout.displayName,
                        status: .ready,
                        detail: nil,
                        importedWorkoutID: workout.id
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    items.append(WorkoutBatchImportItemResult(
                        candidateID: candidate.id,
                        archiveRelativePath: candidate.archiveRelativePath,
                        activityName: candidate.activityName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                }
                // Release activity bytes by leaving scope (rawBytes/activityBytes end).
            }

            // Determine selection: newest by start date, then archive order.
            let selectedID = Self.selectNewest(stagedWorkouts.map(\.workout))

            await progress(WorkoutBatchImportProgress(
                phase: .committing,
                completedCount: completed,
                totalCount: selection.selectedCandidates.count,
                stagedCount: stagedWorkouts.count,
                skippedCount: skipped,
                failedCount: failed
            ))

            if stagedWorkouts.isEmpty {
                await storeActor.rollbackBatchImport(batch)
                await progress(WorkoutBatchImportProgress(phase: .completed))
                return WorkoutBatchImportReport(
                    items: items,
                    importedWorkoutIDs: [],
                    selectedWorkoutID: nil,
                    wasCancelled: false,
                    commitFailed: false
                )
            }

            let committedIDs: [UUID]
            do {
                committedIDs = try await storeActor.commitBatchImport(
                    batch,
                    selectedWorkoutID: selectedID
                )
            } catch {
                await storeActor.rollbackBatchImport(batch)
                return WorkoutBatchImportReport(
                    items: items,
                    importedWorkoutIDs: [],
                    selectedWorkoutID: nil,
                    wasCancelled: false,
                    commitFailed: true,
                    errorMessage: error.localizedDescription
                )
            }

            await progress(WorkoutBatchImportProgress(
                phase: .completed,
                completedCount: completed,
                totalCount: selection.selectedCandidates.count,
                stagedCount: committedIDs.count,
                skippedCount: skipped,
                failedCount: failed
            ))

            return WorkoutBatchImportReport(
                items: items,
                importedWorkoutIDs: committedIDs,
                selectedWorkoutID: selectedID,
                wasCancelled: false,
                commitFailed: false
            )
        } catch is CancellationError {
            await storeActor.rollbackBatchImport(batch)
            await progress(WorkoutBatchImportProgress(phase: .cancelled))
            return WorkoutBatchImportReport(
                items: items,
                importedWorkoutIDs: [],
                selectedWorkoutID: nil,
                wasCancelled: true
            )
        } catch {
            await storeActor.rollbackBatchImport(batch)
            throw error
        }
    }

    // MARK: - Helpers

    /// One-pass index of archive entries for O(1) path lookups during import.
    private struct ArchiveEntryIndex {
        let byNormalizedPath: [String: Entry]
        let byLowercasedPath: [String: [Entry]]

        init(archive: Archive, maxPathLength: Int) {
            var byNormalized: [String: Entry] = [:]
            var byLower: [String: [Entry]] = [:]
            for entry in archive {
                guard entry.type == .file else { continue }
                guard case .valid(let normalized) = WorkoutArchivePathValidator.validate(
                    entry.path,
                    maxLength: maxPathLength
                ) else {
                    continue
                }
                // First exact path wins; duplicates stay available via lowercased map.
                if byNormalized[normalized] == nil {
                    byNormalized[normalized] = entry
                }
                byLower[normalized.lowercased(), default: []].append(entry)
            }
            self.byNormalizedPath = byNormalized
            self.byLowercasedPath = byLower
        }

        func entry(for path: String) -> Entry? {
            if let exact = byNormalizedPath[path] {
                return exact
            }
            let matches = byLowercasedPath[path.lowercased()] ?? []
            return matches.count == 1 ? matches[0] : nil
        }
    }

    private func makeEntryIndex(for archive: Archive) -> ArchiveEntryIndex {
        ArchiveEntryIndex(archive: archive, maxPathLength: policy.maxPathLength)
    }

    private func readEntry(
        path: String,
        archive: Archive,
        entryIndex: ArchiveEntryIndex,
        maxUncompressed: Int
    ) throws -> Data {
        guard let entry = entryIndex.entry(for: path) else {
            throw WorkoutArchiveError.cannotOpenArchive("Entry not found: \(path)")
        }

        guard entry.type == .file else {
            throw WorkoutArchiveError.cannotOpenArchive("Unsupported entry type")
        }

        let compressed = Int64(entry.compressedSize)
        let uncompressed = Int64(entry.uncompressedSize)
        if compressed > policy.maxCompressedEntryBytes {
            throw WorkoutArchiveError.cannotOpenArchive("Entry exceeds compressed size limit")
        }
        if uncompressed > Int64(maxUncompressed) {
            throw WorkoutArchiveError.cannotOpenArchive("Entry exceeds uncompressed size limit")
        }
        if compressed > 0, uncompressed > 0 {
            let ratio = Double(uncompressed) / Double(compressed)
            if ratio > policy.maxCompressionRatio {
                throw WorkoutArchiveError.cannotOpenArchive("Entry compression ratio exceeds limit")
            }
        }

        var data = Data()
        let reserve = min(maxUncompressed, max(Int(uncompressed), 0))
        if reserve > 0 {
            data.reserveCapacity(reserve)
        }
        // Bound growth even if declared uncompressed size is understated.
        // The extract callback cannot throw; flag oversize and reject after.
        var exceededLimit = false
        do {
            _ = try archive.extract(entry, bufferSize: 65_536, skipCRC32: false) { chunk in
                if exceededLimit { return }
                if data.count + chunk.count > maxUncompressed {
                    exceededLimit = true
                    return
                }
                data.append(chunk)
            }
        } catch {
            throw WorkoutArchiveError.cannotOpenArchive(error.localizedDescription)
        }
        if exceededLimit || data.count > maxUncompressed {
            throw WorkoutArchiveError.cannotOpenArchive("Entry exceeds uncompressed size limit")
        }
        return data
    }

    private static func selectNewest(_ workouts: [RunWorkout]) -> UUID? {
        guard !workouts.isEmpty else { return nil }
        let sorted = workouts.sorted { a, b in
            let da = a.metadata.startDate ?? .distantPast
            let db = b.metadata.startDate ?? .distantPast
            if da != db { return da > db }
            return a.id.uuidString > b.id.uuidString
        }
        return sorted.first?.id
    }
}
