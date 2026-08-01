import Foundation
@testable import RunPlayCore

/// Deterministic, production-shaped routes shared by candidate and complete
/// highlight parity tests. The matrix deliberately covers short and long
/// routes, variable pace, same-segment stationary plateaus, recording pauses,
/// missing-altitude gaps, multiple reliable elevation runs, and optional HR.
enum SegmentDetectorParityFixtures {
    static let generatedFixtureCount = 1_000

    static func generatedFixture(index: Int) -> [RoutePoint] {
        precondition(index >= 0 && index < generatedFixtureCount)

        let start = Date(timeIntervalSinceReferenceDate: 100_000 + Double(index))
        let pointCount = 24 + (index * 37) % 72
        let baseStep = [20.0, 25.0, 40.0, 50.0, 75.0, 100.0][index % 6]
        let stationaryIndex = index.isMultiple(of: 7) ? pointCount / 3 : -1
        let pauseIndex = index.isMultiple(of: 5) ? (pointCount * 2) / 3 : -1
        let missingAltitudeStart = index.isMultiple(of: 4) ? pointCount / 2 : -1
        let missingAltitudeCount = 3 + index % 4

        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        var distance = 0.0
        var elapsed = 0.0
        var routeSegment = 0

        for pointIndex in 0..<pointCount {
            if pointIndex > 0 {
                if pointIndex == pauseIndex {
                    routeSegment += 1
                    elapsed += 240 + Double(index % 180)
                } else if pointIndex == stationaryIndex {
                    elapsed += 15 + Double(index % 45)
                } else {
                    let stepJitter = Double((index * 13 + pointIndex * 17) % 11) - 5
                    let distanceStep = max(5, baseStep + stepJitter)
                    let secondsPerMeter = 0.22
                        + Double((index + pointIndex * 3) % 31) / 100
                    distance += distanceStep
                    elapsed += distanceStep * secondsPerMeter
                }
            }

            let isMissingAltitude = missingAltitudeStart >= 0
                && pointIndex >= missingAltitudeStart
                && pointIndex < missingAltitudeStart + missingAltitudeCount
            let altitude: Double? = isMissingAltitude
                ? nil
                : 45
                    + Double((pointIndex * 11 + index * 7) % 29) * 1.5
                    + Double(routeSegment * 4)
            let heartRate: Double? = (index + pointIndex).isMultiple(of: 9)
                ? nil
                : 118 + Double((index * 5 + pointIndex * 3) % 58)

            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 103 + Double(routeSegment) / 100_000,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                heartRateBPM: heartRate,
                routeSegmentIndex: routeSegment
            ))
        }

        return points
    }
}
