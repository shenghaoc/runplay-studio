import XCTest
import RunPlayCore

@testable import RunPlayStudio

final class RouteScenePointLookupTests: XCTestCase {

    func testPrefersDirectSourceIndexMatch() {
        let routePoints = makeRoutePoints(count: 5)
        let scenePoints = makeScenePoints(sourceIndices: [0, 2, 4, 6])

        let point = scenePoints.scenePoint(forRouteIndex: 4, in: routePoints)

        XCTAssertEqual(point?.sourceIndex, 4)
    }

    func testFallsBackToNearestDistanceWhenSourceIndexWasFiltered() {
        let routePoints = makeRoutePoints(count: 7)
        let scenePoints = makeScenePoints(sourceIndices: [0, 2, 4, 6])

        let point = scenePoints.scenePoint(forRouteIndex: 3, in: routePoints)

        // At 300m, 200m and 400m are equally close. The implementation keeps
        // the upper-bound result, matching the route's forward playback order.
        XCTAssertEqual(point?.sourceIndex, 4)
    }

    func testRejectsInvalidRouteIndex() {
        let point = makeScenePoints(sourceIndices: [0, 2]).scenePoint(
            forRouteIndex: 3,
            in: makeRoutePoints(count: 3)
        )

        XCTAssertNil(point)
    }

    private func makeRoutePoints(count: Int) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(
                timestamp: Date().addingTimeInterval(Double(index) * 5),
                latitude: 37.0 + Double(index) * 0.001,
                longitude: -122.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(index) * 100,
                elapsedSeconds: Double(index) * 5
            )
        }
    }

    private func makeScenePoints(sourceIndices: [Int]) -> [RouteScenePoint] {
        sourceIndices.map { index in
            RouteScenePoint(
                xMeters: Double(index) * 100,
                yMeters: 0,
                zMeters: 0,
                sourceIndex: index,
                distanceFromStartMeters: Double(index) * 100,
                elapsedSeconds: Double(index) * 5
            )
        }
    }
}
