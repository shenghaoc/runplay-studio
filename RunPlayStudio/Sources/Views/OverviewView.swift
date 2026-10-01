import SwiftUI
import RunPlayCore
import RunPlayPlatform

/// Overview tab showing a map with route overlay as the default landing view.
///
/// The shared current-metrics panel, replay controls, and summary are provided
/// by the parent `WorkoutDetailView` below all tabs; this view focuses on the
/// map/route context only.
///
/// `currentPointIndex` is passed explicitly from the parent so the map marker
/// tracks the replay position at 30 fps — `AppState` does not forward
/// `replayController.objectWillChange`, so direct access alone would not
/// trigger re-renders during playback.
///
/// Metric route coloring is owned by `mapViewModel` and must not rebuild on
/// every replay tick — only workout identity / analysis context updates should
/// refresh the view model.
struct OverviewView: View {
    let workout: RunWorkout
    let currentPointIndex: Int
    var mapViewModel: WorkoutRouteMapViewModel?
    var displayMode: Binding<RouteMapDisplayMode> = .constant(.twoD)
    /// Cumulative-distance window emphasized on the route (personal-record
    /// navigation); `nil` draws no overlay.
    var highlightedRangeMeters: ClosedRange<Double>? = nil

    var body: some View {
        if workout.hasRoute {
            MapReferenceView(
                routePoints: workout.routePoints,
                currentPointIndex: currentPointIndex,
                mapViewModel: mapViewModel,
                displayMode: displayMode,
                highlightedRangeMeters: highlightedRangeMeters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A map with nothing to draw is a blank canvas, not an answer.
            ContentUnavailableView {
                Label(RouteLessNoticePresentation.mapTitle, systemImage: "location.slash")
            } description: {
                Text(RouteLessNoticePresentation.mapDetail(hasHeartRate: workout.hasHeartRateData))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
