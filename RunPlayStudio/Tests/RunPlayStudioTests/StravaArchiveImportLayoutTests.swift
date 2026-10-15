import XCTest
import SwiftUI
import AppKit
import RunPlayCore
@testable import RunPlayStudio

/// The Strava archive review table must fit its sheet, and its widest labels
/// must fit their columns.
///
/// Regression context: the sheet declared a 720 pt minimum width of its own
/// while its six columns needed 843 pt, so the table was laid out wider than
/// the sheet. The last 123 pt (Status and part of Format) were clipped at the
/// sheet's edge, behind an overlay scroller that is hidden at rest. The
/// Format column also cut "Unsupported", and the Type column cut long
/// activity types such as "Mountain Bike Ride".
@MainActor
final class StravaArchiveImportLayoutTests: XCTestCase {

    private typealias Column = StravaArchiveTableColumn

    // MARK: - Width arithmetic

    func testNoColumnStartsNarrowerThanItsMinimum() {
        for column in Column.allCases {
            XCTAssertLessThanOrEqual(column.minimumWidth ?? column.idealWidth, column.idealWidth, "\(column)")
        }
    }

    /// The sheet is wider than the 720 pt minimum window, so it overhangs a
    /// small window; it must still fit the narrowest display a current Mac
    /// offers, a 13-inch MacBook Air at its Larger Text scaling.
    func testSheetFitsTheNarrowestDisplay() {
        XCTAssertLessThanOrEqual(Column.idealTableWidth, 1_024)
    }

    // MARK: - Hosted layout

