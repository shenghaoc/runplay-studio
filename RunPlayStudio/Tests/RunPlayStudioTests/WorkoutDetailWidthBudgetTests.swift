import XCTest
import SwiftUI
import AppKit
import RunPlayCore
@testable import RunPlayStudio

/// The workout detail view must fit the detail column at the minimum window.
///
/// Regression context (#146): the header's metric row and the replay dock
/// could not shrink below roughly 750 pt, but at the 720 pt window minimum
/// the detail column beside the sidebar is under 500 pt. The whole detail
/// view was then laid out wider than its column and clipped on both edges,
/// so the Splits table lost its first columns and Power, HR and Elevation
/// could not be scrolled to. The table itself was never the problem: on its
/// own it stays inside its container and scrolls its full width.
@MainActor
final class WorkoutDetailWidthBudgetTests: XCTestCase {

    private let budget = AppDesign.WindowLayout.workspaceWidthBudget

    func testEveryTabFitsTheWorkspaceWidthBudget() {
        for tab in WorkoutDetailView.ViewTab.allCases {
            let minimum = minimumWidth(of: detailView(tab: tab))
            XCTAssertLessThanOrEqual(
                minimum,
                budget,
                "\(tab.rawValue) tab needs \(minimum)pt; the detail column at the minimum window is \(budget)pt"
            )
        }
    }

    /// The symptom users saw: at the budget width the splits table must lie
    /// inside the detail column, with its full column width scrollable.
    func testSplitsTableStaysInsideTheColumnAtTheBudgetWidth() throws {
        let host = NSHostingView(rootView: detailView(tab: .splits))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: budget, height: 552),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(
            scrollViews(in: host).first { $0.documentView is NSTableView },
            "the splits table should be hosted in a scroll view"
        )
        let frame = table.convert(table.bounds, to: host)
        XCTAssertGreaterThanOrEqual(frame.minX, 0, "table starts off the leading edge: \(frame)")
        XCTAssertLessThanOrEqual(frame.maxX, host.bounds.width, "table ends past the trailing edge: \(frame)")

        let documentWidth = try XCTUnwrap(table.documentView).frame.width
        XCTAssertGreaterThan(
            documentWidth,
            frame.width,
            "at this width the eleven columns should overflow into horizontal scrolling"
        )
    }

    // MARK: - Helpers

    private func minimumWidth<V: View>(of view: V) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 1, height: 552))
            .width
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }

    private func detailView(tab: WorkoutDetailView.ViewTab) -> some View {
        let appState = AppState(storeActor: nil, importService: nil)
        appState.workoutDetailTabRaw = tab.rawValue
        return WorkoutDetailView(workout: makeWorkout(), appState: appState)
    }

    /// Carries heart rate, cadence and power so the header and the replay
    /// dock show every optional metric — their widest configuration.
    private func makeWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0...80).map { index in
            let offset = Double(index)
            return RoutePoint(
                timestamp: start.addingTimeInterval(offset * 30),
                latitude: 1.3 + offset * 0.001,
                longitude: 103.8 + offset * 0.001,
                distanceFromStartMeters: offset * 100,
                elapsedSeconds: offset * 30,
                heartRateBPM: 150,
                cadence: 170,
                powerWatts: 250
            )
        }
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Width Budget", startDate: start),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 8_000,
                totalElapsedSeconds: 2_400,
                averageHeartRateBPM: 150
            )
        )
        workout.splits = (1...8).map { index in
            RunSplit(
                splitIndex: index,
                elapsedSeconds: 300,
                paceSecondsPerKilometer: 300,
                averageHeartRateBPM: 150,
                averagePowerWatts: 250,
                elevationGainMeters: 5,
                startDistanceMeters: Double(index - 1) * 1_000,
                endDistanceMeters: Double(index) * 1_000
            )
        }
        return workout
    }
}
