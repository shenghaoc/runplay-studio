import Foundation
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Phases of the Apple Health review sheet.
enum AppleHealthImportUIPhase: Equatable {
    case reviewing
    case importing
    case report
}

/// Main-actor UI state for one Apple Health review.
///
/// Holds the scan result and the selection only. Reading the archive and writing
/// the library belong to `RunPlayPlatform`, and this type never opens the ZIP:
/// the sheet is a view of values another layer produced, so a bug in it can
/// mislabel a row but cannot misread an archive or half-write a library.
@MainActor
final class AppleHealthImportSession: ObservableObject {

    @Published var phase: AppleHealthImportUIPhase = .reviewing
    @Published var selectedIDs: Set<String>
    @Published var searchText: String = ""
    /// Show only the candidates carrying a flag. Off by default, because the
    /// review exists to show what the export holds, not only what is wrong.
    @Published var flaggedOnly: Bool = false
    @Published var progress: AppleHealthImportProgress
    @Published var report: AppleHealthImportReport?
    @Published var errorMessage: String?

    let archiveURL: URL
    let archiveName: String
    let scanResult: AppleHealthArchiveScanResult

    /// Keeps security-scoped access alive for the session lifetime.
    private let securityScopedURL: URL
    private let isAccessing: Bool

    init(archiveURL: URL, scanResult: AppleHealthArchiveScanResult, securityScoped: Bool) {
        self.archiveURL = archiveURL
        self.archiveName = archiveURL.lastPathComponent
        self.securityScopedURL = archiveURL
        self.isAccessing = securityScoped
        self.scanResult = scanResult
        self.progress = AppleHealthImportProgress(phase: .importing, totalCount: 0)
        // Duplicates start unchecked: a run the user already has, or one that
        // overlaps something, is not imported behind their back.
        self.selectedIDs = AppleHealthReviewPresentation.defaultSelection(scanResult.candidates)
    }

    deinit {
        if isAccessing {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    var candidates: [AppleHealthWorkoutCandidate] { scanResult.candidates }

    var filteredCandidates: [AppleHealthWorkoutCandidate] {
        AppleHealthReviewPresentation.filtered(
            candidates,
            query: searchText,
            flaggedOnly: flaggedOnly
        )
    }

    var selectedCount: Int { selectedIDs.count }

    var readyCount: Int { AppleHealthReviewPresentation.readyCount(candidates) }

    var flaggedCount: Int { AppleHealthReviewPresentation.flaggedCount(candidates) }

    func selectAllReady() {
        selectedIDs = AppleHealthReviewPresentation.defaultSelection(candidates)
    }

    func selectNone() {
        selectedIDs.removeAll()
    }
}
