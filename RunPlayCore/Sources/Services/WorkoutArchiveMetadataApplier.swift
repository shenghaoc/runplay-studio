import Foundation

/// Applies secondary archive CSV metadata onto a parsed activity workout.
///
/// Route geometry, timestamps, laps, sensors, and analysis remain canonical
/// from the activity file. CSV may improve display name, provenance, and
/// provide a start-date fallback.
public enum WorkoutArchiveMetadataApplier {

    public static func apply(
        metadata: StravaActivityMetadataRow?,
        to workout: inout RunWorkout,
        provenance: WorkoutImportProvenance,
        contentSHA256: String?
    ) {
        var provenance = provenance
        if let contentSHA256 {
            provenance.contentSHA256 = contentSHA256.lowercased()
        }
        if let id = metadata?.activityID, !id.isEmpty {
            provenance.providerActivityID = id
        }
        if let filename = metadata?.filename, !filename.isEmpty {
            provenance.originalFilename = (filename as NSString).lastPathComponent
        }
        workout.importProvenance = provenance

        if let name = metadata?.activityName, !name.isEmpty {
            let current = workout.metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Replace empty or filename-derived generic names.
            if current.isEmpty
                || current == provenance.originalFilename
                || current == (provenance.originalFilename as NSString?)?.deletingPathExtension
            {
                workout.metadata.name = name
            } else if looksLikeFilename(current) {
                workout.metadata.name = name
            }
        }

        // Date: only fill missing start date from CSV; never overwrite a trustworthy route time.
        if workout.metadata.startDate == nil, let csvDate = metadata?.activityDate {
            workout.metadata.startDate = csvDate
        }
        // Route timestamps remain canonical when present; CSV date conflicts are not overwritten.
    }

    private static func looksLikeFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".fit")
            || lower.hasSuffix(".gpx")
            || lower.hasSuffix(".tcx")
            || lower.hasSuffix(".gz")
            || lower.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// Builds candidates from metadata rows and archive entry inventory.
public enum WorkoutArchiveCandidateBuilder {

    /// Status detail for a provider activity ID that repeats within one
    /// archive, in the app's language. Importers that must recognise this
    /// duplicate compare against it rather than against English text.
    public static var duplicateProviderActivityIDWithinArchiveDetail: String {
        coreLocalized("Duplicate provider activity ID within archive")
    }

    public static func buildCandidates(
        metadataRows: [StravaActivityMetadataRow],
        entryPaths: [String],
        entrySizes: [String: (compressed: Int64?, uncompressed: Int64?)],
        existingWorkouts: [RunWorkout],
        hasFilenameColumn: Bool,
        policy: WorkoutArchiveSecurityPolicy = .default
    ) -> (candidates: [WorkoutArchiveCandidate], diagnosticsExtras: [String]) {
        var warnings: [String] = []
        let existingByProviderID = indexProviderIDs(existingWorkouts)
        let pathIndex = WorkoutArchivePathValidator.PathIndex(entries: entryPaths)

        var usedPaths = Set<String>()
        var seenProviderIDs = Set<String>()
        var candidates: [WorkoutArchiveCandidate] = []
        var order = 0

        if !metadataRows.isEmpty {
            for row in metadataRows {
                if candidates.count >= policy.maxCandidateActivityCount {
                    warnings.append(coreLocalized("Candidate activity limit reached; remaining rows skipped."))
                    break
                }

                var state = pathState(
                    for: row, pathIndex: pathIndex, entrySizes: entrySizes,
                    hasFilenameColumn: hasFilenameColumn, usedPaths: &usedPaths
                )
                applyFormatCheck(to: &state)
                applyActivityTypeCheck(row, to: &state)
                applyDuplicateCheck(
                    row, seenProviderIDs: &seenProviderIDs, existingByProviderID: existingByProviderID, to: &state
                )
                applySizeLimits(policy, to: &state)

                let selected = state.status.isImportableByDefault
                    && StravaActivityTypePolicy.isSelectedByDefault(row.activityType)

                // A provider ID is metadata, not a row identity: exports can
                // contain duplicate provider IDs and SwiftUI still needs stable,
                // distinct rows for each candidate.
                let id = "row:\(row.rowIndex):\(state.archivePath)"

                candidates.append(WorkoutArchiveCandidate(
                    id: id,
                    archiveRelativePath: state.archivePath,
                    providerActivityID: row.activityID,
                    activityName: row.activityName,
                    activityType: row.activityType,
                    activityDate: row.activityDate,
                    format: state.format,
                    compressedBytes: state.compressed,
                    declaredUncompressedBytes: state.uncompressed,
                    status: state.status,
                    statusDetail: state.detail,
                    isSelectedByDefault: selected,
                    archiveOrder: order
                ))
                order += 1
            }
        } else {
            // No metadata CSV: fall back to activity files only (weaker recognition).
            candidates = fileOnlyCandidates(
                entryPaths: entryPaths, entrySizes: entrySizes, policy: policy, usedPaths: &usedPaths
            )
        }

        return (candidates, warnings)
    }

