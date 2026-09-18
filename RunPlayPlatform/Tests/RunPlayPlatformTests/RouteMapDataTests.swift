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

// MARK: - Highlighted range overlay (personal-record windows)

final class RouteMapHighlightTests: XCTestCase {

    /// Synthetic route: 0–5 km in one segment, a pause (distance plateau)
    /// across a relocation into segment 1, then 5–12 km. A 10 km record
    /// window [0, 10 km] spans the pause in cumulative distance.
    private func makePausedRoute() -> [RoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed = 0.0
        for index in 0...120 {
            let distance = Double(index) * 100
            let relocated = distance >= 5_000
            let lat = (relocated ? 38.2 : 37.7) + (distance - (relocated ? 5_000 : 0)) / 111_000
            let lon = -122.42 + distance / 90_000
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: lat,
                longitude: lon,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                routeSegmentIndex: relocated ? 1 : 0
            ))
            if index == 50 {
                // Pause: 600 s of elapsed time at the same distance.
                elapsed += 600
                points.append(RoutePoint(
                    timestamp: start.addingTimeInterval(elapsed),
                    latitude: lat,
                    longitude: lon,
                    distanceFromStartMeters: distance,
                    elapsedSeconds: elapsed,
                    routeSegmentIndex: 1
                ))
            }
            elapsed += 24
        }
        return points
    }

    func testWindowSpanningPauseSplitsHighlightPerSegment() {
        let points = makePausedRoute()
        let lines = RouteMapContent.highlightedRangeLines(
            idPrefix: "route",
            points: points,
            startDistanceMeters: 0,
            endDistanceMeters: 10_000
        )

        // One line per covered segment — the overlay never bridges the
        // relocation gap with a single polyline.
        XCTAssertEqual(lines.count, 2, "window spans a pause; overlay must split per segment")
        XCTAssertTrue(lines.allSatisfy { $0.style == .highlight })
        XCTAssertTrue(lines.allSatisfy { $0.coordinates.count >= 2 })

        // Segment-0 side covers [0, 5000]; segment-1 side covers the rest.
        let segmentZeroLatitudes = lines[0].coordinates.map(\.latitude)
        XCTAssertTrue(segmentZeroLatitudes.allSatisfy { $0 < 38.0 },
                      "first line stays on the pre-pause side of the relocation")
        let segmentOneLatitudes = lines[1].coordinates.map(\.latitude)
        XCTAssertTrue(segmentOneLatitudes.allSatisfy { $0 > 38.0 },
                      "second line stays on the relocated side")
    }

    func testHighlightBoundaryInterpolatesInsideASegment() {
        let points = makePausedRoute()
        // End boundary at 7'350 m falls strictly inside segment 1 between
        // the 7'300 and 7'400 samples: the overlay interpolates it exactly.
        let lines = RouteMapContent.highlightedRangeLines(
            idPrefix: "route",
            points: points,
            startDistanceMeters: 7_000,
            endDistanceMeters: 7_350
        )
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertEqual(line.coordinates.count, 5,
                       "samples at 7000/7100/7200/7300 plus the interpolated 7350 boundary")
        // All coordinates live on the relocated side; nothing crosses the gap.
        XCTAssertTrue(line.coordinates.map(\.latitude).allSatisfy { $0 > 38.0 })
    }

    func testWindowInsideGapProducesNoLine() {
        let points = makePausedRoute()
        // The pause is a zero-distance plateau: no window can sit inside it,
        // but a degenerate/inverted range must still produce nothing.
        XCTAssertTrue(RouteMapContent.highlightedRangeLines(
            idPrefix: "route",
            points: points,
            startDistanceMeters: 4_000,
            endDistanceMeters: 4_000
        ).isEmpty)
        // A window with no valid coordinates inside (beyond the route) is empty.
        XCTAssertTrue(RouteMapContent.highlightedRangeLines(
            idPrefix: "route",
            points: points,
            startDistanceMeters: 20_000,
            endDistanceMeters: 21_000
        ).isEmpty)
    }
}
