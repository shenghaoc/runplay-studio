import Foundation
import Testing
@testable import RunPlayCore

@Suite("ElevationProfile production build")
struct ElevationProfileParityTests {

    @Test("production profile maps every route point and snapshot entry")
    func productionProfileMapsRoutePoints() throws {
        let points = ordinaryClimb()
        let policy = RouteQualityPolicy.runningDefault
        let built = try ElevationProfile.build(
            routePoints: points,
            policy: policy,
            isCancelled: { false }
        )
        let profile = built.profile

        try #require(profile.samples.count == points.count)

        for index in profile.samples.indices {
            let sample = profile.samples[index]
            #expect(sample.routePointID == points[index].id)
            #expect(sample.distanceFromStartMeters == points[index].distanceFromStartMeters)
            #expect(sample.routeSegmentIndex == points[index].routeSegmentIndex)
        }

        // Snapshot arrays used by SegmentDetector.
        let snapshot = profile.segmentDetectionSnapshot()
        #expect(snapshot.cumulativeAscentMeters.count == points.count)
        #expect(snapshot.reliableRunIdentifiers.count == points.count)

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
}
