import Foundation
import Testing
@testable import RunPlayCore

@Suite("ElevationProfile production parity")
struct ElevationProfileParityTests {

    @Test("production profile matches oracle samples and totals")
    func productionMatchesOracle() throws {
        let points = ordinaryClimb()
        let policy = RouteQualityPolicy.runningDefault
        let oracle = SwiftElevationProfileOracle.build(routePoints: points, policy: policy)
        let built = try ElevationProfile.build(
            routePoints: points,
            policy: policy,
            isCancelled: { false }
        )
        let profile = built.profile

        #expect(built.rejectedAltitudeCount == oracle.rejectedAltitudeCount)
        #expect(profile.hasMeaningfulElevation == oracle.hasMeaningfulElevation)
        #expect(optionalNearEqual(profile.totalAscentMeters, oracle.totalAscentMeters))
        #expect(optionalNearEqual(profile.totalDescentMeters, oracle.totalDescentMeters))
        #expect(profile.samples.count == oracle.samples.count)

        for index in profile.samples.indices {
            let sample = profile.samples[index]
            let expected = oracle.samples[index]
            #expect(sample.routePointID == points[index].id)
            #expect(sample.distanceFromStartMeters == points[index].distanceFromStartMeters)
            #expect(sample.routeSegmentIndex == points[index].routeSegmentIndex)
            #expect(optionalNearEqual(sample.correctedAltitudeMeters, expected.correctedAltitudeMeters))
            #expect(sample.sourceAltitudeWasRejected == expected.sourceAltitudeWasRejected)
            #expect(nearEqual(sample.cumulativeAscentMeters, expected.cumulativeAscentMeters))
            #expect(nearEqual(sample.cumulativeDescentMeters, expected.cumulativeDescentMeters))
        }

        // Snapshot arrays used by SegmentDetector.
        let snapshot = profile.segmentDetectionSnapshot()
        #expect(snapshot.cumulativeAscentMeters.count == points.count)
        #expect(snapshot.reliableRunIdentifiers.count == points.count)
        for index in points.indices {
            #expect(nearEqual(
                snapshot.cumulativeAscentMeters[index],
                oracle.samples[index].cumulativeAscentMeters
            ))
            #expect(nearEqual(
                snapshot.cumulativeDescentMeters[index],
                oracle.samples[index].cumulativeDescentMeters
            ))
            #expect(nearEqual(
                snapshot.reliableIntervalCounts[index],
                oracle.samples[index].reliableIntervalCount
            ))
            #expect(
                snapshot.reliableRunIdentifiers[index]
                    == oracle.samples[index].reliableRunIdentifier
            )
        }

        // Public distance queries remain usable.
        if let first = points.first, let last = points.last {
            let mid = (first.distanceFromStartMeters + last.distanceFromStartMeters) / 2
            _ = profile.correctedAltitude(atDistance: mid)
            _ = profile.change(
                from: first.distanceFromStartMeters,
                to: last.distanceFromStartMeters
            )
            _ = profile.hasContinuousReliableElevation(
                from: first.distanceFromStartMeters,
                to: last.distanceFromStartMeters
            )
        }
    }

    @Test("spike and excursion fixtures match oracle")
    func spikeFixtures() throws {
        let fixtures: [[Double]] = [
            [100, 101, 200, 102, 103],
            [100, 101, 220, 225, 102, 103],
            [100, 120, 140, 160, 140, 120, 105],
        ]
        for altitudes in fixtures {
            let points = makePoints(altitudes: altitudes, step: 10)
            let oracle = SwiftElevationProfileOracle.build(routePoints: points)
            let built = try ElevationProfile.build(
                routePoints: points,
                policy: .runningDefault,
                isCancelled: { false }
            )
            #expect(built.rejectedAltitudeCount == oracle.rejectedAltitudeCount)
            #expect(built.profile.samples.count == oracle.samples.count)
            for index in oracle.samples.indices {
                #expect(optionalNearEqual(
                    built.profile.samples[index].correctedAltitudeMeters,
                    oracle.samples[index].correctedAltitudeMeters
                ))
                #expect(
                    built.profile.samples[index].sourceAltitudeWasRejected
                        == oracle.samples[index].sourceAltitudeWasRejected
                )
            }
        }
    }

    @Test("public initializer builds the production profile")
    func publicInitializerBuildsProfile() {
        let points = ordinaryClimb()
        let profile = ElevationProfile(routePoints: points)
        #expect(profile.samples.count == points.count)
        #expect(profile.hasMeaningfulElevation)
    }

    private func ordinaryClimb() -> [RoutePoint] {
        makePoints(altitudes: [100, 104, 108, 112, 116, 120], step: 10)
    }

    private func makePoints(altitudes: [Double], step: Double) -> [RoutePoint] {
        let base = Date(timeIntervalSinceReferenceDate: 2_000)
        return altitudes.enumerated().map { index, altitude in
            RoutePoint(
                timestamp: base.addingTimeInterval(Double(index)),
                latitude: 37.5 + Double(index) * 0.0001,
                longitude: -122.3,
                altitudeMeters: altitude,
                distanceFromStartMeters: Double(index) * step,
                elapsedSeconds: Double(index),
                routeSegmentIndex: 0
            )
        }
    }

    private func nearEqual(_ a: Double, _ b: Double) -> Bool {
        if a == b { return true }
        let tolerance = max(1e-9, abs(b) * 1e-12)
        return abs(a - b) <= tolerance
    }

    private func optionalNearEqual(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return nearEqual(a, b)
        default: return false
        }
    }
}
