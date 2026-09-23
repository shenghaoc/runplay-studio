import Foundation
import RunPlayCore
import RunPlayPlatform

/// The result of one watch-folder import execution, with display detail.
struct WatchFolderExecutionResult: Sendable {
    let outcome: WatchFolderImportOutcome
    let failureDetail: String

    static let imported = WatchFolderExecutionResult(outcome: .imported, failureDetail: "")
    static let duplicate = WatchFolderExecutionResult(outcome: .skippedDuplicate, failureDetail: "")

    static func failed(_ detail: String) -> WatchFolderExecutionResult {
        WatchFolderExecutionResult(outcome: .failed, failureDetail: detail)
    }

    static let awaitingReview = WatchFolderExecutionResult(outcome: .awaitingReview, failureDetail: "")
}

/// Orchestrates watch-folder scanning, settling, dedupe, and import hand-off.
///
/// Design rules (mirroring the `AppSessionController` task-ownership
/// precedent):
///
/// - The periodic poll is the **authoritative** detector; DispatchSource
///   events only wake it early. Missed events degrade to poll latency.
/// - Hashing and directory listing run detached from the main actor;
///   published state mutates only on the main actor.
/// - Import execution is delegated to `AppState` so the existing pipeline
///   (training-load restamp, persistence, library refresh, tags) is reused;
///   the coordinator never duplicates import logic.
/// - A file is ledgered exactly once per outcome, including failures, so a
///   bad file never retries forever. Files awaiting FIT review are queued,
///   not ledgered, until the review resolves.
/// - Steady-state duplicates (content ledgered long ago, file still in the
///   folder) are silent: the recent-imports panel records events, not
///   directory inventory.
@MainActor
final class WatchFolderCoordinator: ObservableObject {

    // MARK: - Published state

    /// Bounded recent-import rows, newest first.
    @Published private(set) var recentImports: [WatchFolderImportRecord] = []

    /// Configured folders as persisted.
    @Published private(set) var folders: [WatchFolderConfiguration] = []

    /// Master pause: when true no folder is scanned or imported.
    @Published private(set) var isPaused = false

    /// The queued FIT file surfaced by the non-modal banner, if any.
    @Published private(set) var pendingReviewBanner: PendingReviewBanner?

    /// Folders that were watchable but whose directory is currently gone
    /// (volume ejected, folder deleted or moved, permission revoked). The
    /// settings pane shows these as **Unavailable** rather than silently
    /// listing them as watching; watching resumes automatically when the
    /// directory returns.
    @Published private(set) var unavailableFolderIDs: Set<UUID> = []

    struct PendingReviewBanner: Equatable, Sendable {
        /// Folder that owns the queued file, so removing that folder can drop
        /// exactly this banner.
        let folderID: UUID
        let folderName: String
        let fileName: String
        let fileURL: URL
    }

    // MARK: - Collaborators (injected)

    private let store: FileWatchFolderStore
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let watcherFactory: () -> any DirectoryWatching
    private let policy: WatchFolderScanPolicy
    private let scanner: WatchFolderScanner

    /// Executes one import through the existing AppState pipeline.
    /// Returns the outcome; the coordinator owns ledgering either way.
    var importExecutor: ((URL, WatchFolderConfiguration) async -> WatchFolderExecutionResult)?
    /// Presents the multi-session FIT review sheet for a queued file
    /// (user-initiated from the banner).
    var reviewPresenter: ((URL) -> Void)?
    /// Whether AppState can accept a background import right now (no manual
    /// import/scan/sheet in flight). When false the file stays a candidate.
    var canImportNow: () -> Bool = { true }

    /// Announcement sink. Injected by `AppState` so watch-folder outcomes are
    /// spoken. Announcing is aggregated **once per scan pass**, never per file
    /// and never per poll when nothing changed: a background watcher that spoke
    /// for every row would be exactly the announcement spam the accessibility
    /// policy forbids. Nil in tests that do not assert speech.
    var announce: ((AccessibilityAnnouncementEvent) -> Void)?

    // MARK: - Runtime state