    /// At the sheet's minimum width every column starts at its ideal width
    /// and the whole table is inside the sheet: nothing is clipped, and
    /// nothing needs scrolling to reach.
    func testTableFitsTheSheetAtItsMinimumWidth() throws {
        let sheetWidth = NSHostingController(rootView: sheet())
            .sizeThatFits(in: CGSize(width: 1, height: 600))
            .width
        XCTAssertEqual(sheetWidth, Column.idealTableWidth, accuracy: 0.5, "the sheet's minimum width should follow its columns")

        let host = NSHostingView(rootView: sheet())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sheetWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            scrollViews(in: host).first { $0.documentView is NSTableView },
            "the candidate table should be hosted in a scroll view"
        )
        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)

        XCTAssertEqual(table.tableColumns.count, Column.allCases.count)
        for (column, tableColumn) in zip(Column.allCases, table.tableColumns) {
            XCTAssertEqual(tableColumn.width, column.idealWidth, accuracy: 0.5, "\(column) width")
            XCTAssertEqual(
                tableColumn.minWidth,
                column.minimumWidth ?? column.idealWidth,
                accuracy: 0.5,
                "\(column) minimum width"
            )
        }

        let frame = scrollView.convert(scrollView.bounds, to: host)
        XCTAssertLessThanOrEqual(frame.maxX, host.bounds.width, "table ends past the sheet's edge: \(frame)")
        XCTAssertLessThanOrEqual(
            table.frame.width,
            scrollView.contentView.bounds.width,
            "the columns need \(table.frame.width) pt in a \(scrollView.contentView.bounds.width) pt sheet"
        )
    }

    /// A label wider than its column wraps onto a second line, and its row
    /// grows to show it, instead of being cut to one line.
    func testLongTypeAndStatusWrapOntoASecondLine() throws {
        let session = makeSession([
            candidate(index: 0),
            // "Conflicts with existing workout" is the one status wider than
            // its column. An import assigns it, not a scan.
            candidate(index: 1, type: "Mountain Bike Ride", status: .providerConflict),
        ])
        session.showRunningOnly = false
        let host = NSHostingView(rootView: sheet(session))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Column.idealTableWidth, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(scrollViews(in: host).lazy.compactMap { $0.documentView as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)

        for column in [Column.type, .status] {
            let index = try XCTUnwrap(Column.allCases.firstIndex(of: column))
            let oneLine = try XCTUnwrap(table.view(atColumn: index, row: 0, makeIfNecessary: true)).fittingSize
            let wrapped = try XCTUnwrap(table.view(atColumn: index, row: 1, makeIfNecessary: true)).fittingSize
            XCTAssertGreaterThan(wrapped.height, oneLine.height, "\(column) should wrap rather than truncate")
        }

        // A row takes its height from its cells when the table draws.
        window.displayIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, table.rect(ofRow: 0).height, "the wrapped row should grow")
    }

    // MARK: - Labels

    /// The widest date in each supported language's region fits on one line:
    /// a two-digit month and day.
    func testWidestDatesFitOnOneLine() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for identifier in ["en_US", "zh_CN", "zh_TW"] {
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.locale = Locale(identifier: identifier)
            style.timeZone = timeZone
            for month in 1...12 {
                let date = try XCTUnwrap(
                    calendar.date(from: DateComponents(year: 2021, month: month, day: 28, hour: 10, minute: 3))
                )
                let text = date.formatted(style)
                let width = lineWidth(of: Text(text).font(AppDesign.Typography.compactLabel))
                XCTAssertLessThanOrEqual(width, Column.date.idealWidth, "\(identifier): \(text)")
            }
        }
    }

    /// The Format column has a fixed width and its names are single words,
    /// which cannot wrap, so each must fit on one line.
    func testEveryFormatFitsOneLine() {
        for format in WorkoutArchiveActivityFormat.allCases {
            assertFits(format.displayName, lines: 1, width: Column.format.idealWidth)
        }
    }

    /// A long Strava activity type wraps onto two lines between words, never
    /// through one. These are the widest types the import policy names.
    func testWidestActivityTypesWrapBetweenWordsOntoTwoLines() {
        let types = [
            "Weight Training",
            "Backcountry Ski",
            "Open Water Swim",
            "Stand Up Paddling",
            "Mountain Bike Ride",
        ]
        for type in types {
            assertFits(type, lines: 2, width: Column.type.idealWidth)
        }
    }

    func testEveryStatusFitsTwoLinesAndUnsupportedActivityTypeFitsOne() {
        for status in WorkoutArchiveCandidateStatus.allCases {
            assertFits(status.userFacingSummary, lines: 2, width: Column.status.idealWidth)
        }
        assertFits(
            WorkoutArchiveCandidateStatus.unsupportedActivityType.userFacingSummary,
            lines: 1,
            width: Column.status.idealWidth
        )
    }

    // MARK: - Helpers

    private func sheet(_ session: ArchiveImportSession? = nil) -> StravaArchiveImportView {
        StravaArchiveImportView(
            session: session ?? makeSession(),
            onImport: {},
            onCancel: {},
            onDone: {},
            onViewImported: {},
            onOpenHeatmap: {}
        )
    }

    private func candidate(
        index: Int,
        type: String = "Run",
        status: WorkoutArchiveCandidateStatus = .ready
    ) -> WorkoutArchiveCandidate {
        WorkoutArchiveCandidate(
            id: "layout-\(index)",
            archiveRelativePath: "activities/\(index + 1).fit.gz",
            providerActivityID: "\(index + 1)",
            activityName: "Layout Run \(index + 1)",
            activityType: type,
            activityDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
            format: .fitGzip,
            status: status,
            isSelectedByDefault: status.isImportableByDefault,
            archiveOrder: index
        )
    }

    private func makeSession(_ candidates: [WorkoutArchiveCandidate]? = nil) -> ArchiveImportSession {
        let candidates = candidates ?? (0..<3).map { candidate(index: $0) }
        return ArchiveImportSession(
            archiveURL: URL(fileURLWithPath: "/tmp/layout.zip"),
            scanResult: WorkoutArchiveScanResult(
                candidates: candidates,
                diagnostics: WorkoutArchiveScanDiagnostics(archiveName: "layout.zip"),
                isRecognizedStravaExport: true
            ),
            securityScoped: false
        )
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    /// Width SwiftUI lays `view` out at on one line.
    private func lineWidth<V: View>(of view: V) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    private func assertFits(
        _ text: String,
        lines maximumLines: Int,
        width: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let lines = lineCount(text, width: width) else {
            XCTFail("\"\(text)\" has a word wider than \(width) pt", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            lines,
            maximumLines,
            "\"\(text)\" needs \(lines) lines at \(width) pt",
            file: file,
            line: line
        )
    }

    /// Lines a table cell's text needs at `width` when it wraps only between
    /// words, or `nil` when a single word is wider than `width`.
    private func lineCount(_ text: String, width: CGFloat) -> Int? {
        let words = text.split(separator: " ").map(String.init)
        guard words.allSatisfy({ lineWidth(of: Text($0)) <= width }) else { return nil }
        var lines = 1
        var line = ""
        for word in words {
            let candidate = line.isEmpty ? word : line + " " + word
            if line.isEmpty || lineWidth(of: Text(candidate)) <= width {
                line = candidate
            } else {
                lines += 1
                line = word
            }
        }
        return lines
    }
}
