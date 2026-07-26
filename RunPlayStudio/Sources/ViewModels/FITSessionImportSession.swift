import Foundation
import RunPlayCore
import SwiftUI

/// Phases of the multi-session FIT import sheet.
enum FITSessionImportUIPhase: Equatable {
    case reviewing
    case importing
    case report
}

/// Main-actor UI state for one multi-session FIT import.
///
/// Holds descriptors only. Decoded FIT messages stay inside
/// `FITSessionImportService` and are released between the scan and the import,
/// so an open review sheet never pins a parsed container in memory.
@MainActor
final class FITSessionImportSession: ObservableObject {
    @Published var phase: FITSessionImportUIPhase = .reviewing
    @Published var scanResult: FITSessionScanResult
    @Published var selectedIDs: Set<String>
    @Published var progress: WorkoutBatchImportProgress = WorkoutBatchImportProgress()
    @Published var report: FITSessionBatchImportReport?
    @Published var errorMessage: String?

    let fileURL: URL
    let fileName: String
    /// Keeps security-scoped access alive for the whole scan → review → import
    /// lifetime, and no longer.
    private let securityScopedURL: URL
    private let isAccessing: Bool

    init(fileURL: URL, scanResult: FITSessionScanResult, securityScoped: Bool) {
        self.fileURL = fileURL
        self.fileName = scanResult.fileName.isEmpty
            ? fileURL.lastPathComponent
            : scanResult.fileName
        self.securityScopedURL = fileURL
        self.isAccessing = securityScoped
        self.scanResult = scanResult
        self.selectedIDs = Set(
            scanResult.candidates.filter(\.isSelectedByDefault).map(\.providerActivityID)
        )
    }

    deinit {
        if isAccessing {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    /// Candidates in FIT source order, which is also the staging and reporting
    /// order. A container holds a short, fully visible session list, so there
    /// is no search field to trap the Escape key or steal initial focus.
    var displayedCandidates: [FITSessionDescriptor] {
        scanResult.candidates.sorted { $0.sourceIndex < $1.sourceIndex }
    }

    var selectedCount: Int { selectedIDs.count }

    var canImport: Bool {
        phase == .reviewing && selectedCount > 0
    }

    func isSelectable(_ candidate: FITSessionDescriptor) -> Bool {
        candidate.status.isImportableByDefault
    }

    func isSelected(_ candidate: FITSessionDescriptor) -> Bool {
        selectedIDs.contains(candidate.providerActivityID)
    }

    func setSelected(_ isSelected: Bool, for candidate: FITSessionDescriptor) {
        guard isSelectable(candidate) else { return }
        if isSelected {
            selectedIDs.insert(candidate.providerActivityID)
        } else {
            selectedIDs.remove(candidate.providerActivityID)
        }
    }

    func selectAllImportable() {
        for candidate in scanResult.candidates where candidate.status.isImportableByDefault {
            selectedIDs.insert(candidate.providerActivityID)
        }
    }

    func selectNone() {
        selectedIDs.removeAll()
    }

    func makeSelection() -> FITSessionImportSelection {
        FITSessionImportSelection(
            selectedCandidateIDs: Array(selectedIDs),
            candidates: scanResult.candidates
        )
    }

    // MARK: - Accessibility

    /// One spoken summary per row: name, sport, timing, data volume, status.
    /// Status is text, never colour alone.
    func accessibilityLabel(for candidate: FITSessionDescriptor) -> String {
        var parts: [String] = [
            "Session \(candidate.displayOrdinal) of \(scanResult.candidates.count)",
            candidate.displayName,
            candidate.sportDescription
        ]
        if let subSport = candidate.subSportDescription {
            parts.append(subSport)
        }
        if let start = candidate.startDate {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append("No start time")
        }
        if let elapsed = candidate.elapsedSeconds {
            parts.append("Elapsed \(DisplayFormatter.formatDuration(elapsed))")
        }
        if let distance = candidate.reportedDistanceMeters {
            parts.append("Distance \(DisplayFormatter.formatDistance(distance))")
        }
        parts.append("\(candidate.gpsRecordCount) GPS points")
        parts.append("\(candidate.recordedLapCount) laps")
        parts.append(candidate.status.userFacingSummary)
        if let detail = candidate.statusDetail {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    var selectionAccessibilityValue: String {
        "\(selectedCount) of \(scanResult.readyCount) importable sessions selected"
    }
}
