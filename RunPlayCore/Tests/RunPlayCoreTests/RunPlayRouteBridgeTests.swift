import Foundation
import XCTest
@testable import RunPlayCore

final class RunPlayRouteBridgeTests: XCTestCase {
    func testEmptyRouteHasSuccessfulOffsetBasisInspection() {
        let inspection = RunPlayRouteBridge.inspect([])

        XCTAssertEqual(inspection.status, .success)
        XCTAssertEqual(inspection.sampleCount, 0)
        XCTAssertEqual(inspection.altitudeValueCount, 0)
        XCTAssertEqual(inspection.speedValueCount, 0)
        XCTAssertEqual(inspection.paceValueCount, 0)
        XCTAssertEqual(inspection.heartRateValueCount, 0)
        XCTAssertEqual(inspection.cadenceValueCount, 0)
        XCTAssertEqual(inspection.horizontalAccuracyValueCount, 0)
        XCTAssertEqual(inspection.segmentTransitionCount, 0)
        XCTAssertNil(inspection.firstSourceIndex)
        XCTAssertNil(inspection.lastSourceIndex)
        XCTAssertEqual(inspection.fieldDigest, SwiftRouteInspectionOracle.digestOffset)
        assertParity(for: [])
    }

    func testCompletePointPreservesEveryRoutePointField() {
        let point = RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: 123.125),
            latitude: 1.25,
            longitude: -103.75,
            altitudeMeters: 42.5,
            distanceFromStartMeters: 321.75,
            elapsedSeconds: 67.875,
            speedMetersPerSecond: 4.125,
            paceSecondsPerKilometer: 242.25,
            heartRateBPM: 151.5,
            cadence: 176.25,
            horizontalAccuracy: 3.75,
            routeSegmentIndex: 4
        )

        let inspection = RunPlayRouteBridge.inspect([point])

        XCTAssertEqual(inspection.status, .success)
        XCTAssertEqual(inspection.sampleCount, 1)
        XCTAssertEqual(inspection.altitudeValueCount, 1)
        XCTAssertEqual(inspection.speedValueCount, 1)
        XCTAssertEqual(inspection.paceValueCount, 1)
        XCTAssertEqual(inspection.heartRateValueCount, 1)
        XCTAssertEqual(inspection.cadenceValueCount, 1)
        XCTAssertEqual(inspection.horizontalAccuracyValueCount, 1)
        XCTAssertEqual(inspection.firstSourceIndex, 0)
        XCTAssertEqual(inspection.lastSourceIndex, 0)
        assertParity(for: [point])
    }

    func testMissingOptionalsRemainAbsent() {
        let points = [
            point(index: 0, segment: 0),
            point(index: 1, segment: 0)
        ]

        let inspection = RunPlayRouteBridge.inspect(points)

        XCTAssertEqual(inspection.altitudeValueCount, 0)
        XCTAssertEqual(inspection.speedValueCount, 0)
        XCTAssertEqual(inspection.paceValueCount, 0)
        XCTAssertEqual(inspection.heartRateValueCount, 0)
        XCTAssertEqual(inspection.cadenceValueCount, 0)
        XCTAssertEqual(inspection.horizontalAccuracyValueCount, 0)
        assertParity(for: points)
    }

    func testMultipleSegmentsPreserveOrderAndCountOnlyTransitions() {
        let segmentIndexes = [0, 0, 3, 3, 3, -2]
        let points = segmentIndexes.enumerated().map { index, segment in
            point(index: index, segment: segment)
        }

        let inspection = RunPlayRouteBridge.inspect(points)

        XCTAssertEqual(inspection.status, .success)
        XCTAssertEqual(inspection.sampleCount, 6)
        XCTAssertEqual(inspection.segmentTransitionCount, 2)
        XCTAssertEqual(inspection.firstSourceIndex, 0)
        XCTAssertEqual(inspection.lastSourceIndex, 5)
        assertParity(for: points)
    }

    func testDuplicateDistanceAcrossSegmentBoundaryPreservesBothPoints() {
        var points = [
            point(index: 0, segment: 0),
            point(index: 1, segment: 0),
            point(index: 2, segment: 1),
            point(index: 3, segment: 1)
        ]
        points[1].distanceFromStartMeters = 250
        points[2].distanceFromStartMeters = 250

        let inspection = RunPlayRouteBridge.inspect(points)

        XCTAssertEqual(inspection.sampleCount, 4)
        XCTAssertEqual(inspection.segmentTransitionCount, 1)
        XCTAssertEqual(inspection.lastSourceIndex, 3)
        assertParity(for: points)
    }

    func testNonFiniteAndSignedZeroBitPatternsArePreserved() {
        let canonicalNaN = Double.nan
        let edgePoint = RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: 0.125),
            latitude: -0.0,
            longitude: .infinity,
            altitudeMeters: -.infinity,
            distanceFromStartMeters: canonicalNaN,
            elapsedSeconds: -.infinity,
            speedMetersPerSecond: .infinity,
            paceSecondsPerKilometer: -.infinity,
            heartRateBPM: canonicalNaN,
            cadence: -0.0,
            horizontalAccuracy: .infinity,
            routeSegmentIndex: -7
        )
        var positiveZeroPoint = edgePoint
        positiveZeroPoint.latitude = 0.0

        let negativeZeroInspection = RunPlayRouteBridge.inspect([edgePoint])
        let positiveZeroInspection = RunPlayRouteBridge.inspect([positiveZeroPoint])

        assertParity(for: [edgePoint])
        assertParity(for: [positiveZeroPoint])
        XCTAssertNotEqual(
            negativeZeroInspection.fieldDigest,
            positiveZeroInspection.fieldDigest,
            "Signed zero must not be normalized at the bridge"
        )
    }

    func testHundredThousandSampleRouteMatchesIndependentOracle() {
        let sampleCount = 100_000
        var points: [RoutePoint] = []
        points.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let scalar = Double(index)
            points.append(
                RoutePoint(
                    timestamp: Date(
                        timeIntervalSinceReferenceDate: 500_000 + scalar * 0.25
                    ),
                    latitude: 1.0 + scalar * 0.000_001,
                    longitude: 103.0 - scalar * 0.000_001,
                    altitudeMeters: index.isMultiple(of: 2) ? scalar * 0.01 : nil,
                    distanceFromStartMeters: scalar * 1.5,
                    elapsedSeconds: scalar * 0.25,
                    speedMetersPerSecond:
                        index.isMultiple(of: 3) ? 6.0 + scalar * 0.000_01 : nil,
                    paceSecondsPerKilometer:
                        index.isMultiple(of: 5) ? 240.0 + scalar * 0.000_1 : nil,
                    heartRateBPM:
                        index.isMultiple(of: 7) ? 120.0 + Double(index % 80) : nil,
                    cadence:
                        index.isMultiple(of: 11) ? 160.0 + Double(index % 30) : nil,
                    horizontalAccuracy:
                        index.isMultiple(of: 13) ? 2.0 + Double(index % 10) : nil,
                    routeSegmentIndex: index / 25_000
                )
            )
        }

        let inspection = RunPlayRouteBridge.inspect(points)

        XCTAssertEqual(inspection.status, .success)
        XCTAssertEqual(inspection.sampleCount, UInt64(sampleCount))
        XCTAssertEqual(inspection.firstSourceIndex, 0)
        XCTAssertEqual(inspection.lastSourceIndex, UInt64(sampleCount - 1))
        XCTAssertEqual(inspection.segmentTransitionCount, 3)
        assertParity(for: points)
    }

    func testInspectionResultContainsOnlyPureSwiftValues() {
        let inspection = RunPlayRouteBridge.inspect([point(index: 0, segment: 0)])

        XCTAssertTrue(type(of: inspection) == RunPlayRouteBatchInspection.self)
        XCTAssertTrue(type(of: inspection.status) == RunPlayRouteInteropStatus.self)
        XCTAssertTrue(type(of: inspection.sampleCount) == UInt64.self)
        XCTAssertTrue(type(of: inspection.firstSourceIndex) == UInt64?.self)
    }

    private func assertParity(
        for points: [RoutePoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = RunPlayRouteBridge.inspect(points)
        let expected = SwiftRouteInspectionOracle.inspect(points)

        XCTAssertEqual(actual.status, .success, file: file, line: line)
        XCTAssertEqual(actual.sampleCount, expected.sampleCount, file: file, line: line)
        XCTAssertEqual(
            actual.altitudeValueCount,
            expected.altitudeValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.speedValueCount,
            expected.speedValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.paceValueCount,
            expected.paceValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.heartRateValueCount,
            expected.heartRateValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.cadenceValueCount,
            expected.cadenceValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.horizontalAccuracyValueCount,
            expected.horizontalAccuracyValueCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.segmentTransitionCount,
            expected.segmentTransitionCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.firstSourceIndex,
            expected.firstSourceIndex,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.lastSourceIndex,
            expected.lastSourceIndex,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.fieldDigest, expected.fieldDigest, file: file, line: line)
    }

    private func point(index: Int, segment: Int) -> RoutePoint {
        let scalar = Double(index)
        return RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: 10_000 + scalar * 0.5),
            latitude: 1.3 + scalar * 0.001,
            longitude: -103.8 - scalar * 0.001,
            distanceFromStartMeters: scalar * 250,
            elapsedSeconds: scalar * 60,
            routeSegmentIndex: segment
        )
    }
}

