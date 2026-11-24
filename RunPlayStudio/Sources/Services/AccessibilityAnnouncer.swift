import AppKit
import Foundation

/// Narrow announcement sink for deliberate accessibility status updates.
///
/// Replay ticks, map camera motion, and high-frequency progress must never
/// call this type. Prefer SwiftUI accessibility values on focused controls
/// for continuous state.
@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String)
}

/// AppKit-backed announcer that posts to the system accessibility subsystem.
@MainActor
final class AccessibilityAnnouncer: AccessibilityAnnouncing {
    static let shared = AccessibilityAnnouncer()

    /// Last spoken message, exposed for tests and duplicate suppression.
    private(set) var lastAnnouncement: String?
    private var lastAnnouncementDate: Date?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.4) {
        self.minimumInterval = minimumInterval
    }

    func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed == lastAnnouncement,
           let lastAnnouncementDate,
           Date().timeIntervalSince(lastAnnouncementDate) < minimumInterval {
            return
        }
        lastAnnouncement = trimmed
        lastAnnouncementDate = Date()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    /// Test helper: clear suppression state.
    func reset() {
        lastAnnouncement = nil
        lastAnnouncementDate = nil
    }
}

/// Records announcements without talking to AppKit (unit tests).
@MainActor
final class RecordingAccessibilityAnnouncer: AccessibilityAnnouncing {
    private(set) var messages: [String] = []

    func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(trimmed)
    }

    func reset() {
        messages.removeAll()
    }
}

/// Domain events that may produce at most one concise announcement.
enum AccessibilityAnnouncementEvent: Equatable, Sendable {
    case libraryLoaded(count: Int)
    case importCompleted(name: String)
    /// A single-file import whose elevation was DEM-corrected on the way in.
    case importCompletedWithDetail(name: String, detail: String)
    case importCancelled
    case importFailed(message: String)
    case exportPreviewReady
    case exportCompleted(name: String)
    case exportFailed(message: String)
    case videoPreviewReady
    case videoPreviewFailed(message: String)
    case videoExportCompleted(name: String)
    case videoExportFailed(message: String)
    case videoExportCancelled
    case comparisonVideoPreviewReady
    case comparisonVideoExportCompleted(name: String)
    case comparisonVideoExportFailed(message: String)
    case comparisonVideoExportCancelled
    case comparisonVideoRouteAwareUnavailable
    case heatmapReady(runCount: Int)
    case trendsReady(runCount: Int)
    case recordsReady(runCount: Int)
    case queryResultPublished(count: Int)
    case comparisonEntered
    case comparisonExited
    case usingDistanceAlignment
    case usingRouteAwareAlignment
    case routeAlignmentReady
    case routeAlignmentUnavailable
    case replayPlayed
    case replayPaused
    case replayRestarted
    case replayReachedEnd
    case speedChanged(label: String)
    case tagUpdateCompleted
    case smartCollectionUpdated
    case watchFolderImportCompleted(count: Int)
    case watchFolderImportFailed(count: Int)
    case watchFolderUnavailable(name: String)
    case watchFolderReviewReady(name: String)
    case elevationCorrectionFinished(summary: String)
    /// One run's elevation source changed; the message says how.
    case elevationSourceChanged(message: String)

