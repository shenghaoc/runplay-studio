import CoreGraphics
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform

final class WorkoutVideoMapPreparerTests: XCTestCase {
    func testSyntheticPreparerMapsOnePixelPerValidPoint() async throws {
        let workout = sampleWorkout()
        let preparer = SyntheticWorkoutVideoMapPreparer()
        let request = WorkoutVideoMapPreparationRequest(
            size: CGSize(width: 320, height: 180),
            appearance: .light,
            routes: RouteMapContent.segmentedRoutes(
                idPrefix: "t",
                points: workout.routePoints,
                style: .primary
            ),
            markers: RouteMapContent.endpointMarkers(points: workout.routePoints, idPrefix: "t"),
            routePoints: workout.routePoints
        )
        let prepared = try await preparer.prepare(request: request)
        XCTAssertEqual(prepared.routePointPixels.count, workout.routePoints.count)
        XCTAssertEqual(prepared.pixelWidth, 320)
        XCTAssertEqual(prepared.pixelHeight, 180)
        let valid = prepared.routePointPixels.compactMap { $0 }
        XCTAssertEqual(valid.count, workout.routePoints.count)
        for (index, pixel) in valid.enumerated() {
            XCTAssertEqual(pixel.routePointIndex, index)
            XCTAssertEqual(pixel.routePointID, workout.routePoints[index].id)
            XCTAssertEqual(pixel.routeSegmentIndex, workout.routePoints[index].routeSegmentIndex)
        }
    }

    func testMarkerPixelDoesNotCrossSegments() {
        let p0 = WorkoutVideoRoutePixel(
            routePointID: UUID(),
            routePointIndex: 0,
            routeSegmentIndex: 0,
            point: CGPoint(x: 10, y: 10)
        )
        let p1 = WorkoutVideoRoutePixel(
            routePointID: UUID(),
            routePointIndex: 1,
            routeSegmentIndex: 0,
            point: CGPoint(x: 20, y: 10)
        )
        // Index 2 invalid in segment 0
        let p3 = WorkoutVideoRoutePixel(
            routePointID: UUID(),
            routePointIndex: 3,
            routeSegmentIndex: 1,
            point: CGPoint(x: 90, y: 10)
        )
        let pixels: [WorkoutVideoRoutePixel?] = [p0, p1, nil, p3]

        // Looking for segment 0 at invalid index 2 → should find p1 backward.
        let found = WorkoutVideoMapPreparation.markerPixel(
            routePointIndex: 2,
            routeSegmentIndex: 0,
            pixels: pixels
        )
        XCTAssertEqual(found, CGPoint(x: 20, y: 10))

        // Looking for segment 1 at index 2 (nil, wrong segment neighbors) → p3 forward.
        let foundSeg1 = WorkoutVideoMapPreparation.markerPixel(
            routePointIndex: 2,
            routeSegmentIndex: 1,
            pixels: pixels
        )
        XCTAssertEqual(foundSeg1, CGPoint(x: 90, y: 10))

        // Empty segment yields nil.
        let none = WorkoutVideoMapPreparation.markerPixel(
            routePointIndex: 0,
            routeSegmentIndex: 9,
            pixels: pixels
        )
        XCTAssertNil(none)
    }

    func testCancellationDuringSyntheticPrepare() async {
        let preparer = SyntheticWorkoutVideoMapPreparer()
        let workout = sampleWorkout()
        let request = WorkoutVideoMapPreparationRequest(
            size: CGSize(width: 64, height: 36),
            appearance: .dark,
            routes: [],
            markers: [],
            routePoints: workout.routePoints
        )
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            do {
                _ = try await preparer.prepare(request: request)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }

    private func sampleWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<20 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i)),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 8,
                elapsedSeconds: Double(i) * 2
            ))
        }
        return RunWorkout(routePoints: points)
    }
}
