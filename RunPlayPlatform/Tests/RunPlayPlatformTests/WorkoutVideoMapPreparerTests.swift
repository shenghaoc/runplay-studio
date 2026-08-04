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

    func testFirstAndLastNonNilPixelWithLeadingTrailingNils() {
        let pA = WorkoutVideoRoutePixel(
            routePointID: UUID(),
            routePointIndex: 1,
            routeSegmentIndex: 0,
            point: CGPoint(x: 11, y: 12)
        )
        let pB = WorkoutVideoRoutePixel(
            routePointID: UUID(),
            routePointIndex: 3,
            routeSegmentIndex: 0,
            point: CGPoint(x: 33, y: 34)
        )
        let sparse: [WorkoutVideoRoutePixel?] = [nil, pA, nil, pB, nil]
        XCTAssertEqual(WorkoutVideoMapPreparation.firstNonNilPixel(in: sparse), pA)
        XCTAssertEqual(WorkoutVideoMapPreparation.lastNonNilPixel(in: sparse), pB)

        let allNil: [WorkoutVideoRoutePixel?] = [nil, nil, nil]
        XCTAssertNil(WorkoutVideoMapPreparation.firstNonNilPixel(in: allNil))
        XCTAssertNil(WorkoutVideoMapPreparation.lastNonNilPixel(in: allNil))
        XCTAssertNil(WorkoutVideoMapPreparation.firstNonNilPixel(in: []))
        XCTAssertNil(WorkoutVideoMapPreparation.lastNonNilPixel(in: []))
    }

    func testSyntheticPreparerLeavesNilForInvalidCoordinatesAndPreservesIndices() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: 37.77,
                longitude: -122.42,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(1),
                latitude: .nan,
                longitude: -122.42,
                distanceFromStartMeters: 8,
                elapsedSeconds: 2
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(2),
                latitude: 37.771,
                longitude: -122.42,
                distanceFromStartMeters: 16,
                elapsedSeconds: 4
            )
        ]
        let preparer = SyntheticWorkoutVideoMapPreparer()
        let width = 320
        let height = 180
        let request = WorkoutVideoMapPreparationRequest(
            size: CGSize(width: width, height: height),
            appearance: .light,
            routes: [],
            markers: [],
            routePoints: points
        )
        let prepared = try await preparer.prepare(request: request)

        XCTAssertEqual(prepared.routePointPixels.count, 3)
        XCTAssertNil(prepared.routePointPixels[1])

        let first = try XCTUnwrap(prepared.routePointPixels[0])
        let last = try XCTUnwrap(prepared.routePointPixels[2])
        XCTAssertEqual(first.routePointIndex, 0)
        XCTAssertEqual(last.routePointIndex, 2)
        XCTAssertEqual(first.routePointID, points[0].id)
        XCTAssertEqual(last.routePointID, points[2].id)

        // Two valid points: order 0 at left pad, order 1 at right pad.
        XCTAssertEqual(first.point.x, 40, accuracy: 0.001)
        XCTAssertEqual(last.point.x, Double(width - 40), accuracy: 0.001)
        XCTAssertEqual(first.point.y, Double(height) * 0.5, accuracy: 0.001)
        XCTAssertEqual(last.point.y, Double(height) * 0.5, accuracy: 0.001)

        XCTAssertEqual(WorkoutVideoMapPreparation.firstNonNilPixel(in: prepared.routePointPixels), first)
        XCTAssertEqual(WorkoutVideoMapPreparation.lastNonNilPixel(in: prepared.routePointPixels), last)
    }

    func testSyntheticPreparerSingleValidPointCentersOnCanvas() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: .nan,
                longitude: -122.42,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(1),
                latitude: 37.77,
                longitude: -122.42,
                distanceFromStartMeters: 8,
                elapsedSeconds: 2
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(2),
                latitude: .nan,
                longitude: -122.42,
                distanceFromStartMeters: 16,
                elapsedSeconds: 4
            )
        ]
        let preparer = SyntheticWorkoutVideoMapPreparer()
        let width = 200
        let height = 100
        let request = WorkoutVideoMapPreparationRequest(
            size: CGSize(width: width, height: height),
            appearance: .dark,
            routes: [],
            markers: [],
            routePoints: points
        )
        let prepared = try await preparer.prepare(request: request)

        XCTAssertNil(prepared.routePointPixels[0])
        XCTAssertNil(prepared.routePointPixels[2])
        let only = try XCTUnwrap(prepared.routePointPixels[1])
        XCTAssertEqual(only.routePointIndex, 1)
        // Single valid point uses t = 0.5 → centered between side pads.
        let expectedX = 40 + 0.5 * Double(width - 80)
        XCTAssertEqual(only.point.x, expectedX, accuracy: 0.001)
        XCTAssertEqual(
            WorkoutVideoMapPreparation.firstNonNilPixel(in: prepared.routePointPixels),
            only
        )
        XCTAssertEqual(
            WorkoutVideoMapPreparation.lastNonNilPixel(in: prepared.routePointPixels),
            only
        )
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
