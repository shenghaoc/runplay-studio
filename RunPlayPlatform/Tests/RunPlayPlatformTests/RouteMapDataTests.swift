import MapKit
import RunPlayCore
import RunPlayPlatform
import XCTest

final class RouteMapDataTests: XCTestCase {

    func testAreasFromSnapshotHaveStableIDsAndPolygonOrder() {
        let cellID = PersonalHeatmapCellID(x: 10, y: -3)
        let bounds = PersonalHeatmapProjection.cellBounds(id: cellID, cellSizeMeters: 50)!
        let cell = PersonalHeatmapCell(
            id: cellID,
            workoutCount: 3,
            normalizedIntensity: 0.7,
            bounds: bounds
        )
        let snapshot = PersonalHeatmapSnapshot(
            cells: [cell],
            statistics: .empty,
            diagnostics: .empty,
            configuration: PersonalHeatmapConfiguration(),
            bounds: nil
        )

        let areas = RouteMapContent.areas(from: snapshot)
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas[0].id, "heatmap-10--3")
        XCTAssertEqual(areas[0].workoutCount, 3)
        XCTAssertEqual(areas[0].normalizedIntensity, 0.7, accuracy: 1e-9)
        // Closed ring: 5 coordinates (SW→SE→NE→NW→SW).
        XCTAssertEqual(areas[0].coordinates.count, 5)
        XCTAssertEqual(areas[0].coordinates.first, areas[0].coordinates.last)
    }

    func testMapRectFromAreasOnly() {
        let coords = [
            RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!,
            RouteMapCoordinate(latitude: 1.30, longitude: 103.81)!,
            RouteMapCoordinate(latitude: 1.31, longitude: 103.81)!,
            RouteMapCoordinate(latitude: 1.31, longitude: 103.80)!,
            RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!
        ]
        let area = RouteMapArea(
            id: "a",
            coordinates: coords,
            normalizedIntensity: 0.5,
            workoutCount: 2
        )
        let rect = RouteMapContent.mapRect(routes: [], areas: [area])
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect!.width, 0)
        XCTAssertGreaterThan(rect!.height, 0)
    }

    func testMapRectFromRoutesAndAreas() {
        let route = RouteMapLine(
            id: "r",
            coordinates: [
                RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!,
                RouteMapCoordinate(latitude: 1.32, longitude: 103.82)!
            ],
            style: .primary
        )
        let area = RouteMapArea(
            id: "a",
            coordinates: [
                RouteMapCoordinate(latitude: 1.29, longitude: 103.79)!,
                RouteMapCoordinate(latitude: 1.29, longitude: 103.83)!,
                RouteMapCoordinate(latitude: 1.33, longitude: 103.83)!,
                RouteMapCoordinate(latitude: 1.33, longitude: 103.79)!,
                RouteMapCoordinate(latitude: 1.29, longitude: 103.79)!
            ],
            normalizedIntensity: 1,
            workoutCount: 1
        )
        let combined = RouteMapContent.mapRect(routes: [route], areas: [area])
        let routesOnly = RouteMapContent.mapRect(for: [route])
        XCTAssertNotNil(combined)
        XCTAssertNotNil(routesOnly)
        // Combined should be at least as large as routes-only.
        XCTAssertGreaterThanOrEqual(combined!.width, routesOnly!.width - 1)
        XCTAssertGreaterThanOrEqual(combined!.height, routesOnly!.height - 1)
    }

    func testEmptyMapRectIsNil() {
        XCTAssertNil(RouteMapContent.mapRect(routes: [], areas: []))
        XCTAssertNil(RouteMapContent.mapRect(for: []))
    }

    func testRouteOnlyMapRectRegression() {
        let route = RouteMapLine(
            id: "r",
            coordinates: [
                RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!,
                RouteMapCoordinate(latitude: 1.31, longitude: 103.81)!
            ],
            style: .primary
        )
        let rect = RouteMapContent.mapRect(for: [route])
        XCTAssertNotNil(rect)
        // Minimum span still applied.
        XCTAssertGreaterThan(rect!.width, 0)
    }

    func testCameraPlanWithAreas() {
        let area = RouteMapArea(
            id: "a",
            coordinates: [
                RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!,
                RouteMapCoordinate(latitude: 1.30, longitude: 103.81)!,
                RouteMapCoordinate(latitude: 1.31, longitude: 103.81)!,
                RouteMapCoordinate(latitude: 1.31, longitude: 103.80)!,
                RouteMapCoordinate(latitude: 1.30, longitude: 103.80)!
            ],
            normalizedIntensity: 0.4,
            workoutCount: 1
        )
        let plan = RouteMapContent.cameraPlan(routes: [], areas: [area])
        XCTAssertNotNil(plan)
        XCTAssertGreaterThan(plan!.distance, 0)
    }
}