    var message: String {
        switch self {
        case .libraryLoaded(let count):
            return studioLocalized("Library loaded. \(count) runs.")
        case .importCompleted(let name):
            return studioLocalized("Imported \(name).")
        case .importCompletedWithDetail(let name, let detail):
            return studioLocalized("Imported \(name). \(detail)")
        case .importCancelled:
            return studioLocalized("Import cancelled.")
        case .importFailed(let message):
            return studioLocalized("Import failed. \(message)")
        case .exportPreviewReady:
            return studioLocalized("Export preview ready.")
        case .exportCompleted(let name):
            return studioLocalized("Exported \(name).")
        case .exportFailed(let message):
            return studioLocalized("Export failed. \(message)")
        case .videoPreviewReady:
            return studioLocalized("Video preview ready.")
        case .videoPreviewFailed(let message):
            return studioLocalized("Video preview failed. \(message)")
        case .videoExportCompleted(let name):
            return studioLocalized("Video exported \(name).")
        case .videoExportFailed(let message):
            return studioLocalized("Video export failed. \(message)")
        case .videoExportCancelled:
            return studioLocalized("Video export cancelled.")
        case .comparisonVideoPreviewReady:
            return studioLocalized("Comparison video preview ready.")
        case .comparisonVideoExportCompleted(let name):
            return studioLocalized("Comparison video exported \(name).")
        case .comparisonVideoExportFailed(let message):
            return studioLocalized("Comparison video export failed. \(message)")
        case .comparisonVideoExportCancelled:
            return studioLocalized("Comparison video export cancelled.")
        case .comparisonVideoRouteAwareUnavailable:
            return studioLocalized("Route-Aware comparison video unavailable.")
        case .heatmapReady(let runCount):
            return studioLocalized("Heatmap ready. \(runCount) runs included.")
        case .trendsReady(let runCount):
            return studioLocalized("Trends ready. \(runCount) runs included.")
        case .recordsReady(let runCount):
            return studioLocalized("Personal records ready. \(runCount) runs included.")
        case .queryResultPublished(let count):
            if count == 0 { return studioLocalized("No runs match the current search or filters.") }
            return studioLocalized("\(count) runs.")
        case .comparisonEntered:
            return studioLocalized("Entered comparison.")
        case .comparisonExited:
            return studioLocalized("Ended comparison.")
        case .usingDistanceAlignment:
            return studioLocalized("Using Distance alignment.")
        case .usingRouteAwareAlignment:
            return studioLocalized("Using Route-Aware alignment.")
        case .routeAlignmentReady:
            return studioLocalized("Route alignment ready.")
        case .routeAlignmentUnavailable:
            return studioLocalized("Route alignment unavailable.")
        case .replayPlayed:
            return studioLocalized("Replay playing.")
        case .replayPaused:
            return studioLocalized("Replay paused.")
        case .replayRestarted:
            return studioLocalized("Replay restarted.")
        case .replayReachedEnd:
            return studioLocalized("Replay finished.")
        case .speedChanged(let label):
            return studioLocalized("Replay speed \(label).")
        case .tagUpdateCompleted:
            return studioLocalized("Tags updated.")
        case .smartCollectionUpdated:
            return studioLocalized("Smart collection updated.")
        case .watchFolderImportCompleted(let count):
            return studioLocalized("Watch folder imported \(count) runs.")
        case .watchFolderImportFailed(let count):
            return studioLocalized("Watch folder import failed for \(count) files. See Recent Imports.")
        case .watchFolderUnavailable(let name):
            return studioLocalized("Watched folder \(name) is unavailable. Watching resumes if it returns.")
        case .watchFolderReviewReady(let name):
            return studioLocalized("\(name) has several sessions and is waiting for review.")
        case .elevationCorrectionFinished(let summary):
            return studioLocalized("Elevation correction finished. \(summary)")
        case .elevationSourceChanged(let message):
            return message
        }
    }
}

/// Policy helper that maps events to announcements without spamming.
@MainActor
final class AccessibilityAnnouncementPolicy {
    private let announcer: any AccessibilityAnnouncing
    private var lastQueryAnnouncementKey: String?

    init(announcer: any AccessibilityAnnouncing = AccessibilityAnnouncer.shared) {
        self.announcer = announcer
    }

    func handle(_ event: AccessibilityAnnouncementEvent) {
        if case .libraryLoaded(let count) = event {
            // Suppress the immediate identical query publication that follows
            // initial library loading.
            lastQueryAnnouncementKey = "query:\(count)"
        } else if case .queryResultPublished(let count) = event {
            let key = "query:\(count)"
            if key == lastQueryAnnouncementKey { return }
            lastQueryAnnouncementKey = key
        }
        announcer.announce(event.message)
    }

    /// Replay timer ticks must never announce.
    static func shouldAnnounceReplayTick() -> Bool { false }

    /// Continuous progress percentage updates must never announce.
    static func shouldAnnounceProgressPercent() -> Bool { false }
}