    private struct ActiveFolder {
        let configuration: WatchFolderConfiguration
        let resolvedURL: URL
        let scopedAccess: SecurityScopedBookmarkStore.ScopedAccess?
        let watchHandle: (any DirectoryWatchHandle)?
    }

    /// Sendable snapshot handed to the detached scan task.
    private struct FolderScanInput: Hashable, Sendable {
        let folderID: UUID
        let displayName: String
        let resolvedURL: URL
    }

    /// Settled-file scan output for one folder (Sendable tuple stand-in).
    private struct FolderScanOutput: Sendable {
        let input: FolderScanInput
        let settledFiles: [WatchFolderScanner.DiscoveredFile]
        /// False when the directory could not be listed at all this pass
        /// (volume ejected, folder deleted or moved, permission revoked).
        /// Distinguishes "gone" from "empty", which zero files alone cannot.
        let isListable: Bool
    }

    /// Result of one detached scan: settled files plus tracker snapshots.
    private struct ScanPassResult: Sendable {
        let outputs: [FolderScanOutput]
        let trackers: [TrackerSnapshot]
    }

    /// Settle-tracker snapshot that crosses into the detached scan and back.
    private struct TrackerSnapshot: Sendable {
        let folderID: UUID
        let tracker: WatchFolderScanner.SettleTracker
    }

    /// Result of the detached hashing step: successful content hashes plus the
    /// files that definitively exceeded a product resource limit.
    private struct HashOutcome: Sendable {
        let hashes: [URL: String]
        let oversized: [(url: URL, detail: String)]
    }

    /// Outcome counts for one scan pass, used to announce **once** per pass.
    struct PassTally: Equatable {
        var imported = 0
        var failed = 0
        var awaitingReview = 0

        var isEmpty: Bool {
            imported == 0 && failed == 0 && awaitingReview == 0
        }
    }

    private var activeFolders: [UUID: ActiveFolder] = [:]
    private var folderStates: [UUID: WatchFolderState] = [:]
    private var settleTrackers: [UUID: WatchFolderScanner.SettleTracker] = [:]
    /// Fingerprints ("size|mtime|path") already classified as ledgered
    /// duplicates, so steady-state polls skip re-hashing unchanged files.
    private var knownDuplicateFingerprints: [UUID: Set<String>] = [:]
    private var pollTask: Task<Void, Never>?
    private var earlyScanPending = false

    // MARK: - Init

    init(
        store: FileWatchFolderStore,
        bookmarkStore: SecurityScopedBookmarkStore = SecurityScopedBookmarkStore(),
        watcherFactory: @escaping () -> any DirectoryWatching = { DispatchSourceDirectoryWatcher() },
        digest: any ContentDigesting,
        policy: WatchFolderScanPolicy = .default
    ) {
        self.store = store
        self.bookmarkStore = bookmarkStore
        self.watcherFactory = watcherFactory
        self.policy = policy
        self.scanner = WatchFolderScanner(digest: digest, policy: policy)
    }

    deinit {
        pollTask?.cancel()
        for (_, folder) in activeFolders {
            folder.watchHandle?.cancel()
            folder.scopedAccess?.stop()
        }
    }

    // MARK: - Lifecycle

    /// Load persisted configuration and begin watching.
    func start() {
        loadFromStore()
        // A review queued before quit is still queued: the pending-review state
        // persists, so restore its banner rather than leaving the file silently
        // invisible until the next new FIT file arrives.
        if pendingReviewBanner == nil {
            surfaceNextPendingReview()
        }
        guard !folders.isEmpty else { return }
        for folder in folders where !folder.isPaused {
            activate(folder)
        }
        beginPolling()
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        for (_, folder) in activeFolders {
            folder.watchHandle?.cancel()
            folder.scopedAccess?.stop()
        }
        activeFolders.removeAll()
    }

