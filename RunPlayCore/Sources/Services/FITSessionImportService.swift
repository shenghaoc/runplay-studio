import Foundation

/// Scans a FIT container and reports every session it contains.
public protocol FITFileScanning: Sendable {
    func scanFITFile(
        at url: URL,
        existingWorkouts: [RunWorkout],
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void
    ) async throws -> FITSessionScanResult
}

/// Imports selected FIT sessions as separate workouts in one staged transaction.
public protocol FITSessionBatchImporting: Sendable {
    func importSessions(
        _ selection: FITSessionImportSelection,
        from url: URL,
        existingWorkouts: [RunWorkout],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void
    ) async throws -> FITSessionBatchImportReport
}

/// Actor that owns multi-session FIT scanning and batch import.
///
/// Never runs on the main actor. Parses the container **once per phase** and
/// decodes every selected session from that single `FITDecodedFile`; the review
/// sheet holds only lightweight descriptors while it is open.
///
/// `WorkoutImportServicing.importWorkout` is untouched: ordinary one-session
/// FIT, GPX, TCX, JSON, and archive entries still return exactly one workout.
public actor FITSessionImportService: FITFileScanning, FITSessionBatchImporting {

    public let policy: FITMultiSessionImportPolicy
    private let digest: any ContentDigesting

    public init(
        digest: any ContentDigesting,
        policy: FITMultiSessionImportPolicy = .default
    ) {
        self.digest = digest
        self.policy = policy
    }

    // MARK: - Scan

    public func scanFITFile(
        at url: URL,
        existingWorkouts: [RunWorkout],
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void = { _ in }
    ) async throws -> FITSessionScanResult {
        await progress(WorkoutBatchImportProgress(phase: .openingArchive))
        try Task.checkCancellation()

        let data = try readContainer(at: url)
        let containerSHA256 = digest.sha256Hex(of: data)
        let fileName = url.lastPathComponent

        try Task.checkCancellation()
        await progress(WorkoutBatchImportProgress(phase: .scanningEntries))

        let decodedFile = try parseContainer(data)

        // Zero or one session message keeps the existing single-workout path.
        // A legacy sessionless FIT file must never open a review sheet.
        guard decodedFile.sessions.count > 1 else {
            await progress(WorkoutBatchImportProgress(phase: .awaitingSelection))
            return FITSessionScanResult(
                routing: .direct,
                fileName: fileName,
                containerSHA256: containerSHA256,
                totalSessionMessageCount: decodedFile.sessions.count
            )
        }

        guard decodedFile.sessions.count <= policy.maxScannedSessions else {
            throw FITSessionImportError.tooManySessions(policy.maxScannedSessions)
        }

        let index = FITSessionMessageIndex.build(decodedFile: decodedFile)
        var result = try makeScanResult(
            index: index,
            containerSHA256: containerSHA256,
            fileName: fileName,
            existingWorkouts: existingWorkouts
        )
        result.routing = .review

        await progress(WorkoutBatchImportProgress(
            phase: .awaitingSelection,
            totalCount: result.candidates.count
        ))
        return result
    }

    // MARK: - Import

    public func importSessions(
        _ selection: FITSessionImportSelection,
        from url: URL,
        existingWorkouts: [RunWorkout],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void = { _ in }
    ) async throws -> FITSessionBatchImportReport {
        do {
            return try await performImport(
                selection,
                from: url,
                existingWorkouts: existingWorkouts,
                storeActor: storeActor,
                progress: progress
            )
        } catch is CancellationError {
            // Cancellation before the transaction opens still reports a
            // structured cancelled result rather than a bare error.
            await progress(WorkoutBatchImportProgress(phase: .cancelled))
            return FITSessionBatchImportReport(wasCancelled: true)
        }
    }

    private func performImport(
        _ selection: FITSessionImportSelection,
        from url: URL,
        existingWorkouts: [RunWorkout],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (WorkoutBatchImportProgress) async -> Void
    ) async throws -> FITSessionBatchImportReport {
        try Task.checkCancellation()

        let selected = selection.selectedCandidates
        guard selected.count <= policy.maxSelectedSessions else {
            throw FITSessionImportError.tooManySelectedSessions(policy.maxSelectedSessions)
        }

        await progress(WorkoutBatchImportProgress(
            phase: .openingArchive,
            totalCount: selected.count
        ))

        // Reopen and reparse once. The review sheet deliberately does not hold
        // the decoded container open while the user deliberates.
        let data = try readContainer(at: url)
        let containerSHA256 = digest.sha256Hex(of: data)
        let decodedFile = try parseContainer(data)
        let index = FITSessionMessageIndex.build(decodedFile: decodedFile)

        // Re-derive statuses from the file as it is *now*, so a container that
        // changed between review and import cannot import stale selections.
        let liveCandidates = try makeScanResult(
            index: index,
            containerSHA256: containerSHA256,
            fileName: url.lastPathComponent,
            existingWorkouts: existingWorkouts
        ).candidates
        var liveByID: [String: FITSessionDescriptor] = [:]
        for candidate in liveCandidates {
            liveByID[candidate.providerActivityID] = candidate
        }

        let batch: WorkoutLibraryBatchToken
        do {
            batch = try await storeActor.beginBatchImport()
        } catch {
            throw FITSessionImportError.batchConflict
        }

        var items: [FITSessionImportItemResult] = []
        /// Lightweight staged metadata only — full workouts are released after
        /// staging so a large batch never holds every route array at once.
        var stagedSummaries: [(id: UUID, startDate: Date?, sourceIndex: Int)] = []
        var stagedIDsInBatch = Set<String>()
        var completed = 0
        var failed = 0
        var skipped = 0
        let importer = FITImporter()

        func makeProgress(_ phase: WorkoutBatchImportPhase, name: String?) -> WorkoutBatchImportProgress {
            WorkoutBatchImportProgress(
                phase: phase,
                completedCount: completed,
                totalCount: selected.count,
                currentFilename: name,
                stagedCount: stagedSummaries.count,
                skippedCount: skipped,
                failedCount: failed
            )
        }

        do {
            for candidate in selected {
                try Task.checkCancellation()
                completed += 1
                await progress(makeProgress(.importing, name: candidate.displayName))

                // The live descriptor is authoritative. A missing entry means
                // this session no longer exists in the container.
                guard let live = liveByID[candidate.providerActivityID] else {
                    failed += 1
                    items.append(FITSessionImportItemResult(
                        candidateID: candidate.providerActivityID,
                        sourceIndex: candidate.sourceIndex,
                        sessionName: candidate.displayName,
                        status: .parseFailed,
                        detail: "This session is no longer present in the file."
                    ))
                    continue
                }

                guard live.status == .ready else {
                    // Force-selected or newly-invalid candidates are reported,
                    // never imported.
                    if live.status == .parseFailed {
                        failed += 1
                    } else {
                        skipped += 1
                    }
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: live.displayName,
                        status: live.status,
                        detail: live.statusDetail
                    ))
                    continue
                }

                // Within-batch identity guard: never stage two workouts that
                // would claim the same provider identity.
                guard stagedIDsInBatch.insert(live.providerActivityID).inserted else {
                    skipped += 1
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: live.displayName,
                        status: .duplicate,
                        detail: "Duplicate session identity within this file."
                    ))
                    continue
                }

                let provenance = WorkoutImportProvenance(
                    provider: .fitMultiSessionFile,
                    providerActivityID: live.providerActivityID,
                    // Every sibling shares the container, so a whole-file hash
                    // here would make them look like the same activity.
                    contentSHA256: nil,
                    originalFilename: url.lastPathComponent,
                    sourceContainerSHA256: containerSHA256
                )

                let workout: RunWorkout
                do {
                    workout = try importer.buildSession(
                        index: index,
                        sessionIndex: live.sourceIndex,
                        suggestedName: live.displayName,
                        provenance: provenance
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as WorkoutImportError {
                    failed += 1
                    let status: FITSessionCandidateStatus
                    if case .missingData = error {
                        status = .noGPSRoute
                    } else {
                        status = .parseFailed
                    }
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: live.displayName,
                        status: status,
                        detail: error.localizedDescription
                    ))
                    continue
                } catch {
                    failed += 1
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: live.displayName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                await progress(makeProgress(.staging, name: live.displayName))
                try Task.checkCancellation()

                do {
                    let workoutID = workout.id
                    let startDate = workout.metadata.startDate
                    let displayName = workout.displayName
                    try await storeActor.stageWorkout(workout, in: batch)
                    // Release the full workout; retain only report metadata.
                    stagedSummaries.append((
                        id: workoutID,
                        startDate: startDate,
                        sourceIndex: live.sourceIndex
                    ))
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: displayName,
                        status: .ready,
                        detail: nil,
                        importedWorkoutID: workoutID
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    stagedIDsInBatch.remove(live.providerActivityID)
                    items.append(FITSessionImportItemResult(
                        candidateID: live.providerActivityID,
                        sourceIndex: live.sourceIndex,
                        sessionName: live.displayName,
                        status: .parseFailed,
                        detail: error.localizedDescription
                    ))
                }
            }

            try Task.checkCancellation()
            let selectedWorkoutID = Self.selectNewest(stagedSummaries)
            await progress(makeProgress(.committing, name: nil))

            guard !stagedSummaries.isEmpty else {
                await storeActor.rollbackBatchImport(batch)
                await progress(makeProgress(.completed, name: nil))
                return FITSessionBatchImportReport(items: items)
            }

            let committedIDs: [UUID]
            do {
                committedIDs = try await storeActor.commitBatchImport(
                    batch,
                    selectedWorkoutID: selectedWorkoutID
                )
            } catch {
                // Commit failed: nothing is imported. Items keep their staged
                // status but `importedWorkoutIDs` stays empty, so the report
                // never claims a workout was imported.
                await storeActor.rollbackBatchImport(batch)
                return FITSessionBatchImportReport(
                    items: items,
                    importedWorkoutIDs: [],
                    selectedWorkoutID: nil,
                    wasCancelled: false,
                    commitFailed: true,
                    errorMessage: error.localizedDescription
                )
            }

            await progress(makeProgress(.completed, name: nil))
            return FITSessionBatchImportReport(
                items: items,
                importedWorkoutIDs: committedIDs,
                selectedWorkoutID: selectedWorkoutID
            )
        } catch is CancellationError {
            await storeActor.rollbackBatchImport(batch)
            await progress(WorkoutBatchImportProgress(phase: .cancelled))
            return FITSessionBatchImportReport(
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

    // MARK: - Candidate construction

    /// Build descriptors for every session in the container, in source order.
    ///
    /// Shared by scan and import so a candidate can never be classified one way
    /// during review and another way during import.
    func makeScanResult(
        index: FITSessionMessageIndex,
        containerSHA256: String,
        fileName: String,
        existingWorkouts: [RunWorkout]
    ) throws -> FITSessionScanResult {
        let decodedFile = index.decodedFile
        let sessions = decodedFile.sessions
        let baseName = (fileName as NSString).deletingPathExtension

        var existingSessionIDs = Set<String>()
        for workout in existingWorkouts {
            guard let provenance = workout.importProvenance,
                  provenance.provider == .fitMultiSessionFile,
                  let id = provenance.providerActivityID
            else {
                continue
            }
            existingSessionIDs.insert(id)
        }

        let overLimit = decodedFile.records.count > policy.maxRecords
            || decodedFile.events.count > policy.maxEvents
            || decodedFile.laps.count > policy.maxLaps

        var candidates: [FITSessionDescriptor] = []
        candidates.reserveCapacity(sessions.count)
        var seenIDs = Set<String>()
        var warnings: [String] = []

        for sourceIndex in sessions.indices {
            if sourceIndex % policy.cancellationCheckStride == 0 {
                try Task.checkCancellation()
            }
            let session = sessions[sourceIndex]
            let classification = FITSportPolicy.classify(session: session)
            let range = index.prepared.range(at: sourceIndex)
            let boundaryProblem = index.prepared.problem(at: sourceIndex)
            let isAmbiguous = index.prepared.ambiguousIndexes.contains(sourceIndex)
            let gpsRecordCount = index.gpsRecordCount(for: sourceIndex)
            let lapCount = index.lapCount(for: sourceIndex)

            let providerActivityID = FITSessionIdentity.providerActivityID(
                containerSHA256: containerSHA256,
                sourceIndex: sourceIndex,
                session: session,
                digest: digest
            )
            let isUniqueWithinFile = seenIDs.insert(providerActivityID).inserted

            let startDate = range.map { FITParser.timestampToDate($0.start) }
                ?? FITParser.timestampIfValid(session.startTime).map(FITParser.timestampToDate)
            let endDate = range.map { FITParser.timestampToDate($0.end) }
                ?? FITParser.timestampIfValid(session.timestamp).map(FITParser.timestampToDate)

            var status: FITSessionCandidateStatus = .ready
            var detail: String?

            if classification == .unsupported {
                status = .unsupportedSport
                detail = "\(FITSportPolicy.displayName(sport: session.sport)) sessions are not supported."
            } else if !isUniqueWithinFile {
                status = .duplicate
                detail = "Another session in this file produced the same identity."
            } else if existingSessionIDs.contains(providerActivityID) {
                status = .duplicate
                detail = "This session is already in your library."
            } else if let boundaryProblem {
                status = .invalidBoundaries
                detail = boundaryProblem.detail
            } else if isAmbiguous {
                status = .ambiguousAttribution
                detail = "This session's time range overlaps another session, so its data cannot be separated reliably."
            } else if overLimit {
                status = .exceedsResourceLimit
                detail = "This file exceeds the supported record, event, or lap limit."
            } else if gpsRecordCount == 0 {
                status = .noGPSRoute
                detail = "No GPS records could be attributed to this session."
            }

            if status == .ready, classification == .unknownTreatedAsRunning {
                detail = "This session has no recognised sport and is being treated as a run."
            }

            candidates.append(FITSessionDescriptor(
                sourceIndex: sourceIndex,
                startDate: startDate,
                endDate: endDate,
                sport: classification,
                sportDescription: FITSportPolicy.displayName(sport: session.sport),
                subSportDescription: FITSportPolicy.subSportDescription(subSport: session.subSport),
                elapsedSeconds: scaledSeconds(session.totalElapsedTime),
                timerSeconds: scaledSeconds(session.totalTimerTime),
                reportedDistanceMeters: session.totalDistance.flatMap {
                    $0 == FITParser.invalidUint32 ? nil : FITParser.scaledDistanceToMeters($0)
                },
                gpsRecordCount: gpsRecordCount,
                recordedLapCount: lapCount,
                status: status,
                statusDetail: detail,
                isSelectedByDefault: status.isImportableByDefault,
                providerActivityID: providerActivityID,
                displayName: displayName(
                    baseName: baseName,
                    startDate: startDate,
                    sourceIndex: sourceIndex
                )
            ))
        }

        let unattributed = index.unattributedRecordCount()
        if unattributed > 0 {
            warnings.append(
                "\(unattributed) record(s) could not be attributed to any session and were excluded."
            )
        }
        if !index.prepared.ambiguousIndexes.isEmpty {
            warnings.append(
                "\(index.prepared.ambiguousIndexes.count) session(s) overlap in time and cannot be separated reliably."
            )
        }

        return FITSessionScanResult(
            routing: .review,
            fileName: fileName,
            containerSHA256: containerSHA256,
            totalSessionMessageCount: sessions.count,
            candidates: candidates,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private func readContainer(at url: URL) throws -> Data {
        // Local files only: no HTTP, remote schemes, string paths, or directories.
        guard url.isFileURL else {
            throw FITSessionImportError.notLocalFile
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw FITSessionImportError.cannotReadFile("The file could not be found.")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FITSessionImportError.cannotReadFile(error.localizedDescription)
        }
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= policy.maxContainerBytes else {
            throw FITSessionImportError.containerTooLarge
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw FITSessionImportError.cannotReadFile(error.localizedDescription)
        }
    }

    private func parseContainer(_ data: Data) throws -> FITDecodedFile {
        do {
            return try FITParser.parse(data: data, isCancelled: { Task.isCancelled })
        } catch let error as FITError {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw WorkoutImportError.parsingError(error.localizedDescription)
        }
    }

    private func scaledSeconds(_ milliseconds: UInt32?) -> Double? {
        guard let milliseconds, milliseconds != FITParser.invalidUint32 else { return nil }
        return Double(milliseconds) / 1_000
    }

    /// Concise candidate name. Never contains a UUID, a provider fingerprint,
    /// an absolute path, or a raw FIT field value.
    private func displayName(baseName: String, startDate: Date?, sourceIndex: Int) -> String {
        let prefix = baseName.isEmpty ? "FIT file" : baseName
        let suffix: String
        if let startDate {
            suffix = Self.candidateDateFormatter.string(from: startDate)
        } else {
            suffix = "Run \(sourceIndex + 1)"
        }
        return policy.clampDisplayName("\(prefix) — \(suffix)")
    }

    /// Fixed-locale formatter: candidate names are stable across locales and
    /// are never used as identity input.
    private static let candidateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func selectNewest(
        _ staged: [(id: UUID, startDate: Date?, sourceIndex: Int)]
    ) -> UUID? {
        guard !staged.isEmpty else { return nil }
        // Newest by start date; FIT source order is the deterministic tie break.
        return staged.max { lhs, rhs in
            let left = lhs.startDate ?? .distantPast
            let right = rhs.startDate ?? .distantPast
            if left != right { return left < right }
            return lhs.sourceIndex < rhs.sourceIndex
        }?.id
    }
}
