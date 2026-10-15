import AppKit
import SwiftUI
import XCTest
import RunPlayCore
@testable import RunPlayPlatform
@testable import RunPlayStudio

/// Escape cancels the Apple Health sheet in every phase that offers Cancel.
///
/// The review's Cancel and the progress view's Cancel are separate buttons, so a
/// shortcut on one says nothing about the other. The sheet is hosted in an
/// offscreen window and Escape is sent as a key equivalent, the path AppKit
/// gives a keypress, so these tests exercise what a keyboard user does.
@MainActor
final class AppleHealthImportViewKeyboardTests: XCTestCase {

    /// Also proves the harness delivers Escape at all, which the committing
    /// test below depends on to mean anything.
    func testEscapeCancelsTheReview() throws {
        XCTAssertEqual(try cancelsAfterEscape(phase: .reviewing), 1)
    }

    func testEscapeCancelsARunningImport() throws {
        XCTAssertEqual(try cancelsAfterEscape(phase: .importing), 1)
    }

    /// A commit cannot be cancelled, so its disabled Cancel ignores Escape.
    func testEscapeDoesNotCancelWhileCommitting() throws {
        XCTAssertEqual(try cancelsAfterEscape(phase: .importing, progress: .committing), 0)
    }

    // MARK: - Harness

    private func cancelsAfterEscape(
        phase: AppleHealthImportUIPhase,
        progress: AppleHealthImportProgress.Phase = .importing
    ) throws -> Int {
        var cancels = 0
        let session = makeSession()
        session.phase = phase
        session.progress = AppleHealthImportProgress(phase: progress, totalCount: 1)
        let host = NSHostingView(rootView: AppleHealthImportView(
            session: session,
            onImport: {},
            onCancel: { cancels += 1 },
            onDone: {},
            onViewImported: {}
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        // SwiftUI installs a button's shortcut when its view graph updates, so
        // give it a few run-loop turns rather than one fixed wait.
        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if window.performKeyEquivalent(with: escape) { break }
        }
        return cancels
    }

    private func makeSession() -> AppleHealthImportSession {
        let window = AppleHealthWorkoutWindow(
            startSeconds: 1_700_000_000,
            endSeconds: 1_700_001_800,
            activityType: "HKWorkoutActivityTypeRunning",
            utcOffsetSeconds: 0
        )
        let candidate = AppleHealthWorkoutCandidate(id: "run-0", sourceIndex: 0, window: window)
        let result = AppleHealthArchiveScanResult(
            scan: AppleHealthExportScan(
                workouts: [AppleHealthExportScan.WorkoutEntry(
                    window: window,
                    statistics: [],
                    routeArchivePath: nil,
                    heartRate: []
                )],
                droppedWorkoutCount: 0
            ),
            candidates: [candidate],
            exportXMLEntryPath: "apple_health_export/export.xml",
            usedCaseInsensitiveXMLLookup: false,
            report: AppleHealthArchiveReport(
                workoutCount: 1,
                candidateCount: 1,
                duplicateCandidateCount: 0,
                droppedWorkoutCount: 0,
                unmatchedRouteReferenceCount: 0,
                routeEntryCount: 0,
                entryCount: 1,
                uncompressedXMLBytes: 0
            )
        )
        return AppleHealthImportSession(
            archiveURL: FileManager.default.temporaryDirectory.appendingPathComponent("export.zip"),
            scanResult: result,
            securityScoped: false
        )
    }
}
