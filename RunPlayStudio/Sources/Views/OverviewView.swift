import SwiftUI
import RunPlayCore

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

    var body: some View {
        MapReferenceView(
            routePoints: workout.routePoints,
            currentPointIndex: currentPointIndex,
            mapViewModel: mapViewModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
