import Foundation
import RunPlayCore
import SwiftUI

/// Phases of the Strava archive import sheet.
enum ArchiveImportUIPhase: Equatable {
    case reviewing
    case importing
    case report
}

/// Main-actor UI state for a single Strava archive import session.
@MainActor
final class ArchiveImportSession: ObservableObject {
    @Published var phase: ArchiveImportUIPhase = .reviewing
    @Published var scanResult: WorkoutArchiveScanResult
    @Published var selectedIDs: Set<String>
    @Published var searchText: String = ""
    @Published var showRunningOnly: Bool = true
    @Published var progress: WorkoutBatchImportProgress = WorkoutBatchImportProgress()
    @Published var report: WorkoutBatchImportReport?
    @Published var errorMessage: String?

    let archiveURL: URL
    let archiveName: String
    /// Keeps security-scoped access alive for the session lifetime.
    let securityScopedURL: URL
    private let isAccessing: Bool

    init(archiveURL: URL, scanResult: WorkoutArchiveScanResult, securityScoped: Bool) {
        self.archiveURL = archiveURL
        self.archiveName = archiveURL.lastPathComponent
        self.securityScopedURL = archiveURL
        self.isAccessing = securityScoped
        self.scanResult = scanResult
        self.selectedIDs = Set(scanResult.candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    deinit {
        if isAccessing {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    var filteredCandidates: [WorkoutArchiveCandidate] {
        var list = scanResult.candidates
        if showRunningOnly {
            list = list.filter { candidate in
                if selectedIDs.contains(candidate.id) { return true }
                switch StravaActivityTypePolicy.classify(candidate.activityType) {
                case .running, .walkOrHike:
                    return true
                case .unsupported, .unknown:
                    // Still surface missing files / errors for transparency.
                    return candidate.status != .unsupportedActivityType
                }
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q)
                    || ($0.activityType?.lowercased().contains(q) ?? false)
                    || $0.archiveRelativePath.lowercased().contains(q)
                    || $0.status.userFacingSummary.lowercased().contains(q)
            }
        }
        return list.sorted { $0.archiveOrder < $1.archiveOrder }
    }

    var selectedCount: Int { selectedIDs.count }

    func selectAllImportable() {
        for c in scanResult.candidates where c.status.isImportableByDefault {
            selectedIDs.insert(c.id)
        }
    }

    func selectNone() {
        selectedIDs.removeAll()
    }
}

