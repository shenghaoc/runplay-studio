import Foundation
@testable import RunPlayCore

/// Minimal Studio-side synthetic route builders for the Routes workspace
/// tests. The full fixture set lives in RunPlayCoreTests; this copy keeps
/// the Studio test target self-contained.
enum RouteGroupsWorkspaceFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let baseLatitude = 37.7749
    static let baseLongitude = -122.4194

    static var metersPerDegreeLongitude: Double {
        111_000 * cos(baseLatitude * .pi / 180)
    }

    static func squareLoop(sideMeters: Double, date: Date) -> [RoutePoint] {
        let perimeter = sideMeters * 4
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= perimeter {
            let position = travelled.truncatingRemainder(dividingBy: perimeter)
            let east: Double
            let north: Double
            switch position {
            case ..<sideMeters:
                east = position
                north = 0
            case ..<(2 * sideMeters):
                east = sideMeters
                north = position - sideMeters
            case ..<(3 * sideMeters):
                east = sideMeters - (position - 2 * sideMeters)
                north = sideMeters
            default:
                east = 0
                north = sideMeters - (position - 3 * sideMeters)
            }
            points.append(RoutePoint(
                timestamp: date.addingTimeInterval(travelled / 3),
                latitude: baseLatitude + north / 111_000,
                longitude: baseLongitude + east / metersPerDegreeLongitude,
                distanceFromStartMeters: travelled,
                elapsedSeconds: travelled / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if travelled >= perimeter { break }
            travelled = min(perimeter, travelled + 20)
        }
        return points
    }

    static func reversed(_ points: [RoutePoint], date: Date) -> [RoutePoint] {
        let total = points.last?.distanceFromStartMeters ?? 0
        let totalElapsed = points.last?.elapsedSeconds ?? 0
        return points.reversed().enumerated().map { index, point in
            RoutePoint(
                timestamp: date.addingTimeInterval(Double(index) / 3),
                latitude: point.latitude,
                longitude: point.longitude,
                distanceFromStartMeters: total - point.distanceFromStartMeters,
                elapsedSeconds: totalElapsed - point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: 0
            )
        }
    }

    static func straightLine(distanceMeters: Double, date: Date) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= distanceMeters {
            points.append(RoutePoint(
                timestamp: date.addingTimeInterval(travelled / 3),
                latitude: baseLatitude + travelled / 111_000,
                longitude: baseLongitude,
                distanceFromStartMeters: travelled,
                elapsedSeconds: travelled / 3,
                paceSecondsPerKilometer: 300,
                routeSegmentIndex: 0
            ))
            if travelled >= distanceMeters { break }
            travelled = min(distanceMeters, travelled + 20)
        }
        return points
    }

    static func workout(points: [RoutePoint], date: Date) -> RunWorkout {
        let distance = points.last?.distanceFromStartMeters ?? 0
        let elapsed = points.last?.elapsedSeconds ?? (distance / 3)
        return RunWorkout(
            metadata: WorkoutMetadata(
                name: nil,
                activityType: "Running",
                startDate: date,
                endDate: date.addingTimeInterval(max(0, elapsed))
            ),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: distance,
                totalElapsedSeconds: max(0, elapsed),
                averagePaceSecondsPerKilometer: 300
            )
        )
    }

    static func loopRepeat(sideMeters: Double, index: Int) -> RunWorkout {
        let date = epoch.addingTimeInterval(Double(index) * 86_400)
        return workout(points: squareLoop(sideMeters: sideMeters, date: date), date: date)
    }

    // MARK: - Derived-name groups

    static var metersPerDegreeLatitude: Double { 111_000 }

    /// A persisted-facts group for derived-name tests, mirroring
    /// `RouteGroupingFixtures.namingFacts`: `bearingDegrees` places the
    /// bounding-box centre relative to the start point, which is what the
    /// compass token is derived from.
    static func namingGroup(
        bearingDegrees: Double,
        totalDistanceMeters: Double,
        closesLoop: Bool = true,
        date: Date = epoch,
        name: String? = nil
    ) -> WorkoutRouteGroup {
        let bearing = bearingDegrees * .pi / 180
        let centreMeters = 600.0
        let extentMeters = 800.0
        let centreEast = centreMeters * sin(bearing)
        let centreNorth = centreMeters * cos(bearing)
        let half = extentMeters / 2
        let finishEast = closesLoop ? 0.0 : 2 * centreEast
        let finishNorth = closesLoop ? 0.0 : 2 * centreNorth
        let id = UUID()
        let facts = RouteGroupingRouteFacts(
            minLatitude: baseLatitude + (centreNorth - half) / metersPerDegreeLatitude,
            maxLatitude: baseLatitude + (centreNorth + half) / metersPerDegreeLatitude,
            minLongitude: baseLongitude + (centreEast - half) / metersPerDegreeLongitude,
            maxLongitude: baseLongitude + (centreEast + half) / metersPerDegreeLongitude,
            startLatitude: baseLatitude,
            startLongitude: baseLongitude,
            finishLatitude: baseLatitude + finishNorth / metersPerDegreeLatitude,
            finishLongitude: baseLongitude + finishEast / metersPerDegreeLongitude,
            totalDistanceMeters: totalDistanceMeters,
            routePointCount: 200,
            discardedCoordinatePointCount: 0
        )
        return WorkoutRouteGroup(
            id: id,
            name: name,
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: id,
                startDate: date,
                facts: facts
            )
        )
    }

    /// An organization snapshot carrying `groups` with no member assignments —
    /// enough for derived-name derivation, which reads only persisted facts.
    static func organization(groups: [WorkoutRouteGroup]) -> WorkoutLibraryOrganizationSnapshot {
        WorkoutLibraryOrganizationSnapshot(
            routeGroups: groups,
            routeGroupAssignments: []
        )
    }
}
