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

    func testSheetWidthUsesVisibleFrameAfterSideDock() {
        let display = NSRect(x: 0, y: 0, width: 1_024, height: 768)
        let visibleFrame = display.divided(atDistance: 176, from: .minXEdge).remainder
        XCTAssertEqual(visibleFrame.width, 848)
        XCTAssertEqual(Column.maximumSheetWidth(visibleFrameWidth: visibleFrame.width), 832)
        for style in [NSScroller.Style.overlay, .legacy] {
            XCTAssertEqual(
                Column.minimumSheetWidth(scrollerStyle: style, visibleFrameWidth: visibleFrame.width),
                832
            )
        }
    }

    // MARK: - Hosted layout

    func testVerticallyScrollingTableFitsWithOverlayScrollbars() throws {
        try assertVerticallyScrollingTableFits(style: .overlay)
    }

    func testVerticallyScrollingTableFitsWithLegacyScrollbars() throws {
        try assertVerticallyScrollingTableFits(style: .legacy)
    }

    private func assertVerticallyScrollingTableFits(style: NSScroller.Style) throws {
        let sheetWidth = Column.minimumSheetWidth(scrollerStyle: style, visibleFrameWidth: nil)
        let rowCount = 48
        let root = sheet(makeSession((0..<rowCount).map { candidate(index: $0) }), scrollerStyle: style)
        let measuredWidth = NSHostingController(rootView: root)
            .sizeThatFits(in: CGSize(width: 1, height: 600))
            .width
        XCTAssertEqual(measuredWidth, sheetWidth, accuracy: 0.5, "the sheet's minimum width should follow its columns")
        let host = NSHostingView(rootView: root)
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
        scrollView.scrollerStyle = style
        scrollView.tile()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(scrollView.scrollerStyle, style)

        let table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, rowCount)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(table.frame.height, scrollView.contentView.bounds.height, "the fixture must scroll vertically")

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

    /// Like the Strava table, the FIT table must grow its wrapped rows.
    func testLongSportAndStatusWrapOntoASecondLine() throws {
        let session = makeSession([
            candidate(index: 0),
            candidate(index: 1, sport: "Stand-up paddleboarding", status: .invalidBoundaries),
        ])
        let style = NSScroller.preferredScrollerStyle
        let host = NSHostingView(rootView: sheet(session, scrollerStyle: style))
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Column.minimumSheetWidth(scrollerStyle: style, visibleFrameWidth: nil),
                height: 600
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(scrollViews(in: host).lazy.compactMap { $0.documentView as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 2)

        for column in [Column.sport, .status] {
            let index = try XCTUnwrap(Column.allCases.firstIndex(of: column))
            let oneLine = try XCTUnwrap(table.view(atColumn: index, row: 0, makeIfNecessary: true)).fittingSize
            let wrapped = try XCTUnwrap(table.view(atColumn: index, row: 1, makeIfNecessary: true)).fittingSize
            XCTAssertGreaterThan(wrapped.height, oneLine.height, "\(column) should wrap rather than truncate")
        }

        window.displayIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, table.rect(ofRow: 0).height, "the wrapped row should grow")
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

    private func sheet(
        _ session: FITSessionImportSession,
        scrollerStyle: NSScroller.Style
    ) -> FITSessionImportView {
        FITSessionImportView(
            session: session,
            onImport: {},
            onCancel: {},
            onDone: {},
            onViewImported: {},
            onOpenAllRuns: {},
            scrollerStyle: scrollerStyle,
            visibleFrameWidth: 2_000
        )
    }

    private func candidate(
        index: Int,
        sport: String = "Running",
        status: FITSessionCandidateStatus = .ready
    ) -> FITSessionDescriptor {
        FITSessionDescriptor(
            sourceIndex: index,
            startDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600),
            sport: .running,
            sportDescription: sport,
            elapsedSeconds: 1_800,
            reportedDistanceMeters: 5_000,
            gpsRecordCount: 1_800,
            recordedLapCount: 5,
            status: status,
            isSelectedByDefault: status.isImportableByDefault,
            providerActivityID: "layout-\(index)",
            displayName: "Layout — Run \(index + 1)"
        )
    }

    private func makeSession(_ candidates: [FITSessionDescriptor]) -> FITSessionImportSession {
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
