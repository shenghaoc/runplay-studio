import XCTest
@testable import RunPlayCore

/// End-to-end parity for the public highlight values produced after native
/// candidate selection. The independent oracle reconstructs the pre-migration
/// Swift search and materialization path; UUIDs are the only excluded field.
final class SegmentDetectorParityTests: XCTestCase {

    func testEndToEndHighlightsMatchSwiftOracle() throws {
        let fixtures: [(String, [RoutePoint])] = [
            ("continuous-variable", Self.makeContinuousVariableRoute()),
            ("same-segment-plateau", Self.makeSameSegmentPlateauRoute()),
            ("multi-sample-pause", Self.makeMultiSamplePauseRoute()),
            ("separated-elevation-runs", Self.makeSeparatedElevationRunsRoute()),
        ]

        for (name, points) in fixtures {
            let workout = RunWorkout(routePoints: points)
            let context = WorkoutAnalysisContext(workout: workout)
            let expected = SwiftSegmentDetectorOracle.detectSegments(
                from: workout,
                context: context
            )
            let actual = try SegmentDetector.detectSegments(
                from: workout,
                context: context,
                policy: .runningDefault,
                isCancelled: { false }
            )

            assertSegmentsEqual(actual, expected, fixture: name)
        }
    }

    private func assertSegmentsEqual(
        _ actual: [SegmentHighlight],
        _ expected: [SegmentHighlight],
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(fixture): count", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            let (actualSegment, expectedSegment) = pair
            let prefix = "\(fixture) segment \(index)"
            XCTAssertEqual(actualSegment.type, expectedSegment.type, "\(prefix): type", file: file, line: line)
            XCTAssertEqual(actualSegment.title, expectedSegment.title, "\(prefix): title", file: file, line: line)
            XCTAssertEqual(actualSegment.subtitle, expectedSegment.subtitle, "\(prefix): subtitle", file: file, line: line)
            assertClose(actualSegment.startDistanceMeters, expectedSegment.startDistanceMeters, "\(prefix): start distance", file, line)
            assertClose(actualSegment.endDistanceMeters, expectedSegment.endDistanceMeters, "\(prefix): end distance", file, line)
            assertClose(actualSegment.startElapsedSeconds, expectedSegment.startElapsedSeconds, "\(prefix): start elapsed", file, line)
            assertClose(actualSegment.endElapsedSeconds, expectedSegment.endElapsedSeconds, "\(prefix): end elapsed", file, line)
            assertClose(actualSegment.durationSeconds, expectedSegment.durationSeconds, "\(prefix): duration", file, line)
            assertClose(actualSegment.distanceMeters, expectedSegment.distanceMeters, "\(prefix): distance", file, line)
            assertOptionalClose(actualSegment.paceSecondsPerKilometer, expectedSegment.paceSecondsPerKilometer, "\(prefix): pace", file, line)
            assertOptionalClose(actualSegment.elevationDeltaMeters, expectedSegment.elevationDeltaMeters, "\(prefix): elevation", file, line)
            assertOptionalClose(actualSegment.averageHeartRate, expectedSegment.averageHeartRate, "\(prefix): heart rate", file, line)
            XCTAssertEqual(actualSegment.sourcePointRange, expectedSegment.sourcePointRange, "\(prefix): source range", file: file, line: line)
            XCTAssertEqual(actualSegment.displayPriority, expectedSegment.displayPriority, "\(prefix): priority", file: file, line: line)
        }
    }

    private func assertOptionalClose(
        _ actual: Double?,
        _ expected: Double?,
        _ message: String,
        _ file: StaticString,
        _ line: UInt
    ) {
        switch (actual, expected) {
        case (.none, .none):
            break
        case (.some(let actual), .some(let expected)):
            assertClose(actual, expected, message, file, line)
        default:
            XCTFail("\(message): \(String(describing: actual)) != \(String(describing: expected))", file: file, line: line)
        }
    }

    private func assertClose(
        _ actual: Double,
        _ expected: Double,
        _ message: String,
        _ file: StaticString,
        _ line: UInt
    ) {
        let tolerance = max(1e-9, abs(expected) * 1e-12)
        XCTAssertEqual(actual, expected, accuracy: tolerance, message, file: file, line: line)
    }

    private static func makeContinuousVariableRoute() -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var elapsed = 0.0
        return (0...50).map { index in
            if index > 0 {
                elapsed += 12 + Double(index % 5)
            }
            let distance = Double(index) * 50
            return RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 103,
                altitudeMeters: 30 + Double((index * 7) % 18),
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                heartRateBPM: 135 + Double(index % 20),
                routeSegmentIndex: 0
            )
        }
    }

    private static func makeSameSegmentPlateauRoute() -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        let values: [(distance: Double, elapsed: Double)] = [
            (0, 0),
            (400, 300),
            (400, 400),
            (800, 500),
            (1_200, 610),
            (1_600, 730),
            (2_000, 860),
        ]
        return values.enumerated().map { index, value in
            RoutePoint(
                timestamp: start.addingTimeInterval(value.elapsed),
                latitude: 1 + value.distance / 100_000,
                longitude: 103,
                altitudeMeters: 40 + Double(index * 2),
                distanceFromStartMeters: value.distance,
                elapsedSeconds: value.elapsed,
                heartRateBPM: 140 + Double(index),
                routeSegmentIndex: 0
            )
        }
    }

    private static func makeMultiSamplePauseRoute() -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 30_000)
        let values: [(distance: Double, elapsed: Double, segment: Int)] = [
            (0, 0, 0),
            (500, 150, 0),
            (500, 160, 0),
            (500, 1_160, 1),
            (500, 1_170, 1),
            (1_000, 1_320, 1),
            (1_500, 1_490, 1),
            (2_000, 1_680, 1),
        ]
        return values.enumerated().map { index, value in
            RoutePoint(
                timestamp: start.addingTimeInterval(value.elapsed),
                latitude: 1 + value.distance / 100_000,
                longitude: 103,
                altitudeMeters: 50 + Double(index),
                distanceFromStartMeters: value.distance,
                elapsedSeconds: value.elapsed,
                heartRateBPM: 145 + Double(index),
                routeSegmentIndex: value.segment
            )
        }
    }

    private static func makeSeparatedElevationRunsRoute() -> [RoutePoint] {
        let start = Date(timeIntervalSinceReferenceDate: 40_000)
        return (0...30).map { index in
            let distance = Double(index) * 100
            let altitude: Double? = (10...14).contains(index)
                ? nil
                : 80 + Double((index * 3) % 25)
            return RoutePoint(
                timestamp: start.addingTimeInterval(distance * 0.32),
                latitude: 1 + distance / 100_000,
                longitude: 103,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: distance * 0.32,
                heartRateBPM: 130 + Double(index % 15),
                routeSegmentIndex: 0
            )
        }
    }
}
