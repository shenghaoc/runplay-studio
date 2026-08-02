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
    case heatmapReady(runCount: Int)
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

    var message: String {
        switch self {
        case .libraryLoaded(let count):
            return count == 1 ? "Library loaded. 1 run." : "Library loaded. \(count) runs."
        case .importCompleted(let name):
            return "Imported \(name)."
        case .importCancelled:
            return "Import cancelled."
        case .importFailed(let message):
            return "Import failed. \(message)"
        case .exportPreviewReady:
            return "Export preview ready."
        case .exportCompleted(let name):
            return "Exported \(name)."
        case .exportFailed(let message):
            return "Export failed. \(message)"
        case .videoPreviewReady:
            return "Video preview ready."
        case .videoPreviewFailed(let message):
            return "Video preview failed. \(message)"
        case .videoExportCompleted(let name):
            return "Video exported \(name)."
        case .videoExportFailed(let message):
            return "Video export failed. \(message)"
        case .videoExportCancelled:
            return "Video export cancelled."
        case .heatmapReady(let runCount):
            return "Heatmap ready. \(runCount) runs included."
        case .queryResultPublished(let count):
            if count == 0 { return "No runs match the current search or filters." }
            return count == 1 ? "1 run." : "\(count) runs."
        case .comparisonEntered:
            return "Entered comparison."
        case .comparisonExited:
            return "Ended comparison."
        case .usingDistanceAlignment:
            return "Using Distance alignment."
        case .usingRouteAwareAlignment:
            return "Using Route-Aware alignment."
        case .routeAlignmentReady:
            return "Route alignment ready."
        case .routeAlignmentUnavailable:
            return "Route alignment unavailable."
        case .replayPlayed:
            return "Replay playing."
        case .replayPaused:
            return "Replay paused."
        case .replayRestarted:
            return "Replay restarted."
        case .replayReachedEnd:
            return "Replay finished."
        case .speedChanged(let label):
            return "Replay speed \(label)."
        case .tagUpdateCompleted:
            return "Tags updated."
        case .smartCollectionUpdated:
            return "Smart collection updated."
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