    private func loadFromStore() {
        let snapshot = store.loadOrEmpty()
        folders = snapshot.folders
        for state in snapshot.states {
            folderStates[state.folderID] = state
        }
        isPaused = !folders.isEmpty && folders.allSatisfy(\.isPaused)
    }

    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanPass()
                let interval = self.policy.pollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func activate(_ configuration: WatchFolderConfiguration) {
        do {
            let resolved = try bookmarkStore.resolve(configuration.bookmarkData)
            let access = bookmarkStore.beginAccess(to: resolved.url)
            let watch = watcherFactory().start(directoryURL: resolved.url) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.requestEarlyScan()
                }
            }
            activeFolders[configuration.id] = ActiveFolder(
                configuration: configuration,
                resolvedURL: resolved.url,
                scopedAccess: access,
                watchHandle: watch
            )
            if resolved.wasStale {
                persistStaleBookmarkRefresh(for: configuration, resolved: resolved)
            }
            // Recovery is a folder-state change, not a file result, so it is
            // reported by the settings pane clearing its Unavailable badge
            // rather than by a Recent Imports row (which would falsely imply a
            // workout was imported).
            unavailableFolderIDs.remove(configuration.id)
        } catch {
            // Never active, so the poll loop cannot report this folder. Mark it
            // unavailable here (once) and let `retryInactiveFolders` recover it
            // automatically when the bookmark resolves again.
            if unavailableFolderIDs.insert(configuration.id).inserted {
                appendRecent(WatchFolderImportRecord(
                    folderID: configuration.id,
                    folderName: configuration.displayName,
                    fileURL: URL(fileURLWithPath: "/"),
                    fileName: configuration.displayName,
                    status: .failed,
                    processedAt: Date(),
                    failureDetail: "This watched folder could not be opened. It may have been moved, renamed, or unmounted. RunPlay Studio will retry automatically; if it stays unavailable, remove it in Watch Folder settings and add it again."
                ))
            }
        }
    }

    /// Retry folders that are configured and unpaused but not active.
    ///
    /// Covers the launch case where a bookmark could not be resolved because
    /// the volume was not mounted yet: without this a folder added while its
    /// volume is offline would stay dead until the app restarts.
    private func retryInactiveFolders() {
        for configuration in folders
        where !configuration.isPaused && activeFolders[configuration.id] == nil {
            activate(configuration)
        }
    }

    private func persistStaleBookmarkRefresh(
        for configuration: WatchFolderConfiguration,
        resolved: SecurityScopedBookmarkStore.ResolvedFolder
    ) {
        guard let freshData = try? bookmarkStore.createBookmark(for: resolved.url) else {
            return
        }
        updateFolder(id: configuration.id) { $0.bookmarkData = freshData }
        persist()
    }

    // MARK: - Folder management (settings pane)

    /// Add a user-chosen folder. Returns false when the bookmark could not
    /// be created.
    @discardableResult
    func addFolder(url: URL, defaultTagName: String = "") -> Bool {
        guard let bookmarkData = try? bookmarkStore.createBookmark(for: url) else {
            return false
        }
        let configuration = WatchFolderConfiguration(
            displayName: url.lastPathComponent,
            bookmarkData: bookmarkData,
            defaultTagName: defaultTagName
        )
        folders.append(configuration)
        folderStates[configuration.id] = WatchFolderState(folderID: configuration.id)
        persist()
        activate(configuration)
        if pollTask == nil {
            beginPolling()
        }
        // Pick up files already sitting in the newly watched folder.
        requestEarlyScan(bypassSettle: true)
        return true
    }

    func removeFolder(id: UUID) {
        if let active = activeFolders.removeValue(forKey: id) {
            active.watchHandle?.cancel()
            active.scopedAccess?.stop()
        }
        folderStates.removeValue(forKey: id)
        settleTrackers.removeValue(forKey: id)
        knownDuplicateFingerprints.removeValue(forKey: id)
        unavailableFolderIDs.remove(id)
        folders.removeAll { $0.id == id }
        // Drop this folder's banner. Any other folder still holding a queued
        // review re-raises its own on the next pass, so removing a folder can
        // never strand another folder's banner or leave one pointing at a
        // folder that no longer exists.
        if pendingReviewBanner?.folderID == id {
            pendingReviewBanner = nil
            surfaceNextPendingReview()
        }
        persist()
    }

    /// Re-raise the banner for any remaining queued review, newest queue first.
    ///
    /// Called after a review resolves or its folder is removed so a queued
    /// file is never silently forgotten: `pendingReview` persists per folder,
    /// so state survives relaunch even when no banner is on screen.
    private func surfaceNextPendingReview() {
        // Newest queue first, deterministic by queue time. Entries whose file
        // vanished are pruned rather than surfaced, so the banner always offers
        // a review the user can actually open.
        var candidates: [(folderID: UUID, folderName: String, entry: WatchFolderPendingReviewEntry)] = []
        var vanished: [(folderID: UUID, key: String)] = []
        for (folderID, state) in folderStates {
            guard let folder = folders.first(where: { $0.id == folderID }),
                  !folder.isPaused else { continue }
            for (key, entry) in state.pendingReview {
                if FileManager.default.fileExists(atPath: entry.filePath) {
                    candidates.append((folderID, folder.displayName, entry))
                } else {
                    vanished.append((folderID, key))
                }
            }
        }
        if !vanished.isEmpty {
            for item in vanished {
                folderStates[item.folderID]?.pendingReview.removeValue(forKey: item.key)
            }
            persist()
        }
        guard let found = candidates.max(by: { $0.entry.queuedAt < $1.entry.queuedAt }) else {
            return
        }
        pendingReviewBanner = PendingReviewBanner(
            folderID: found.folderID,
            folderName: found.folderName,
            fileName: found.entry.fileName,
            fileURL: URL(fileURLWithPath: found.entry.filePath)
        )
    }

    func setPaused(_ paused: Bool, folderID: UUID) {
        updateFolder(id: folderID) { $0.isPaused = paused }
        if paused {
            if let active = activeFolders.removeValue(forKey: folderID) {
                active.watchHandle?.cancel()
                active.scopedAccess?.stop()
            }
            // Pausing deliberately stops access, so an unreadable folder is
            // expected, not a fault: never show Unavailable for a paused folder.
            unavailableFolderIDs.remove(folderID)
        } else if let folder = folders.first(where: { $0.id == folderID }) {
            activate(folder)
            requestEarlyScan(bypassSettle: true)
        }
        isPaused = !folders.isEmpty && folders.allSatisfy(\.isPaused)
        persist()
    }

    /// Master pause toggle from settings.
    func setAllPaused(_ paused: Bool) {
        for folder in folders {
            setPaused(paused, folderID: folder.id)
        }
        isPaused = paused
    }

    func setDefaultTag(_ tagName: String, folderID: UUID) {
        updateFolder(id: folderID) { $0.defaultTagName = tagName }
        persist()
    }

    /// "Import existing files now": scan immediately, bypassing the settle
    /// tracker's two-probe requirement — pre-existing files are
    /// definitionally not mid-write.
    func importExistingNow() {
        requestEarlyScan(bypassSettle: true)
    }

    /// User-initiated review of the banner's queued FIT file.
    func presentPendingReview() {
        guard let banner = pendingReviewBanner else { return }
        reviewPresenter?(banner.fileURL)
    }

    /// Dismiss the banner without reviewing; the file stays queued and the
    /// banner returns on the next queued file.
    func dismissPendingReviewBanner() {
        pendingReviewBanner = nil
    }

    // MARK: - Scan scheduling

    /// Event-driven wake: run one scan pass soon, coalesced so a burst of
    /// filesystem events collapses into one pass.
    private func requestEarlyScan(bypassSettle: Bool = false) {
        guard !earlyScanPending else {
            if bypassSettle {
                // A user-initiated scan must not be swallowed by a pending
                // coalesced wake; flag it for that pass.
                pendingBypassSettle = true
            }
            return
        }
        earlyScanPending = true
        if bypassSettle {
            pendingBypassSettle = true
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.earlyScanPending = false
            let bypass = self.pendingBypassSettle
            self.pendingBypassSettle = false
            await self.scanPass(bypassSettle: bypass)
        }
    }

    private var pendingBypassSettle = false

    // MARK: - Scan pass

    /// One authoritative scan across all active folders.
    private func scanPass(bypassSettle: Bool = false) async {
        guard !isPaused else { return }
        // A folder whose volume was offline at launch never activated; retrying
        // each pass lets it come back without restarting the app.
        retryInactiveFolders()
        guard !activeFolders.isEmpty else { return }

        let inputs = activeFolders.values.map { folder in
            FolderScanInput(
                folderID: folder.configuration.id,
                displayName: folder.configuration.displayName,
                resolvedURL: folder.resolvedURL
            )
        }
        let scanner = self.scanner
        let settleInterval = policy.settleInterval

        // Detached: directory listing, settle probing, and bounded reads.
        // The tracker snapshot crosses the boundary by value and returns
        // for the next pass; probing is pure and deterministic.
        let trackerSnapshots = settleTrackers.map { TrackerSnapshot(folderID: $0.key, tracker: $0.value) }
        let scanned: ScanPassResult = await Task.detached(priority: .utility) {
            var trackers: [UUID: WatchFolderScanner.SettleTracker] = [:]
            for snapshot in trackerSnapshots {
                trackers[snapshot.folderID] = snapshot.tracker
            }
            var results: [FolderScanOutput] = []
            for input in inputs {
                // Listability is checked first: an unreadable directory returns
                // zero files, which must not read as "watched and empty".
                let isListable = scanner.isDirectoryListable(input.resolvedURL)
                var files: [WatchFolderScanner.DiscoveredFile] = []
                if isListable {
                    files = scanner.eligibleFiles(in: input.resolvedURL).files
                }
                var tracker = trackers[input.folderID]
                    ?? WatchFolderScanner.SettleTracker(settleInterval: settleInterval)
                var settled: [WatchFolderScanner.DiscoveredFile] = []
                let now = Date()
                for file in files {
                    let key = file.url.absoluteString
                    let isSettled = bypassSettle
                        || tracker.update(
                            key: key,
                            byteSize: file.byteSize,
                            contentModificationDate: file.contentModificationDate,
                            now: now
                        )
                    if isSettled {
                        settled.append(file)
                    }
                }
                tracker.prune(keeping: Set(files.map { $0.url.absoluteString }))
                trackers[input.folderID] = tracker
                results.append(FolderScanOutput(
                    input: input,
                    settledFiles: settled,
                    isListable: isListable
                ))
            }
            return ScanPassResult(
                outputs: results,
                trackers: trackers.map { TrackerSnapshot(folderID: $0.key, tracker: $0.value) }
            )
        }.value
        // Persist returned trackers only for folders still active; a folder
        // removed mid-pass must not resurrect its tracker.
        let activeIDs = Set(activeFolders.keys)
        for snapshot in scanned.trackers where activeIDs.contains(snapshot.folderID) {
            settleTrackers[snapshot.folderID] = snapshot.tracker
        }

        // One aggregate announcement per pass across every folder: a background
        // watcher must never speak per file or per idle poll.
        var passTally = PassTally()
        var newlyUnavailable: [String] = []

        for output in scanned.outputs {
            guard let active = activeFolders[output.input.folderID] else { continue }
            if handleAvailabilityChange(output, folder: active) {
                newlyUnavailable.append(active.configuration.displayName)
            }
            guard output.isListable else { continue }
            let tally = await processSettledFiles(output.settledFiles, in: active)
            passTally.imported += tally.imported
            passTally.failed += tally.failed
            passTally.awaitingReview += tally.awaitingReview
        }

        announcePassResults(
            tally: passTally,
            newlyUnavailable: newlyUnavailable,
            reviewName: pendingReviewBanner?.fileName
        )
    }

    /// Speak at most a few concise messages per pass.
    ///
    /// A failure outranks a success so an error is never masked by a sibling
    /// import; unavailability and a queued review are spoken because both
    /// otherwise have no non-visual signal at all.
    private func announcePassResults(
        tally: PassTally,
        newlyUnavailable: [String],
        reviewName: String?
    ) {
        guard let announce else { return }
        if tally.failed > 0 {
            announce(.watchFolderImportFailed(count: tally.failed))
        } else if tally.imported > 0 {
            announce(.watchFolderImportCompleted(count: tally.imported))
        }
        for name in newlyUnavailable {
            announce(.watchFolderUnavailable(name: name))
        }
        if tally.awaitingReview > 0, let reviewName {
            announce(.watchFolderReviewReady(name: reviewName))
        }
    }

    /// Report the available ⇄ unavailable transition exactly once per edge.
    ///
    /// An ejected volume or deleted folder must not be silent: without this the
    /// scan returns zero files and the folder looks merely empty, so the user
    /// gets no reason their imports stopped. Equally it must not repeat on
    /// every ~5 s poll, so the row is appended only when the edge is crossed.
    ///
    /// Returns true when this call crossed into unavailable, so the caller can
    /// announce the edge once.
    @discardableResult
    private func handleAvailabilityChange(
        _ output: FolderScanOutput,
        folder: ActiveFolder
    ) -> Bool {
        let id = output.input.folderID
        if !output.isListable {
            guard !unavailableFolderIDs.contains(id) else { return false }
            unavailableFolderIDs.insert(id)
            appendRecent(WatchFolderImportRecord(
                folderID: id,
                folderName: folder.configuration.displayName,
                fileURL: folder.resolvedURL,
                fileName: folder.configuration.displayName,
                status: .failed,
                processedAt: Date(),
                failureDetail: "This watched folder is not available. It may have been ejected, moved, renamed, or deleted. RunPlay Studio will resume watching automatically if it returns."
            ))
            return true
        } else if unavailableFolderIDs.contains(id) {
            unavailableFolderIDs.remove(id)
        }
        return false
    }

    /// Hash, classify, and import one folder's settled files.
    ///
    /// Returns the outcome counts for this folder's pass so the caller can
    /// announce once per pass rather than once per file.
    @discardableResult
    private func processSettledFiles(
        _ files: [WatchFolderScanner.DiscoveredFile],
        in folder: ActiveFolder
    ) async -> PassTally {
        var tally = PassTally()
        let folderID = folder.configuration.id
        var duplicateFingerprints = knownDuplicateFingerprints[folderID] ?? []

        // Hash only files whose fingerprint is not already known-duplicate.
        var hashes: [URL: String] = [:]
        var hashable: [WatchFolderScanner.DiscoveredFile] = []
        for file in files {
            let fingerprint = Self.fingerprint(file)
            if duplicateFingerprints.contains(fingerprint) {
                continue
            }
            hashable.append(file)
        }

        var oversized: [(url: URL, detail: String)] = []
        if !hashable.isEmpty {
            let scanner = self.scanner
            let hashed: HashOutcome = await Task.detached(priority: .utility) {
                var ok: [URL: String] = [:]
                var tooLarge: [(url: URL, detail: String)] = []
                for file in hashable {
                    do {
                        // A nil hash means unreadable right now (vanished,
                        // locked); leave it for the next pass rather than
                        // failing it.
                        if let hash = try scanner.contentHash(for: file.url) {
                            ok[file.url] = hash
                        }
                    } catch let error as WorkoutResourceLimitError {
                        // Definitive: this file can never import. Report it
                        // once and stop re-reading it on every pass. Reuses
                        // the shared product wording rather than a second
                        // copy of the limit.
                        tooLarge.append((
                            file.url,
                            error.errorDescription ?? "This file exceeds a RunPlay Studio import limit."
                        ))
                    } catch {
                        continue
                    }
                }
                return HashOutcome(hashes: ok, oversized: tooLarge)
            }.value
            hashes = hashed.hashes
            oversized = hashed.oversized
        }

        // Record oversized files as failures exactly once, keyed by fingerprint
        // so a later pass never re-reads or re-reports them.
        if !oversized.isEmpty {
            for entry in oversized {
                guard let file = files.first(where: { $0.url == entry.url }) else { continue }
                let fingerprint = Self.fingerprint(file)
                guard !duplicateFingerprints.contains(fingerprint) else { continue }
                duplicateFingerprints.insert(fingerprint)
                appendRecent(WatchFolderImportRecord(
                    folderID: folderID,
                    folderName: folder.configuration.displayName,
                    fileURL: entry.url,
                    fileName: entry.url.lastPathComponent,
                    status: .failed,
                    processedAt: Date(),
                    failureDetail: entry.detail
                ))
                tally.failed += 1
            }
            knownDuplicateFingerprints[folderID] = duplicateFingerprints
        }

        let state = folderStates[folderID] ?? WatchFolderState(folderID: folderID)
        let hashedFiles = files.filter { hashes[$0.url] != nil }
        let result = scanner.classify(
            files: hashedFiles,
            state: state,
            contentHashes: hashes
        )

        // Ledgered content whose file is unchanged needs no new record and
        // no re-hash next pass: remember the fingerprint. A skip row is
        // recorded only for a *newly seen* duplicate under a different name
        // (a rename or copy) — the unchanged original stays silent so every
        // successful import does not produce a second row.
        let ledgerByHash = Dictionary(state.ledger.map { ($0.contentSHA256, $0) }, uniquingKeysWith: { first, _ in first })
        for duplicate in result.duplicates {
            let fingerprint = Self.fingerprint(duplicate)
            defer { duplicateFingerprints.insert(fingerprint) }
            guard !duplicateFingerprints.contains(fingerprint) else { continue }
            guard let hash = hashes[duplicate.url],
                  let entry = ledgerByHash[hash],
                  entry.fileName != duplicate.url.lastPathComponent else {
                continue
            }
            appendRecent(WatchFolderImportRecord(
                folderID: folderID,
                folderName: folder.configuration.displayName,
                fileURL: duplicate.url,
                fileName: duplicate.url.lastPathComponent,
                status: .skippedDuplicate,
                processedAt: Date()
            ))
        }
        knownDuplicateFingerprints[folderID] = duplicateFingerprints

        for candidate in result.candidates {
            guard !isPaused else { break }
            guard canImportNow() else {
                // Busy with a user-initiated operation: leave as candidate,
                // retried next pass without ledgering.
                continue
            }
            let outcome = await processCandidate(
                candidate,
                folder: folder,
                hash: hashes[candidate.url] ?? ""
            )
            switch outcome {
            case .imported: tally.imported += 1
            case .failed: tally.failed += 1
            case .awaitingReview: tally.awaitingReview += 1
            case .skippedDuplicate, .none: break
            }
        }
        return tally
    }

    private func processCandidate(
        _ file: WatchFolderScanner.DiscoveredFile,
        folder: ActiveFolder,
        hash: String
    ) async -> WatchFolderImportOutcome? {
        let configuration = folder.configuration
        let folderID = configuration.id

        guard let importExecutor else { return nil }
        let execution = await importExecutor(file.url, configuration)

        switch execution.outcome {
        case .awaitingReview:
            guard !hash.isEmpty else { return nil }
            var state = folderStates[folderID] ?? WatchFolderState(folderID: folderID)
            guard state.pendingReview[hash] == nil else { return nil }
            state.pendingReview[hash] = WatchFolderPendingReviewEntry(
                filePath: file.url.path,
                fileName: file.url.lastPathComponent,
                queuedAt: Date()
            )
            folderStates[folderID] = state
            pendingReviewBanner = PendingReviewBanner(
                folderID: folderID,
                folderName: configuration.displayName,
                fileName: file.url.lastPathComponent,
                fileURL: file.url
            )
            appendRecent(WatchFolderImportRecord(
                folderID: folderID,
                folderName: configuration.displayName,
                fileURL: file.url,
                fileName: file.url.lastPathComponent,
                status: .awaitingReview,
                processedAt: Date()
            ))
            persist()
            return .awaitingReview

        case .imported, .skippedDuplicate, .failed:
            appendRecent(WatchFolderImportRecord(
                folderID: folderID,
                folderName: configuration.displayName,
                fileURL: file.url,
                fileName: file.url.lastPathComponent,
                status: Self.status(for: execution.outcome),
                processedAt: Date(),
                failureDetail: execution.failureDetail
            ))
            ledger(hash: hash, outcome: execution.outcome, file: file, folderID: folderID)
            persist()
            return execution.outcome
        }
    }

    /// Called after the FIT review sheet resolves a queued file: the pending
    /// entry is removed and the content is ledgered so it never requeues.
    func resolvePendingReview(fileURL: URL, outcome: WatchFolderImportOutcome) {
        let normalizedTarget = fileURL.resolvingSymlinksInPath()
        guard let hash = try? scanner.contentHash(for: fileURL), !hash.isEmpty else {
            // Unreadable now (moved/deleted): drop every pending entry that
            // references this path so it cannot requeue either.
            for (folderID, var state) in folderStates {
                let before = state.pendingReview.count
                state.pendingReview = state.pendingReview.filter {
                    URL(fileURLWithPath: $0.value.filePath).resolvingSymlinksInPath() != normalizedTarget
                }
                if state.pendingReview.count != before {
                    folderStates[folderID] = state
                }
            }
            if pendingReviewBanner?.fileURL.resolvingSymlinksInPath() == normalizedTarget {
                pendingReviewBanner = nil
                surfaceNextPendingReview()
            }
            persist()
            return
        }
        for (folderID, var state) in folderStates {
            guard state.pendingReview.removeValue(forKey: hash) != nil else { continue }
            state.ledger.removeAll { $0.contentSHA256 == hash }
            state.ledger.append(WatchFolderLedgerEntry(
                contentSHA256: hash,
                fileName: fileURL.lastPathComponent,
                outcome: outcome,
                processedAt: Date()
            ))
            trimLedger(&state)
            folderStates[folderID] = state
        }
        if pendingReviewBanner?.fileURL.resolvingSymlinksInPath() == normalizedTarget {
            pendingReviewBanner = nil
            surfaceNextPendingReview()
        }
        persist()
    }

    // MARK: - Helpers

    private static func status(
        for outcome: WatchFolderImportOutcome
    ) -> WatchFolderImportRecord.Status {
        switch outcome {
        case .imported: return .imported
        case .skippedDuplicate: return .skippedDuplicate
        case .failed: return .failed
        case .awaitingReview: return .awaitingReview
        }
    }

    private static func fingerprint(_ file: WatchFolderScanner.DiscoveredFile) -> String {
        "\(file.byteSize)|\(Int(file.contentModificationDate.timeIntervalSince1970 * 1000))|\(file.url.absoluteString)"
    }

    private func ledger(
        hash: String,
        outcome: WatchFolderImportOutcome,
        file: WatchFolderScanner.DiscoveredFile,
        folderID: UUID
    ) {
        guard !hash.isEmpty else { return }
        var state = folderStates[folderID] ?? WatchFolderState(folderID: folderID)
        state.ledger.removeAll { $0.contentSHA256 == hash }
        state.ledger.append(WatchFolderLedgerEntry(
            contentSHA256: hash,
            fileName: file.url.lastPathComponent,
            outcome: outcome,
            processedAt: Date()
        ))
        trimLedger(&state)
        folderStates[folderID] = state
    }

    private func trimLedger(_ state: inout WatchFolderState) {
        guard state.ledger.count > policy.maxLedgerEntriesPerFolder else { return }
        let sorted = state.ledger.sorted { $0.processedAt > $1.processedAt }
        state.ledger = Array(sorted.prefix(policy.maxLedgerEntriesPerFolder))
    }

    private func appendRecent(_ record: WatchFolderImportRecord) {
        recentImports.insert(record, at: 0)
        if recentImports.count > policy.maxRecentRecords {
            recentImports = Array(recentImports.prefix(policy.maxRecentRecords))
        }
    }

    private func updateFolder(id: UUID, _ mutate: (inout WatchFolderConfiguration) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        mutate(&folder)
        folders[index] = folder
    }

    private func persist() {
        let snapshot = FileWatchFolderStore.WatchFolderStoreSnapshot(
            folders: folders,
            states: Array(folderStates.values)
        )
        try? store.save(snapshot)
    }
}
