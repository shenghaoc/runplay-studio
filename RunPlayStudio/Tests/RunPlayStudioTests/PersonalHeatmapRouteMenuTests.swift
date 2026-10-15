import Combine
import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// The Personal Heatmap route menu's Any Route row, through the binding that
/// `PersonalHeatmapView` gives it: which states check it, and what choosing
/// it does.
@MainActor
final class PersonalHeatmapRouteMenuTests: XCTestCase {
    private let group = RouteGroupsWorkspaceFixtures.namingGroup(bearingDegrees: 45, totalDistanceMeters: 1_200)

    private func makeViewModel() -> PersonalHeatmapViewModel {
        let vm = PersonalHeatmapViewModel()
        vm.applyOrganization(RouteGroupsWorkspaceFixtures.organization(groups: [group]))
        return vm
    }

    func testAnyRouteIsCheckedOnlyWhileNoRouteIsChosen() {
        let vm = makeViewModel()
        let anyRoute = PersonalHeatmapView.anyRouteMenuCheck(for: vm)
        XCTAssertTrue(anyRoute.wrappedValue, "Any Route is the heatmap's default")

        vm.routeFilter = .group(group.id)
        XCTAssertFalse(anyRoute.wrappedValue, "the chosen route's own row is checked instead")

        // The chosen route goes away, and the heatmap falls back to Any Route.
        vm.applyOrganization(RouteGroupsWorkspaceFixtures.organization(groups: []))
        XCTAssertEqual(vm.routeFilter, .anyRoute)
        XCTAssertTrue(anyRoute.wrappedValue)
    }

    func testChoosingAnyRouteAppliesItEvenWhenChecked() {
        let vm = makeViewModel()
        vm.routeFilter = .group(group.id)
        let anyRoute = PersonalHeatmapView.anyRouteMenuCheck(for: vm)
        var writes: [WorkoutLibraryRouteFilter] = []
        let recorder = vm.$routeFilter.dropFirst().sink { writes.append($0) }
        defer { recorder.cancel() }

        anyRoute.wrappedValue = true
        // A menu sends `false` when its checked Toggle row is chosen again.
        anyRoute.wrappedValue = false

        XCTAssertEqual(writes, [.anyRoute, .anyRoute], "the Button applied Any Route again too")
        XCTAssertEqual(vm.routeFilter, .anyRoute)
        XCTAssertTrue(anyRoute.wrappedValue)
    }
}
