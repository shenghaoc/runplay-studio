import MapKit
import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class MapSnapshotRegionPlannerTests: XCTestCase {
    private let portraitSize = CGSize(width: 1_120, height: 560)

    func testNormalRouteProducesFiniteRect() {
        let routes = [line(id: "a", coords: [
            (37.77, -122.42),
            (37.78, -122.41),
            (37.79, -122.40)
        ])]
        let rect = MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize)
        XCTAssertNotNil(rect)
        XCTAssertFalse(rect!.isNull)
        XCTAssertGreaterThan(rect!.size.width, 0)
        XCTAssertGreaterThan(rect!.size.height, 0)
        assertInsideWorld(rect!)
    }

    func testVeryShortRouteStillVisible() throws {
        let routes = [line(id: "short", coords: [
            (37.7749, -122.4194),
            (37.7750, -122.4193)
        ])]
        let rect = try XCTUnwrap(MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize))
        let center = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let mpp = MKMetersPerMapPointAtLatitude(center.latitude)
        let spanMeters = min(rect.size.width, rect.size.height) * mpp
        XCTAssertGreaterThanOrEqual(spanMeters, MapSnapshotRegionPlanner.minimumSpanMeters * 0.99)
    }

    func testOnePointRouteUsesMarkerAndMinimumSpan() throws {
        let coord = RouteMapCoordinate(latitude: 40.0, longitude: -74.0)!
        let routes = [RouteMapLine(id: "pt", coordinates: [coord], style: .primary)]
        let markers = [
            RouteMapMarker(id: "s", title: "Start", coordinate: coord, style: .start)
        ]
        let rect = try XCTUnwrap(
            MapSnapshotRegionPlanner.planMapRect(routes: routes, markers: markers, imageSize: portraitSize)
        )
        XCTAssertGreaterThan(rect.size.width, 0)
        assertInsideWorld(rect)
    }

    func testMultipleDisconnectedSegmentsCovered() throws {
        let routes = [
            line(id: "seg0", coords: [(37.77, -122.42), (37.771, -122.421)]),
            line(id: "seg1", coords: [(37.80, -122.40), (37.801, -122.401)])
        ]
        let rect = try XCTUnwrap(MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize))
        for route in routes {
            for c in route.coordinates {
                let p = MKMapPoint(c.mapKitCoordinate)
                XCTAssertTrue(rect.contains(p), "Expected rect to contain \(c.latitude),\(c.longitude)")
            }
        }
    }

    func testPortraitAspectRatioExpansion() throws {
        // Wide east-west route vs tall portrait image → height should expand.
        let routes = [line(id: "wide", coords: [
            (37.77, -122.45),
            (37.77, -122.40)
        ])]
        let rect = try XCTUnwrap(MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize))
        let imageAspect = portraitSize.width / portraitSize.height
        let mapAspect = rect.size.width / rect.size.height
        XCTAssertEqual(mapAspect, imageAspect, accuracy: 0.05)
    }

    func testProportionalPaddingExpandsBeyondBareBounds() throws {
        let routes = [line(id: "a", coords: [
            (37.77, -122.42),
            (37.78, -122.41)
        ])]
        let bare = try XCTUnwrap(RouteMapContent.mapRect(for: routes))
        let planned = try XCTUnwrap(MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize))
        XCTAssertGreaterThan(planned.size.width, bare.size.width)
        XCTAssertGreaterThan(planned.size.height, bare.size.height)
    }

    func testWorldBoundClamping() {
        let huge = MKMapRect(
            x: -1_000_000,
            y: -1_000_000,
            width: MKMapSize.world.width * 3,
            height: MKMapSize.world.height * 3
        )
        let clamped = MapSnapshotRegionPlanner.clampToWorld(huge)
        assertInsideWorld(clamped)
        XCTAssertLessThanOrEqual(clamped.size.width, MKMapSize.world.width + 1)
        XCTAssertLessThanOrEqual(clamped.size.height, MKMapSize.world.height + 1)
    }

    func testInvalidEmptyRoutesReturnNil() {
        XCTAssertNil(MapSnapshotRegionPlanner.planMapRect(routes: [], imageSize: portraitSize))
        XCTAssertNil(MapSnapshotRegionPlanner.planMapRect(
            routes: [RouteMapLine(id: "empty", coordinates: [], style: .primary)],
            imageSize: portraitSize
        ))
    }

    func testZeroImageSizeReturnsNil() {
        let routes = [line(id: "a", coords: [(37.77, -122.42), (37.78, -122.41)])]
        XCTAssertNil(MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: .zero))
        XCTAssertNil(MapSnapshotRegionPlanner.planMapRect(
            routes: routes,
            imageSize: CGSize(width: CGFloat.infinity, height: 560)
        ))
        XCTAssertNil(MapSnapshotRegionPlanner.planMapRect(
            routes: routes,
            imageSize: CGSize(width: 1_120, height: CGFloat.nan)
        ))
    }

    func testDeterministicResult() {
        let routes = [line(id: "a", coords: [
            (37.77, -122.42),
            (37.78, -122.41),
            (37.79, -122.40)
        ])]
        let a = MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize)
        let b = MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize)
        XCTAssertEqual(a?.origin.x, b?.origin.x)
        XCTAssertEqual(a?.origin.y, b?.origin.y)
        XCTAssertEqual(a?.size.width, b?.size.width)
        XCTAssertEqual(a?.size.height, b?.size.height)
    }

    func testAntimeridianConservativeBehavior() {
        // Coordinates on both sides of the dateline — planner should still return a finite rect.
        let routes = [line(id: "anti", coords: [
            (1.0, 179.5),
            (1.1, -179.5)
        ])]
        let rect = MapSnapshotRegionPlanner.planMapRect(routes: routes, imageSize: portraitSize)
        XCTAssertNotNil(rect)
        if let rect {
            assertInsideWorld(rect)
            XCTAssertFalse(rect.isNull)
        }
    }

    // MARK: - Helpers

    private func line(id: String, coords: [(Double, Double)]) -> RouteMapLine {
        RouteMapLine(
            id: id,
            coordinates: coords.compactMap { RouteMapCoordinate(latitude: $0.0, longitude: $0.1) },
            style: .primary
        )
    }

    private func assertInsideWorld(_ rect: MKMapRect, file: StaticString = #filePath, line: UInt = #line) {
        let world = MKMapRect.world
        XCTAssertGreaterThanOrEqual(rect.origin.x, world.origin.x - 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.origin.y, world.origin.y - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, world.maxX + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, world.maxY + 1, file: file, line: line)
    }
}
