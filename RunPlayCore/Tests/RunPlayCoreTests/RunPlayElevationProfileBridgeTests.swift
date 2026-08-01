import Foundation
import Testing
@testable import RunPlayCore

@Suite("ElevationProfile C++ bridge parity")
struct RunPlayElevationProfileBridgeTests {

    @Test("empty route")
    func emptyRoute() throws {
        let result = try RunPlayElevationProfileBridge.build(
            routePoints: [],
            policy: .runningDefault,
            isCancelled: { false }
        )
        #expect(result.samples.isEmpty)
        #expect(result.rejectedAltitudeCount == 0)
        #expect(!result.hasMeaningfulElevation)
    }

    @Test("bridge matches oracle on ordinary climb")
    func ordinaryClimb() throws {
        let points = makePoints(altitudes: [100, 104, 108, 112, 116], step: 10)
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("bridge matches oracle on interior spike")
    func interiorSpike() throws {
        let points = makePoints(altitudes: [100, 101, 200, 102, 103], step: 10)
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("bridge matches oracle on short excursion")
    func shortExcursion() throws {
        let points = makePoints(
            altitudes: [100, 101, 220, 225, 102, 103],
            step: 10
        )
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("bridge matches oracle with missing altitude")
    func missingAltitude() throws {
        var points = makePoints(altitudes: [100, 101, 102, 110, 111, 112], step: 10)
        points[2] = RoutePoint(
            id: points[2].id,
            timestamp: points[2].timestamp,
            latitude: points[2].latitude,
            longitude: points[2].longitude,
            altitudeMeters: nil,
            distanceFromStartMeters: points[2].distanceFromStartMeters,
            elapsedSeconds: points[2].elapsedSeconds,
            routeSegmentIndex: points[2].routeSegmentIndex
        )
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("bridge matches oracle across route segments")
    func routeSegments() throws {
        var points = makePoints(altitudes: [100, 101, 102, 200, 201, 202], step: 10)
        for index in 3..<6 {
            points[index] = RoutePoint(
                id: points[index].id,
                timestamp: points[index].timestamp,
                latitude: points[index].latitude,
                longitude: points[index].longitude,
                altitudeMeters: points[index].altitudeMeters,
                distanceFromStartMeters: points[index].distanceFromStartMeters,
                elapsedSeconds: points[index].elapsedSeconds,
                routeSegmentIndex: 1
            )
        }
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("malformed distances preserve oracle behavior")
    func malformedDistances() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let distances: [Double] = [-10, 5, 3, 3, 1e12]
        let altitudes: [Double] = [100, 105, 110, 115, 120]
        let points: [RoutePoint] = zip(distances, altitudes).enumerated().map { index, pair in
            RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.0,
                longitude: -122.0,
                altitudeMeters: pair.1,
                distanceFromStartMeters: pair.0,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("non-finite altitudes rejected like oracle")
    func nonFiniteAltitudes() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let altitudes: [Double?] = [
            100,
            .nan,
            .infinity,
            -.infinity,
            110,
            111,
        ]
        let points: [RoutePoint] = altitudes.enumerated().map { index, altitude in
            RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.0,
                longitude: -122.0,
                altitudeMeters: altitude,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
        try assertBridgeMatchesOracle(points: points)
    }

    @Test("1,000 deterministic generated fixtures")
    func generatedFixtures() throws {
        var failures = 0
        for seed in 0..<1_000 {
            let points = generatedFixture(seed: seed)
            let policy = generatedPolicy(seed: seed)
            do {
                try assertBridgeMatchesOracle(points: points, policy: policy)
            } catch {
                failures += 1
                if failures <= 3 {
                    Issue.record("fixture \(seed) failed: \(error)")
                }
            }
        }
        #expect(failures == 0)
    }

    @Test("cancellation before native call")
    func cancellationBeforeNativeCall() {
        let points = makePoints(
            altitudes: Array(repeating: 100.0, count: 50),
            step: 10
        )
        var policy = RouteQualityPolicy.runningDefault
        policy.cancellationCheckStride = 10
        #expect(throws: CancellationError.self) {
            _ = try RunPlayElevationProfileBridge.build(
                routePoints: points,
                policy: policy,
                isCancelled: { true }
            )
        }
    }

    // MARK: - Helpers

    private func makePoints(altitudes: [Double], step: Double) -> [RoutePoint] {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        return altitudes.enumerated().map { index, altitude in
            RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.7 + Double(index) * 0.0001,
                longitude: -122.4,
                altitudeMeters: altitude,
                distanceFromStartMeters: Double(index) * step,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
    }

    private func generatedFixture(seed: Int) -> [RoutePoint] {
        var state = UInt64(seed &+ 1) &* 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        func unit() -> Double {
            Double(next() % 10_000) / 10_000.0
        }

        let count = 3 + Int(next() % 40)
        let base = Date(timeIntervalSinceReferenceDate: Double(seed))
        var distance = 0.0
        var altitude = 80.0 + unit() * 40
        var segment = 0
        var points: [RoutePoint] = []
        points.reserveCapacity(count)

        for index in 0..<count {
            let step = 1.0 + unit() * 25
            if unit() < 0.08 {
                // Duplicate distance
            } else if unit() < 0.05 {
                distance = max(0, distance - unit() * 5) // mild decrease
            } else {
                distance += step
            }

            if unit() < 0.07 {
                segment += 1
            }

            let altitudeValue: Double?
            let roll = unit()
            if roll < 0.08 {
                altitudeValue = nil
            } else if roll < 0.10 {
                altitudeValue = .nan
            } else if roll < 0.11 {
                altitudeValue = .infinity
            } else if roll < 0.18 {
                // Spike
                altitudeValue = altitude + (unit() < 0.5 ? 80 : -80)
            } else if roll < 0.24 {
                // Short excursion plateau start
                altitudeValue = altitude + 120
            } else {
                altitude += (unit() - 0.5) * 6
                altitudeValue = altitude
            }

            points.append(RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.0 + Double(index) * 0.00001,
                longitude: -122.0,
                altitudeMeters: altitudeValue,
                distanceFromStartMeters: distance,
                elapsedSeconds: Double(index),
                routeSegmentIndex: segment
            ))
        }
        return points
    }

    private func generatedPolicy(seed: Int) -> RouteQualityPolicy {
        var policy = RouteQualityPolicy.runningDefault
        switch seed % 5 {
        case 0:
            policy.elevationSmoothingRadiusMeters = 0
        case 1:
            policy.elevationSmoothingRadiusMeters = 5
        case 2:
            policy.elevationSmoothingRadiusMeters = 15
        case 3:
            policy.elevationGainLossDeadbandMeters = 0
        default:
            policy.minimumReliableAltitudeSampleCount = 3
        }
        return policy
    }

    private func assertBridgeMatchesOracle(
        points: [RoutePoint],
        policy: RouteQualityPolicy = .runningDefault
    ) throws {
        let oracle = SwiftElevationProfileOracle.build(
            routePoints: points,
            policy: policy
        )
        let bridge = try RunPlayElevationProfileBridge.build(
            routePoints: points,
            policy: policy,
            isCancelled: { false }
        )

        #expect(bridge.samples.count == oracle.samples.count)
        #expect(bridge.rejectedAltitudeCount == oracle.rejectedAltitudeCount)
        #expect(bridge.hasMeaningfulElevation == oracle.hasMeaningfulElevation)
        #expect(optionalNearEqual(bridge.totalAscentMeters, oracle.totalAscentMeters))
        #expect(optionalNearEqual(bridge.totalDescentMeters, oracle.totalDescentMeters))

        for index in bridge.samples.indices {
            let b = bridge.samples[index]
            let o = oracle.samples[index]
            #expect(optionalNearEqual(b.correctedAltitudeMeters, o.correctedAltitudeMeters))
            #expect(b.sourceAltitudeWasRejected == o.sourceAltitudeWasRejected)
            #expect(nearEqual(b.cumulativeAscentMeters, o.cumulativeAscentMeters))
            #expect(nearEqual(b.cumulativeDescentMeters, o.cumulativeDescentMeters))
            #expect(nearEqual(b.cumulativeSignedChangeMeters, o.cumulativeSignedChangeMeters))
            #expect(nearEqual(b.reliableIntervalCount, o.reliableIntervalCount))
            #expect(b.runIdentifier == o.runIdentifier)
            #expect(b.reliableRunIdentifier == o.reliableRunIdentifier)
        }
    }

    private func nearEqual(_ a: Double, _ b: Double) -> Bool {
        if a == b { return true }
        let tolerance = max(1e-9, abs(b) * 1e-12)
        return abs(a - b) <= tolerance
    }

    private func optionalNearEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return nearEqual(a, b)
        default:
            return false
        }
    }
}
