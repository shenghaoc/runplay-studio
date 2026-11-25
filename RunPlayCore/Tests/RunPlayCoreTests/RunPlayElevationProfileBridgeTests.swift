import Foundation
import Testing
@testable import RunPlayCore

@Suite("ElevationProfile bridge")
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
}
