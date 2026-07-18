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
                    warnings.append("Candidate activity limit reached; remaining rows skipped.")
                    break
                }

                let pathMatch: WorkoutArchivePathValidator.PathMatchResult
                if let filename = row.filename, !filename.isEmpty {
                    pathMatch = WorkoutArchivePathValidator.matchPath(filename, index: pathIndex)
                } else {
                    pathMatch = .none
                }

                var archivePath = ""
                var format: WorkoutArchiveActivityFormat = .unsupported
                var status: WorkoutArchiveCandidateStatus = .ready
                var detail: String? = nil
                var compressed: Int64? = nil
                var uncompressed: Int64? = nil

                switch pathMatch {
                case .exact(let path), .caseInsensitive(let path):
                    archivePath = path
                    format = WorkoutArchiveActivityFormat.detect(fromPath: path)
                    let sizes = entrySizes[path]
                    compressed = sizes?.compressed
                    uncompressed = sizes?.uncompressed
                    usedPaths.insert(path)
                case .ambiguous:
                    archivePath = row.filename ?? ""
                    status = .unsafeArchiveEntry
                    detail = "Ambiguous path match for activity file"
                case .none:
                    if let filename = row.filename, !filename.isEmpty {
                        archivePath = filename
                        format = WorkoutArchiveActivityFormat.detect(fromPath: filename)
                        status = .missingActivityFile
                        detail = "Activity file not found in archive"
                    } else {
                        archivePath = ""
                        status = .missingActivityFile
                        detail = hasFilenameColumn
                            ? "No filename for activity"
                            : "No filename column; activity file not mapped"
                    }
                }

                if status == .ready {
                    if format == .unsupported {
                        status = .unsupportedFormat
                        detail = "Unsupported activity file format"
                    }
                }

                let typeClass = StravaActivityTypePolicy.classify(row.activityType)
                if status == .ready {
                    switch typeClass {
                    case .running, .walkOrHike:
                        break
                    case .unsupported:
                        status = .unsupportedActivityType
                        detail = "Activity type “\(row.activityType ?? "unknown")” is not a running activity"
                    case .unknown:
                        status = .unsupportedActivityType
                        detail = "Unknown activity type “\(row.activityType ?? "")”"
                    }
                }

                if let pid = row.activityID, !pid.isEmpty {
                    if !seenProviderIDs.insert(pid).inserted {
                        status = .duplicate
                        detail = "Duplicate provider activity ID within archive"
                    } else if existingByProviderID[pid] != nil {
                        // Scan-time: treat matching provider IDs as duplicates.
                        // Import-time refineStatus distinguishes providerConflict via content hash.
                        status = .duplicate
                        detail = "Already imported (provider activity ID)"
                    }
                }

                // Size limits
                if status == .ready || status == .possibleDuplicate {
                    if let c = compressed, c > policy.maxCompressedEntryBytes {
                        status = .exceedsResourceLimit
                        detail = "Compressed entry exceeds size limit"
                    }
                    if let u = uncompressed, u > policy.maxUncompressedEntryBytes {
                        status = .exceedsResourceLimit
                        detail = "Declared uncompressed size exceeds limit"
                    }
                    if let c = compressed, c > 0, let u = uncompressed, u > 0 {
                        let ratio = Double(u) / Double(c)
                        if ratio > policy.maxCompressionRatio {
                            status = .exceedsResourceLimit
                            detail = "Implausible compression ratio"
                        }
                    }
                }

                let selected = status.isImportableByDefault
                    && StravaActivityTypePolicy.isSelectedByDefault(row.activityType)

                let id = row.activityID.map { "strava:\($0)" }
                    ?? "row:\(row.rowIndex):\(archivePath)"

                candidates.append(WorkoutArchiveCandidate(
                    id: id,
                    archiveRelativePath: archivePath,
                    providerActivityID: row.activityID,
                    activityName: row.activityName,
                    activityType: row.activityType,
                    activityDate: row.activityDate,
                    format: format,
                    compressedBytes: compressed,
                    declaredUncompressedBytes: uncompressed,
                    status: status,
                    statusDetail: detail,
                    isSelectedByDefault: selected,
                    archiveOrder: order
                ))
                order += 1
            }
        } else {
            // No metadata CSV: fall back to activity files only (weaker recognition).
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
        }

        return (candidates, warnings)
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
            return (.duplicate, "Duplicate content within this import batch")
        }
        for workout in existingWorkouts {
            let prov = workout.importProvenance
            if let existingHash = prov?.contentSHA256?.lowercased(), existingHash == hash {
                return (.duplicate, "Already imported (identical file content)")
            }
            if let pid = candidate.providerActivityID,
               let existingPID = prov?.providerActivityID,
               existingPID == pid {
                if let existingHash = prov?.contentSHA256?.lowercased(), existingHash != hash {
                    return (.providerConflict, "Same activity ID with different content; delete the existing workout first")
                }
                return (.duplicate, "Already imported (provider activity ID)")
            }
        }
        return (candidate.status, candidate.statusDetail)
    }
}
