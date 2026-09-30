import Foundation
import RunPlayCore

// MARK: - Progress

/// One step of an Apple Health import pass.
public struct AppleHealthImportProgress: Sendable, Equatable {

    public enum Phase: String, Sendable, Equatable {
        /// Reading a route file and building the workout.
        case importing
        /// Handing a built workout to the library's staging area.
        case staging
        /// Promoting the staged batch into the library.
        case committing
        case completed
        case cancelled
    }

    public var phase: Phase
    public var completedCount: Int
    public var totalCount: Int
    /// Workouts staged so far in this pass.
    public var stagedCount: Int
    /// Candidates left alone because the library already has that run.
    public var skippedCount: Int
    public var failedCount: Int

    public init(
        phase: Phase,
        completedCount: Int = 0,
        totalCount: Int = 0,
        stagedCount: Int = 0,
        skippedCount: Int = 0,
        failedCount: Int = 0
    ) {
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.stagedCount = stagedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }
}

// MARK: - Per-candidate result

/// What happened to one selected candidate.
public struct AppleHealthImportItemResult: Sendable, Equatable {

    public enum Outcome: String, Sendable, Equatable {
        /// Imported with the route the candidate named.
        case imported
        /// Imported without a route because the file was unavailable or its
        /// timestamps did not match this workout.
        case importedWithoutRoute
        /// Left alone: the library already holds a run with this exact window.
        case alreadyInLibrary
        /// Staged, then discarded because the pass never committed.
        ///
        /// Cancellation and a failed commit both land here. The workout was
        /// ready, so calling it a failure would misdescribe what happened, but
        /// the library does not have it, so calling it imported would be untrue.
        case discarded
        case failed
    }

    public enum RouteFallbackReason: String, Sendable, Equatable {
        case routeFileUnavailable
        case routeWindowMismatch
    }

    public let routeFallbackReason: RouteFallbackReason?
    public let wasRouteTrimmed: Bool
    public let candidateID: String
    /// `workoutActivityType` verbatim, so a report can name the activity without
    /// re-deriving it from a formatting rule this layer does not own.
    public let activityType: String
    public let startSeconds: Int64
    public let outcome: Outcome
    /// Why, when the outcome is not a plain `imported`.
    public let detail: String?
    public let importedWorkoutID: UUID?

    public init(
        candidateID: String,
        activityType: String,
        startSeconds: Int64,
        outcome: Outcome,
        detail: String? = nil,
        importedWorkoutID: UUID? = nil,
        routeFallbackReason: RouteFallbackReason? = nil,
        wasRouteTrimmed: Bool = false
    ) {
        self.routeFallbackReason = routeFallbackReason
        self.wasRouteTrimmed = wasRouteTrimmed
        self.candidateID = candidateID
        self.activityType = activityType
        self.startSeconds = startSeconds
        self.outcome = outcome
        self.detail = detail
        self.importedWorkoutID = importedWorkoutID
    }
}

// MARK: - Report

/// Everything one import pass produced, including what it could not do.
///
/// The two archive-level counts are carried through from the scan rather than
/// recomputed, and sit beside the per-item outcomes on purpose: a dropped
/// workout and a route reference naming an absent entry are the only ways an
/// import can come up short without appearing in the selection, so a report that
/// showed only the selected candidates would look complete while the export was
/// not.
public struct AppleHealthImportReport: Sendable {

    public var items: [AppleHealthImportItemResult]
    public var importedWorkoutIDs: [UUID]
    public var selectedWorkoutID: UUID?
    public var wasCancelled: Bool
    public var commitFailed: Bool
    public var errorMessage: String?

    /// Non-running workouts intentionally excluded before review and dedup.
    public var excludedWorkoutsByActivityType: [String: Int]
    public var excludedWorkoutCount: Int { excludedWorkoutsByActivityType.values.reduce(0, +) }

    /// Workouts the export document described that the scan could not build.
    public var droppedWorkoutCount: Int
    /// Workouts that named a route the archive does not contain.
    public var unmatchedRouteReferenceCount: Int

    public var importedCount: Int { items.count { $0.outcome == .imported } }
    public var importedWithoutRouteCount: Int { items.count { $0.outcome == .importedWithoutRoute } }
    /// Successful imports only; rolled-back items never count as imported.
    public var routeWindowMismatchCount: Int {
        items.count { $0.outcome == .importedWithoutRoute && $0.routeFallbackReason == .routeWindowMismatch }
    }
    public var trimmedRouteCount: Int { items.count { $0.outcome == .imported && $0.wasRouteTrimmed } }
    public var alreadyInLibraryCount: Int { items.count { $0.outcome == .alreadyInLibrary } }
    public var failedCount: Int { items.count { $0.outcome == .failed } }
    /// Candidates that were ready to import but were rolled back, so the library
    /// never received them. Never counted as imported.
    public var discardedCount: Int { items.count { $0.outcome == .discarded } }