    /// One metadata row's candidate as its checks resolve it.
    private struct RowState {
        var archivePath = ""
        var format: WorkoutArchiveActivityFormat = .unsupported
        var status: WorkoutArchiveCandidateStatus = .ready
        var detail: String?
        var compressed: Int64?
        var uncompressed: Int64?
    }

    /// The row's archive path, format and sizes from its filename match. An
    /// ambiguous match is unsafe; a filename not in the archive, or no
    /// filename, is a missing activity file.
    private static func pathState(
        for row: StravaActivityMetadataRow,
        pathIndex: WorkoutArchivePathValidator.PathIndex,
        entrySizes: [String: (compressed: Int64?, uncompressed: Int64?)],
        hasFilenameColumn: Bool,
        usedPaths: inout Set<String>
    ) -> RowState {
        let pathMatch: WorkoutArchivePathValidator.PathMatchResult
        if let filename = row.filename, !filename.isEmpty {
            pathMatch = WorkoutArchivePathValidator.matchPath(filename, index: pathIndex)
        } else {
            pathMatch = .none
        }

        var state = RowState()
        switch pathMatch {
        case .exact(let path), .caseInsensitive(let path):
            state.archivePath = path
            state.format = WorkoutArchiveActivityFormat.detect(fromPath: path)
            let sizes = entrySizes[path]
            state.compressed = sizes?.compressed
            state.uncompressed = sizes?.uncompressed
            usedPaths.insert(path)
        case .ambiguous:
            state.archivePath = row.filename ?? ""
            state.status = .unsafeArchiveEntry
            state.detail = coreLocalized("Ambiguous path match for activity file")
        case .none:
            if let filename = row.filename, !filename.isEmpty {
                state.archivePath = filename
                state.format = WorkoutArchiveActivityFormat.detect(fromPath: filename)
                state.status = .missingActivityFile
                state.detail = coreLocalized("Activity file not found in archive")
            } else {
                state.archivePath = ""
                state.status = .missingActivityFile
                state.detail = hasFilenameColumn
                    ? coreLocalized("No filename for activity")
                    : coreLocalized("No filename column; activity file not mapped")
            }
        }
        return state
    }

    /// A ready row with an unsupported file format becomes unsupported.
    private static func applyFormatCheck(to state: inout RowState) {
        if state.status == .ready {
            if state.format == .unsupported {
                state.status = .unsupportedFormat
                state.detail = coreLocalized("Unsupported activity file format")
            }
        }
    }

    /// A ready row whose activity type is not running, walking or hiking
    /// becomes an unsupported activity type.
    private static func applyActivityTypeCheck(_ row: StravaActivityMetadataRow, to state: inout RowState) {
        let typeClass = StravaActivityTypePolicy.classify(row.activityType)
        if state.status == .ready {
            switch typeClass {
            case .running, .walkOrHike:
                break
            case .unsupported:
                state.status = .unsupportedActivityType
                if let activityType = row.activityType {
                    state.detail = coreLocalized("Activity type “\(activityType)” is not a running activity")
                } else {
                    state.detail = coreLocalized("Activity type “unknown” is not a running activity")
                }
            case .unknown:
                state.status = .unsupportedActivityType
                state.detail = coreLocalized("Unknown activity type “\(row.activityType ?? "")”")
            }
        }
    }

    /// A provider activity ID seen earlier in this archive, or already
    /// imported, makes the row a duplicate.
    private static func applyDuplicateCheck(
        _ row: StravaActivityMetadataRow,
        seenProviderIDs: inout Set<String>,
        existingByProviderID: [String: RunWorkout],
        to state: inout RowState
    ) {
        if let pid = row.activityID, !pid.isEmpty {
            if !seenProviderIDs.insert(pid).inserted {
                state.status = .duplicate
                state.detail = duplicateProviderActivityIDWithinArchiveDetail
            } else if existingByProviderID[pid] != nil {
                // Scan-time: treat matching provider IDs as duplicates.
                // Import-time refineStatus distinguishes providerConflict via content hash.
                state.status = .duplicate
                state.detail = coreLocalized("Already imported (provider activity ID)")
            }
        }
    }

