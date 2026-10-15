import XCTest
import SwiftUI
import AppKit
import RunPlayCore
@testable import RunPlayStudio

/// The multi-session FIT review table must fit its sheet, and its widest
/// labels must fit their columns.
///
/// Regression context: the sheet declared a 940 pt minimum width of its own
/// while its nine columns needed 996 pt, so the table was laid out wider than
/// the sheet and the Status column was clipped at the sheet's edge
/// ("Unsupported sp"). The Sport column cut "Wheelchair push run" and
/// "Wheelchair push walk" to the same "Wheelchai…", and the Date column cut
/// "Sep 8, 2021 at 10:03 AM" and "2021年9月8日 上午10:03".
@MainActor
final class FITSessionImportLayoutTests: XCTestCase {

    private typealias Column = FITSessionTableColumn

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
            "the session table should be hosted in a scroll view"
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

    // MARK: - Labels

    /// The widest date in each supported language's region fits on one line:
    /// a two-digit month, day and hour.
    func testWidestDatesFitOnOneLine() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for identifier in ["en_US", "zh_CN", "zh_TW"] {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.locale = Locale(identifier: identifier)
            style.timeZone = timeZone
            for month in 1...12 {
                let date = try XCTUnwrap(
                    calendar.date(from: DateComponents(year: 2021, month: month, day: 28, hour: 10, minute: 3))
                )
                let text = date.formatted(style)
                let width = lineWidth(of: Text(text).font(AppDesign.Typography.compactLabel).monospacedDigit())
                XCTAssertLessThanOrEqual(width, Column.date.idealWidth, "\(identifier): \(text)")
            }
        }
    }

    /// A long sport name wraps onto two lines between words, never through
    /// one. These are the widest names, including the full FIT profile's
    /// wheelchair and stand-up paddleboarding sports.
    func testWidestSportNamesWrapBetweenWordsOntoTwoLines() {
        let names = [
            "Unrecognised",
            "Cross-country skiing",
            "Wheelchair push run",
            "Wheelchair push walk",
            "Stand-up paddleboarding",
        ]
        for name in names {
            assertFits(name, lines: 2, width: Column.sport.idealWidth)
        }
    }

    func testEveryStatusFitsTwoLinesAndUnsupportedSportFitsOne() {
        for status in FITSessionCandidateStatus.allCases {
            assertFits(status.userFacingSummary, lines: 2, width: Column.status.idealWidth)
        }
        assertFits(
            FITSessionCandidateStatus.unsupportedSport.userFacingSummary,
            lines: 1,
            width: Column.status.idealWidth
        )
    }

    // MARK: - Helpers

    private func sheet() -> FITSessionImportView {
        FITSessionImportView(
            session: makeSession(),
            onImport: {},
            onCancel: {},
            onDone: {},
            onViewImported: {},
            onOpenAllRuns: {}
        )
    }

    private func makeSession() -> FITSessionImportSession {
        let candidates = (0..<3).map { index in
            FITSessionDescriptor(
                sourceIndex: index,
                startDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600),
                sport: .running,
                sportDescription: "Running",
                elapsedSeconds: 1_800,
                reportedDistanceMeters: 5_000,
                gpsRecordCount: 1_800,
                recordedLapCount: 5,
                status: .ready,
                isSelectedByDefault: true,
                providerActivityID: "layout-\(index)",
                displayName: "Layout — Run \(index + 1)"
            )
        }
        return FITSessionImportSession(
            fileURL: URL(fileURLWithPath: "/tmp/layout.fit"),
            scanResult: FITSessionScanResult(routing: .review, fileName: "layout.fit", candidates: candidates),
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