    /// Whether the library gained anything.
    public var addedWorkoutCount: Int { importedWorkoutIDs.count }

    public init(
        items: [AppleHealthImportItemResult] = [],
        importedWorkoutIDs: [UUID] = [],
        selectedWorkoutID: UUID? = nil,
        wasCancelled: Bool = false,
        commitFailed: Bool = false,
        errorMessage: String? = nil,
        droppedWorkoutCount: Int = 0,
        unmatchedRouteReferenceCount: Int = 0,
        excludedWorkoutsByActivityType: [String: Int] = [:]
    ) {
        self.items = items
        self.importedWorkoutIDs = importedWorkoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.wasCancelled = wasCancelled
        self.commitFailed = commitFailed
        self.errorMessage = errorMessage
        self.droppedWorkoutCount = droppedWorkoutCount
        self.unmatchedRouteReferenceCount = unmatchedRouteReferenceCount
        self.excludedWorkoutsByActivityType = excludedWorkoutsByActivityType
    }
}

// MARK: - Errors

public enum AppleHealthImportError: Error, LocalizedError, Equatable, Sendable {
    case notALocalFile
    /// The library already has a batch import in progress.
    case batchConflict

    public var errorDescription: String? {
        switch self {
        case .notALocalFile:
            return "Only local files can be imported. Choose an export.zip saved on this Mac."
        case .batchConflict:
            return "Another library import is already in progress."
        }
    }
}

// MARK: - Service

