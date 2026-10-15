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

    // MARK: - Keys in the table

    /// Space in the table toggles the selected row's checkbox and imports
    /// nothing. Tab reaches the table but not the checkboxes inside it, so this
    /// is the keyboard's way to them.
    func testSpaceInTheTableTogglesTheSelectedRow() throws {
        let outcome = try pressInTable(["space"])
        XCTAssertEqual(outcome.session.selectedIDs, [])
        XCTAssertEqual(outcome.imports, 0)
        XCTAssertEqual(outcome.cancels, 0)
    }

    /// Return in the table is still the sheet's Import.
    func testReturnInTheTableStillImports() throws {
        let outcome = try pressInTable(["return"])
        XCTAssertEqual(outcome.imports, 1)
        XCTAssertEqual(outcome.session.selectedIDs, ["run-0"])
    }

    /// Escape after Space is still the sheet's Cancel.
    func testEscapeAfterSpaceInTheTableStillCancels() throws {
        let outcome = try pressInTable(["space", "escape"])
        XCTAssertEqual(outcome.cancels, 1)
        XCTAssertEqual(outcome.imports, 0)
    }

    // MARK: - Harness

    /// Host the review with its one row selected and the table focused, then
    /// deliver each key as AppKit does: as a key equivalent first, then to the
    /// first responder.
    private func pressInTable(
        _ keys: [String]
    ) throws -> (session: AppleHealthImportSession, imports: Int, cancels: Int) {
        var imports = 0
        var cancels = 0
        let session = makeSession()
        session.tableSelection = ["run-0"]
        let host = NSHostingView(rootView: AppleHealthImportView(
            session: session,
            onImport: { imports += 1 },
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
        for _ in 0..<5 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

        let table = try XCTUnwrap(firstTable(in: host), "the review has no table view")
        XCTAssertTrue(window.makeFirstResponder(table))
        let codes: [String: (UInt16, String)] = ["space": (49, " "), "return": (36, "\r"), "escape": (53, "\u{1b}")]
        for key in keys {
            let (code, characters) = try XCTUnwrap(codes[key])
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            ))
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (session, imports, cancels)
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

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