private struct SwiftRouteInspection {
    let sampleCount: UInt64
    let altitudeValueCount: UInt64
    let speedValueCount: UInt64
    let paceValueCount: UInt64
    let heartRateValueCount: UInt64
    let cadenceValueCount: UInt64
    let horizontalAccuracyValueCount: UInt64
    let segmentTransitionCount: UInt64
    let firstSourceIndex: UInt64?
    let lastSourceIndex: UInt64?
    let fieldDigest: UInt64
}

/// Independent test-only parity oracle. It shares no digest implementation
/// with the C++ engine or the production Swift bridge.
private enum SwiftRouteInspectionOracle {
    static let digestOffset: UInt64 = 14_695_981_039_346_656_037
    private static let digestPrime: UInt64 = 1_099_511_628_211

    static func inspect(_ points: [RoutePoint]) -> SwiftRouteInspection {
        var altitudeValueCount: UInt64 = 0
        var speedValueCount: UInt64 = 0
        var paceValueCount: UInt64 = 0
        var heartRateValueCount: UInt64 = 0
        var cadenceValueCount: UInt64 = 0
        var horizontalAccuracyValueCount: UInt64 = 0
        var segmentTransitionCount: UInt64 = 0
        var digest = digestOffset

        func mix(_ word: UInt64) {
            digest = (digest ^ word) &* digestPrime
        }

        func mixOptional(_ value: Double?, valueCount: inout UInt64) {
            guard let value else {
                mix(0)
                return
            }
            mix(1)
            valueCount += 1
            mix(value.bitPattern)
        }

        for (sourceIndex, point) in points.enumerated() {
            guard let segmentIndex = Int64(exactly: point.routeSegmentIndex) else {
                preconditionFailure("RoutePoint.routeSegmentIndex must fit in Int64")
            }
            if sourceIndex > 0,
               point.routeSegmentIndex != points[sourceIndex - 1].routeSegmentIndex {
                segmentTransitionCount += 1
            }

            mix(UInt64(sourceIndex))
            mix(point.timestamp.timeIntervalSinceReferenceDate.bitPattern)
            mix(point.latitude.bitPattern)
            mix(point.longitude.bitPattern)
            mixOptional(point.altitudeMeters, valueCount: &altitudeValueCount)
            mix(point.distanceFromStartMeters.bitPattern)
            mix(point.elapsedSeconds.bitPattern)
            mixOptional(point.speedMetersPerSecond, valueCount: &speedValueCount)
            mixOptional(
                point.paceSecondsPerKilometer,
                valueCount: &paceValueCount
            )
            mixOptional(point.heartRateBPM, valueCount: &heartRateValueCount)
            mixOptional(point.cadence, valueCount: &cadenceValueCount)
            mixOptional(
                point.horizontalAccuracy,
                valueCount: &horizontalAccuracyValueCount
            )
            mix(UInt64(bitPattern: segmentIndex))
        }

        return SwiftRouteInspection(
            sampleCount: UInt64(points.count),
            altitudeValueCount: altitudeValueCount,
            speedValueCount: speedValueCount,
            paceValueCount: paceValueCount,
            heartRateValueCount: heartRateValueCount,
            cadenceValueCount: cadenceValueCount,
            horizontalAccuracyValueCount: horizontalAccuracyValueCount,
            segmentTransitionCount: segmentTransitionCount,
            firstSourceIndex: points.isEmpty ? nil : 0,
            lastSourceIndex: points.isEmpty ? nil : UInt64(points.count - 1),
            fieldDigest: digest
        )
    }
}