/// Turns selected Apple Health candidates into library workouts.
///
/// Persistence goes through the same batch seam the Strava importer uses:
/// `beginBatchImport` / `stageWorkout` / `commitBatchImport`, with
/// `rollbackBatchImport` on every path that does not commit. Nothing here adds a
/// second way for a workout to reach the library, so an import that is cancelled
/// or that fails part-way leaves the library exactly as it was — the staged
/// bytes are discarded, never promoted.
///
/// The routes themselves are read by `AppleHealthArchiveService`, which is the
/// only thing that opens the ZIP.
public actor AppleHealthImportService {

    private let archiveService: AppleHealthArchiveService

    public init(archiveService: AppleHealthArchiveService) {
        self.archiveService = archiveService
    }

    /// Import the candidates a user selected from one scan.
    ///
    /// - Parameters:
    ///   - selectedCandidates: the candidates to import, in the order the review
    ///     presented them. Candidates the user left unchecked are simply absent.
    ///   - scan: the scan those candidates came from. Its report supplies the
    ///     archive-level counts, so the import report can state everything that
    ///     made the export come up short.
    ///   - existingWorkouts: the library as it stands. A candidate whose window
    ///     exactly matches a run in here is skipped, which is what makes
    ///     importing the same export twice add nothing.
    public func importSelection(
        _ selectedCandidates: [AppleHealthWorkoutCandidate],
        from scan: AppleHealthArchiveScanResult,
        archiveAt archiveURL: URL,
        existingWorkouts: [RunWorkout] = [],
        storeActor: WorkoutLibraryStoreActor,
        progress: @Sendable (AppleHealthImportProgress) async -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> AppleHealthImportReport {
        guard archiveURL.isFileURL else { throw AppleHealthImportError.notALocalFile }
        if isCancelled() { throw CancellationError() }

        var report = AppleHealthImportReport(
            droppedWorkoutCount: scan.report.droppedWorkoutCount,
            unmatchedRouteReferenceCount: scan.report.unmatchedRouteReferenceCount,
            excludedWorkoutsByActivityType: scan.report.excludedWorkoutsByActivityType
        )

        // Nothing selected is nothing to do: do not take the library's batch
        // lock, and do not report a cancelled or failed pass over no work.
        if selectedCandidates.isEmpty {
            await progress(AppleHealthImportProgress(phase: .completed))
            return report
        }

        let total = selectedCandidates.count
        await progress(AppleHealthImportProgress(phase: .importing, totalCount: total))

        let libraryWindows = AppleHealthLibraryRunWindow.windows(for: existingWorkouts)

        let batch: WorkoutLibraryBatchToken
        do {
            batch = try await storeActor.beginBatchImport()
        } catch {
            throw AppleHealthImportError.batchConflict
        }

        var items: [AppleHealthImportItemResult] = []
        /// Staged identity only. The full workouts are released as they stage.
        var staged: [(id: UUID, startSeconds: Int64)] = []
        /// Positions in `items` that describe a staged workout. Until the commit
        /// succeeds those workouts are not in the library, so those items are
        /// rewritten if the pass ends any other way.
        var stagedItemIndices: [Int] = []
        var completed = 0
        var skipped = 0
        var failed = 0

        do {
            for candidate in selectedCandidates {
                // Both cancellation contracts, because they are different
                // questions: the task is cancelled when the caller's work is
                // abandoned, and `isCancelled` is the caller's own probe, which
                // is what a review sheet's Cancel button flips. Either one stops
                // the loop before the next candidate is staged.
                if isCancelled() { throw CancellationError() }
                try Task.checkCancellation()
                completed += 1
                await progress(AppleHealthImportProgress(
                    phase: .importing,
                    completedCount: completed,
                    totalCount: total,
                    stagedCount: staged.count,
                    skippedCount: skipped,
                    failedCount: failed
                ))

                // Already imported. The comparison is by window because that is
                // what "the same run" means for an export that carries no
                // per-workout identifier: the same export read twice produces
                // the same windows, so the second pass recognises every one.
                if Self.windowMatchesLibrary(candidate.window, libraryWindows) {
                    skipped += 1
                    items.append(AppleHealthImportItemResult(
                        candidateID: candidate.id,
                        activityType: candidate.window.activityType,
                        startSeconds: candidate.window.startSeconds,
                        outcome: .alreadyInLibrary,
                        detail: "Your library already has a run at this time"
                    ))
                    continue
                }

                let built: BuiltWorkout
                do {
                    built = try await buildWorkout(
                        for: candidate,
                        archiveAt: archiveURL,
                        isCancelled: isCancelled
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    items.append(AppleHealthImportItemResult(
                        candidateID: candidate.id,
                        activityType: candidate.window.activityType,
                        startSeconds: candidate.window.startSeconds,
                        outcome: .failed,
                        detail: error.localizedDescription
                    ))
                    continue
                }

                await progress(AppleHealthImportProgress(
                    phase: .staging,
                    completedCount: completed,
                    totalCount: total,
                    stagedCount: staged.count,
                    skippedCount: skipped,
                    failedCount: failed
                ))

                do {
                    let workout = built.workout
                    let workoutID = workout.id
                    try await storeActor.stageWorkout(workout, in: batch)
                    staged.append((id: workoutID, startSeconds: candidate.window.startSeconds))
                    stagedItemIndices.append(items.count)
                    items.append(AppleHealthImportItemResult(
                        candidateID: candidate.id,
                        activityType: candidate.window.activityType,
                        startSeconds: candidate.window.startSeconds,
                        outcome: built.routeFailure == nil ? .imported : .importedWithoutRoute,
                        detail: built.routeFailure,
                        importedWorkoutID: workoutID,
                        routeFallbackReason: built.fallbackReason,
                        wasRouteTrimmed: built.wasTrimmed
                    ))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed += 1
                    items.append(AppleHealthImportItemResult(
                        candidateID: candidate.id,
                        activityType: candidate.window.activityType,
                        startSeconds: candidate.window.startSeconds,
                        outcome: .failed,
                        detail: error.localizedDescription
                    ))
                }
            }

            let selectedID = Self.selectNewest(staged)

            await progress(AppleHealthImportProgress(
                phase: .committing,
                completedCount: completed,
                totalCount: total,
                stagedCount: staged.count,
                skippedCount: skipped,
                failedCount: failed
            ))

            if staged.isEmpty {
                await storeActor.rollbackBatchImport(batch)
                await progress(AppleHealthImportProgress(phase: .completed))
                report.items = items
                return report
            }

            let committedIDs: [UUID]
            do {
                committedIDs = try await storeActor.commitBatchImport(
                    batch,
                    selectedWorkoutID: selectedID
                )
            } catch {
                await storeActor.rollbackBatchImport(batch)
                report.items = Self.markingDiscarded(
                    items,
                    at: stagedItemIndices,
                    detail: error.localizedDescription
                )
                report.commitFailed = true
                report.errorMessage = error.localizedDescription
                await progress(AppleHealthImportProgress(phase: .completed))
                return report
            }

            await progress(AppleHealthImportProgress(
                phase: .completed,
                completedCount: completed,
                totalCount: total,
                stagedCount: committedIDs.count,
                skippedCount: skipped,
                failedCount: failed
            ))

            report.items = items
            report.importedWorkoutIDs = committedIDs
            report.selectedWorkoutID = selectedID
            return report
        } catch is CancellationError {
            await storeActor.rollbackBatchImport(batch)
            await progress(AppleHealthImportProgress(phase: .cancelled))
            report.items = Self.markingDiscarded(
                items,
                at: stagedItemIndices,
                detail: "Cancelled before the import was committed"
            )
            report.wasCancelled = true
            return report
        } catch {
            await storeActor.rollbackBatchImport(batch)
            throw error
        }
    }

    // MARK: - Building one workout

    /// A built workout plus why it has no route, when it does not.
    private struct BuiltWorkout {
        var workout: RunWorkout
        var routeFailure: String?
        var fallbackReason: AppleHealthImportItemResult.RouteFallbackReason? = nil
        var wasTrimmed = false
    }

    private func buildWorkout(
        for candidate: AppleHealthWorkoutCandidate,
        archiveAt archiveURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> BuiltWorkout {
        guard let routePath = candidate.routeArchivePath else {
            return BuiltWorkout(workout: Self.routeLessWorkout(for: candidate), routeFailure: nil)
        }

        do {
            let gpx = try await archiveService.routeGPXData(
                forArchivePath: routePath,
                archiveAt: archiveURL,
                isCancelled: isCancelled
            )
            return try Self.routedWorkout(for: candidate, gpx: gpx, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The candidate named a route the archive cannot give us. The scan
            // already counts these, and a workout whose route is missing is
            // still a run the user did, so it is imported from the export's own
            // totals with the reason carried on the item — never dropped, and
            // never silently imported as though it had a route.
            return BuiltWorkout(
                workout: Self.routeLessWorkout(for: candidate),
                routeFailure: "Imported without its route: \(error.localizedDescription)",
                fallbackReason: .routeFileUnavailable
            )
        }
    }

    /// A workout built from the export's own numbers, with no coordinates.
    ///
    /// The distance is the export's reported total and says so, because nothing
    /// here measured it; the duration is the window the export gave the workout.
    private static func routeLessWorkout(
        for candidate: AppleHealthWorkoutCandidate
    ) -> RunWorkout {
        let elapsed = Double(max(0, candidate.window.endSeconds - candidate.window.startSeconds))

        var summary = RunSummary()
        summary.totalDistanceMeters = max(0, candidate.sourceDistanceMeters ?? 0)
        summary.totalElapsedSeconds = elapsed
        summary.totalActiveSeconds = elapsed
        summary.distanceProvenance = .sourceReported

        return RunWorkout(
            metadata: Self.metadata(for: candidate),
            source: .healthKit,
            routePoints: [],
            summary: summary,
            analysisVersion: RunWorkout.currentAnalysisVersion,
            importProvenance: Self.provenance(for: candidate, contentSHA256: nil),
            heartRateSeries: Self.heartRateSeries(for: candidate, routePoints: [])
        )
    }

    /// A workout built from the GPX file the export names.
    ///
    /// Parsing goes through the ordinary GPX importer, so the geometry, splits
    /// and distance come from the same code every other GPX import uses. The
    /// route is judged against this workout's window before its metadata is
    /// replaced. Shared file references are therefore judged independently.
    private static func routedWorkout(
        for candidate: AppleHealthWorkoutCandidate,
        gpx: Data,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> BuiltWorkout {
        let filename = candidate.routeArchivePath.map { ($0 as NSString).lastPathComponent }
        let input = WorkoutImportInput(
            data: gpx,
            fileExtension: "gpx",
            suggestedName: filename ?? "route.gpx",
            provenance: provenance(
                for: candidate,
                contentSHA256: ContentHasher.sha256Hex(of: gpx),
                originalFilename: filename
            )
        )

        var workout = try WorkoutImporterFactory.importWorkout(from: input)
        var wasTrimmed = false
        switch AppleHealthRouteWindowPolicy.decision(for: workout.routePoints, window: candidate.window) {
        case .keep:
            break // Preserve the ordinary GPX route and summary byte for byte.
        case .mismatch:
            return BuiltWorkout(
                workout: routeLessWorkout(for: candidate),
                routeFailure: "Imported without a map because its route file did not match the run's time",
                fallbackReason: .routeWindowMismatch
            )
        case .trim(let range):
            workout.routePoints = Array(workout.routePoints[range])
            // The new first point has no preceding interval in this route.
            workout.routePoints[0].speedMetersPerSecond = nil
            workout.routePoints[0].paceSecondsPerKilometer = nil
            try WorkoutAnalyzer().normalizeAndAnalyze(
                &workout, distancePolicy: .computeFromCoordinates, isCancelled: isCancelled
            )
            wasTrimmed = true
        }
        workout.source = .healthKit
        workout.metadata = metadata(for: candidate)
        workout.heartRateSeries = heartRateSeries(
            for: candidate,
            routePoints: workout.routePoints
        )
        return BuiltWorkout(workout: workout, routeFailure: nil, wasTrimmed: wasTrimmed)
    }

    private static func metadata(for candidate: AppleHealthWorkoutCandidate) -> WorkoutMetadata {
        WorkoutMetadata(
            // No name: the export gives the workout no title, and the library's
            // own display rule falls back to the run's date, which is what a
            // route-less run and a routed one should both show.
            startDate: Date(timeIntervalSince1970: TimeInterval(candidate.window.startSeconds)),
            endDate: Date(timeIntervalSince1970: TimeInterval(candidate.window.endSeconds)),
            recordedUTCOffsetSeconds: candidate.window.utcOffsetSeconds
        )
    }

    private static func provenance(
        for candidate: AppleHealthWorkoutCandidate,
        contentSHA256: String?,
        originalFilename: String? = nil
    ) -> WorkoutImportProvenance {
        WorkoutImportProvenance(
            provider: .appleHealthExport,
            // The export has no per-workout identifier to quote, so this records
            // the importer's own content-derived candidate identity instead.
            providerActivityID: candidate.id,
            contentSHA256: contentSHA256,
            originalFilename: originalFilename
        )
    }

    /// The candidate's joined heart rate, in the standalone-series shape.
    ///
    /// Produced only when the route carries no heart rate of its own, which is
    /// the single-source invariant `RunWorkout` enforces in its initializer.
    /// Setting the property directly would bypass that check, so the check is
    /// made here instead.
    ///
    /// `segmentIndex` stays 0: an Apple Health workout window is one continuous
    /// recording, and this layer has nothing that could identify a pause inside
    /// it, so inventing a second segment would be a guess.
    private static func heartRateSeries(
        for candidate: AppleHealthWorkoutCandidate,
        routePoints: [RoutePoint]
    ) -> [HeartRateSample]? {
        guard !candidate.heartRate.isEmpty else { return nil }
        let routeCarriesHeartRate = routePoints.contains { point in
            point.heartRateBPM.map(MetricValidation.isValidHeartRate) ?? false
        }
        guard !routeCarriesHeartRate else { return nil }

        let start = candidate.window.startSeconds
        return candidate.heartRate.map { reading in
            HeartRateSample(
                // Relative to the workout's own start. A reading that began
                // before the window but overlaps it lands at a negative offset;
                // `RunWorkout`'s series normalization clamps those monotonically.
                elapsedSeconds: Double(reading.startSeconds - start),
                heartRateBPM: reading.beatsPerMinute,
                segmentIndex: 0
            )
        }
    }

    // MARK: - Selection

    /// Whether a candidate's window is exactly a run the library already has.
    ///
    /// Exact, not overlapping: the import must not skip a genuinely different
    /// run that merely shares some minutes with one already stored. Overlap in
    /// the library is a question for the review, which flags it and starts the
    /// candidate unchecked.
    private static func windowMatchesLibrary(
        _ window: AppleHealthWorkoutWindow,
        _ libraryWindows: [AppleHealthLibraryRunWindow]
    ) -> Bool {
        libraryWindows.contains { run in
            run.startSeconds == window.startSeconds && run.endSeconds == window.endSeconds
        }
    }

    /// Rewrite the items that describe a staged workout as discarded.
    ///
    /// Used on the two paths that roll back. The workout was built and staged,
    /// so `failed` would be the wrong word; the library does not have it, so
    /// leaving `imported` would be a claim the caller cannot verify and that a
    /// plain-language report would state wrongly.
    private static func markingDiscarded(
        _ items: [AppleHealthImportItemResult],
        at indices: [Int],
        detail: String
    ) -> [AppleHealthImportItemResult] {
        var updated = items
        for index in indices where updated.indices.contains(index) {
            let item = updated[index]
            updated[index] = AppleHealthImportItemResult(
                candidateID: item.candidateID,
                activityType: item.activityType,
                startSeconds: item.startSeconds,
                outcome: .discarded,
                detail: detail
            )
        }
        return updated
    }

    /// The newest staged workout, so the library opens on what was just imported.
    private static func selectNewest(
        _ staged: [(id: UUID, startSeconds: Int64)]
    ) -> UUID? {
        var best: (id: UUID, startSeconds: Int64)?
        for entry in staged {
            guard let current = best else {
                best = entry
                continue
            }
            // Later stage order wins a tie, so the last-imported duplicate is
            // the one selected rather than an arbitrary earlier one.
            if entry.startSeconds >= current.startSeconds { best = entry }
        }
        return best?.id
    }
}