    /// Size limits: a ready or possibly duplicate row whose compressed size,
    /// declared uncompressed size, or compression ratio exceeds the policy
    /// exceeds the resource limit.
    private static func applySizeLimits(_ policy: WorkoutArchiveSecurityPolicy, to state: inout RowState) {
        if state.status == .ready || state.status == .possibleDuplicate {
            if let c = state.compressed, c > policy.maxCompressedEntryBytes {
                state.status = .exceedsResourceLimit
                state.detail = coreLocalized("Compressed entry exceeds size limit")
            }
            if let u = state.uncompressed, u > policy.maxUncompressedEntryBytes {
                state.status = .exceedsResourceLimit
                state.detail = coreLocalized("Declared uncompressed size exceeds limit")
            }
            if let c = state.compressed, c > 0, let u = state.uncompressed, u > 0 {
                let ratio = Double(u) / Double(c)
                if ratio > policy.maxCompressionRatio {
                    state.status = .exceedsResourceLimit
                    state.detail = coreLocalized("Implausible compression ratio")
                }
            }
        }
    }

    /// Without a metadata CSV, every supported activity file is a ready
    /// candidate, in path order, up to the candidate limit.
    private static func fileOnlyCandidates(
        entryPaths: [String],
        entrySizes: [String: (compressed: Int64?, uncompressed: Int64?)],
        policy: WorkoutArchiveSecurityPolicy,
        usedPaths: inout Set<String>
    ) -> [WorkoutArchiveCandidate] {
        var candidates: [WorkoutArchiveCandidate] = []
        var order = 0
        for path in entryPaths.sorted() {
            let format = WorkoutArchiveActivityFormat.detect(fromPath: path)
            guard format != .unsupported else { continue }
            if candidates.count >= policy.maxCandidateActivityCount { break }
            let sizes = entrySizes[path]
            candidates.append(WorkoutArchiveCandidate(
                id: "path:\(path)",
                archiveRelativePath: path,
                format: format,
                compressedBytes: sizes?.compressed,
                declaredUncompressedBytes: sizes?.uncompressed,
                status: .ready,
                isSelectedByDefault: true,
                archiveOrder: order
            ))
            order += 1
            usedPaths.insert(path)
        }
        return candidates
    }

    private static func indexProviderIDs(_ workouts: [RunWorkout]) -> [String: RunWorkout] {
        var map: [String: RunWorkout] = [:]
        for workout in workouts {
            guard let prov = workout.importProvenance,
                  prov.provider == .stravaBulkExport || prov.provider == .singleFile,
                  let pid = prov.providerActivityID,
                  !pid.isEmpty else { continue }
            // Prefer strava bulk provenance for matching.
            if map[pid] == nil || prov.provider == .stravaBulkExport {
                map[pid] = workout
            }
        }
        // Also match any provider activity ID regardless of provider enum.
        for workout in workouts {
            if let pid = workout.importProvenance?.providerActivityID, !pid.isEmpty, map[pid] == nil {
                map[pid] = workout
            }
        }
        return map
    }

    /// Re-evaluate duplicate / provider conflict once content hash is known.
    public static func refineStatus(
        for candidate: WorkoutArchiveCandidate,
        contentSHA256: String,
        existingWorkouts: [RunWorkout],
        seenHashesInBatch: inout Set<String>
    ) -> (WorkoutArchiveCandidateStatus, String?) {
        let hash = contentSHA256.lowercased()
        if !seenHashesInBatch.insert(hash).inserted {
            return (.duplicate, coreLocalized("Duplicate content within this import batch"))
        }
        for workout in existingWorkouts {
            let prov = workout.importProvenance
            if let existingHash = prov?.contentSHA256?.lowercased(), existingHash == hash {
                return (.duplicate, coreLocalized("Already imported (identical file content)"))
            }
            if let pid = candidate.providerActivityID,
               let existingPID = prov?.providerActivityID,
               existingPID == pid {
                if let existingHash = prov?.contentSHA256?.lowercased(), existingHash != hash {
                    return (.providerConflict, coreLocalized("Same activity ID with different content; delete the existing workout first"))
                }
                return (.duplicate, coreLocalized("Already imported (provider activity ID)"))
            }
        }
        return (candidate.status, candidate.statusDetail)
    }
}
