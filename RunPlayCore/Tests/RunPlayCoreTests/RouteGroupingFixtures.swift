import Foundation
@testable import RunPlayCore

/// Shared synthetic route fixtures for route-grouping tests and benchmarks.
///
/// Everything is deterministic: fixed epoch, fixed geometry, seeded jitter.
/// Following the codebase convention these builders live in one shared enum
/// so both the matcher tests and the benchmark construct identical routes.
enum RouteGroupingFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let baseLatitude = 37.7749
    static let baseLongitude = -122.4194

    static var metersPerDegreeLatitude: Double { 111_000 }
    static var metersPerDegreeLongitude: Double {
        111_000 * cos(baseLatitude * .pi / 180)
    }

    // MARK: - Shapes

    /// Closed square loop starting at the south-west corner, sampled every
    /// `stepMeters` of perimeter.
    static func squareLoop(
        sideMeters: Double,
        stepMeters: Double = 20,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        let perimeter = sideMeters * 4
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= perimeter {
            points.append(squareLoopPoint(
                position: travelled.truncatingRemainder(dividingBy: perimeter),
                side: sideMeters,
                travelled: travelled,
                date: date
            ))
            if travelled >= perimeter { break }
            travelled = min(perimeter, travelled + stepMeters)
        }
        return points
    }

    private static func squareLoopPoint(
        position: Double,
        side: Double,
        travelled: Double,
        date: Date
    ) -> RoutePoint {
        let east: Double
        let north: Double
        switch position {
        case ..<side:
            east = position
            north = 0
        case ..<(2 * side):
            east = side
            north = position - side
        case ..<(3 * side):
            east = side - (position - 2 * side)
            north = side
        default:
            east = 0
            north = side - (position - 3 * side)
        }
        return point(east: east, north: north, travelled: travelled, date: date)
    }

    static func point(east: Double, north: Double, travelled: Double, date: Date) -> RoutePoint {
        RoutePoint(
            timestamp: date.addingTimeInterval(travelled / 3),
            latitude: baseLatitude + north / metersPerDegreeLatitude,
            longitude: baseLongitude + east / metersPerDegreeLongitude,
            distanceFromStartMeters: travelled,
            elapsedSeconds: travelled / 3,
            paceSecondsPerKilometer: 300,
            routeSegmentIndex: 0
        )
    }

    /// A square loop followed by a straight spur east from the start corner.
    ///
    /// The containment shape the match rule must REJECT: the superset rule
    /// was reversed deliberately (a run that covers a route plus extra
    /// distance is not the same route), so loop-plus-spur no longer groups
    /// with the bare loop. Mutual coverage prices the spur as warp-only
    /// travel on the superset side. Manual merge is the recovery path.
    static func loopWithSpur(
        sideMeters: Double,
        spurMeters: Double,
        stepMeters: Double = 20,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        var points = squareLoop(sideMeters: sideMeters, stepMeters: stepMeters, date: date)
        let perimeter = sideMeters * 4
        var along = 0.0
        while along <= spurMeters {
            points.append(point(
                east: along,
                north: 0,
                travelled: perimeter + along,
                date: date
            ))
            if along >= spurMeters { break }
            along = min(spurMeters, along + stepMeters)
        }
        return points
    }

    /// Rectangle loop used for the partial-overlap fixtures: shares the
    /// bottom edge with the square loop of the same width.
    static func rectangleLoop(
        widthMeters: Double,
        heightMeters: Double,
        stepMeters: Double = 20,
        mirrored: Bool = false,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        let perimeter = 2 * (widthMeters + heightMeters)
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= perimeter {
            let position = travelled.truncatingRemainder(dividingBy: perimeter)
            let east: Double
            let north: Double
            switch position {
            case ..<widthMeters:
                east = position
                north = 0
            case ..<(widthMeters + heightMeters):
                east = widthMeters
                north = position - widthMeters
            case ..<(2 * widthMeters + heightMeters):
                east = widthMeters - (position - widthMeters - heightMeters)
                north = heightMeters
            default:
                east = 0
                north = heightMeters - (position - 2 * widthMeters - heightMeters)
            }
            points.append(point(
                east: east,
                north: mirrored ? -north : north,
                travelled: travelled,
                date: date
            ))
            if travelled >= perimeter { break }
            travelled = min(perimeter, travelled + stepMeters)
        }
        return points
    }

    /// Straight line due north — the containment fixtures use a prefix of it.
    static func straightLine(
        distanceMeters: Double,
        stepMeters: Double = 20,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= distanceMeters {
            points.append(point(east: 0, north: travelled, travelled: travelled, date: date))
            if travelled >= distanceMeters { break }
            travelled = min(distanceMeters, travelled + stepMeters)
        }
        return points
    }

    /// A shared northbound prefix followed by a diverging straight tail —
    /// the boundary fixture for the mutual-coverage threshold. Two routes
    /// built with the same `sharedMeters` and `totalMeters` but opposite
    /// tail directions have mutual coverage ≈ sharedMeters / totalMeters,
    /// so the threshold's decision boundary can be probed from either side
    /// while stage 1 still admits the pair (ratio 1, shared start).
    static func divergingRoute(
        sharedMeters: Double,
        totalMeters: Double,
        tailEast: Bool,
        stepMeters: Double = 20,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= sharedMeters {
            points.append(point(east: 0, north: travelled, travelled: travelled, date: date))
            if travelled >= sharedMeters { break }
            travelled = min(sharedMeters, travelled + stepMeters)
        }
        let tailSign: Double = tailEast ? 1 : -1
        let tailStart = travelled
        while travelled <= totalMeters {
            let along = travelled - tailStart
            points.append(point(
                east: tailSign * along,
                north: tailStart,
                travelled: travelled,
                date: date
            ))
            if travelled >= totalMeters { break }
            travelled = min(totalMeters, travelled + stepMeters)
        }
        return points
    }

    // MARK: - Transforms

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

    static func seededNoise(
        on points: [RoutePoint],
        noiseMeters: Double,
        seed: UInt64
    ) -> [RoutePoint] {
        var generator = SplitMix64RouteGrouping(seed: seed)
        return points.map { point in
            let latitudeNoise = generator.symmetric(noiseMeters) / metersPerDegreeLatitude
            let longitudeNoise = generator.symmetric(noiseMeters) / metersPerDegreeLongitude
            return RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude + latitudeNoise,
                longitude: point.longitude + longitudeNoise,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
    }

    // MARK: - Workouts

    static func workout(
        points: [RoutePoint],
        date: Date,
        id: UUID = UUID(),
        name: String? = nil,
        paceSecondsPerKilometer: Double = 300
    ) -> RunWorkout {
        let distance = points.last?.distanceFromStartMeters ?? 0
        let elapsed = points.last?.elapsedSeconds ?? (distance / 3)
        return RunWorkout(
            id: id,
            metadata: WorkoutMetadata(
                name: name,
                activityType: "Running",
                startDate: date,
                endDate: date.addingTimeInterval(max(0, elapsed))
            ),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: distance,
                totalElapsedSeconds: max(0, elapsed),
                averagePaceSecondsPerKilometer: paceSecondsPerKilometer
            )
        )
    }

    /// One repeat of a square loop: same geometry, seeded GPS jitter, unique
    /// date so chronological ordering is deterministic.
    static func loopRepeat(
        sideMeters: Double,
        index: Int,
        noiseMeters: Double = 12,
        stepMeters: Double = 20
    ) -> RunWorkout {
        let date = epoch.addingTimeInterval(Double(index) * 86_400)
        let clean = squareLoop(sideMeters: sideMeters, stepMeters: stepMeters, date: date)
        return workout(
            points: seededNoise(on: clean, noiseMeters: noiseMeters, seed: UInt64(1_000 + index)),
            date: date,
            name: "Loop run \(index)"
        )
    }
}

/// Deterministic pseudo-random source for fixture jitter (SplitMix64, same
/// constants as the aligner fixtures).
struct SplitMix64RouteGrouping {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func symmetric(_ magnitude: Double) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return (unit * 2 - 1) * magnitude
    }
}
