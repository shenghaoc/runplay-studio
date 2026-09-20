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

    /// Straight line due east from the same start point — pairs with
    /// `straightLine` for same-distance point-to-point name fixtures.
    static func eastLine(
        distanceMeters: Double,
        stepMeters: Double = 20,
        date: Date = epoch.addingTimeInterval(0)
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var travelled = 0.0
        while travelled <= distanceMeters {
            points.append(point(east: travelled, north: 0, travelled: travelled, date: date))
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

    // MARK: - Groups

    /// An unnamed route group whose persisted representative summary is
    /// built from `points` exactly the way the store builds one: facts from
    /// the route points, canonical start date from the workout.
    static func group(
        representative points: [RoutePoint],
        date: Date,
        id: UUID = UUID(),
        name: String? = nil
    ) -> WorkoutRouteGroup {
        let representative = workout(points: points, date: date)
        return WorkoutRouteGroup(
            id: id,
            name: name,
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: representative.id,
                startDate: WorkoutLibraryEntry.canonicalStartDate(for: representative),
                facts: RouteGroupingRouteFacts(workout: representative)
            )
        )
    }

    // MARK: - Derived-name populations

    /// Deterministic UUID from the seeded source — the derived-name
    /// property tests must never touch the system RNG (`UUID()`,
    /// `shuffled()`), so ids and permutations come from here.
    static func uuid(from generator: inout SplitMix64RouteGrouping) -> UUID {
        let bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Facts for a synthetic route whose extent centre sits
    /// `centreMeters` from the start point at `bearingDegrees` (0 = north,
    /// clockwise), with a square bounding box of `extentMeters`. The
    /// derived-name derivation reads only persisted facts, so populations
    /// are built straight from facts — no route points needed — with the
    /// bearing controlling the compass token exactly.
    static func namingFacts(
        bearingDegrees: Double,
        centreMeters: Double,
        extentMeters: Double,
        totalDistanceMeters: Double,
        closesLoop: Bool
    ) -> RouteGroupingRouteFacts {
        let bearing = bearingDegrees * .pi / 180
        let centreEast = centreMeters * sin(bearing)
        let centreNorth = centreMeters * cos(bearing)
        let half = extentMeters / 2
        let finishEast = closesLoop ? 0.0 : 2 * centreEast
        let finishNorth = closesLoop ? 0.0 : 2 * centreNorth
        return RouteGroupingRouteFacts(
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
    }

    /// One synthetic group for the derived-name populations.
    static func namingGroup(
        id: UUID,
        bearingDegrees: Double,
        totalDistanceMeters: Double,
        closesLoop: Bool = true,
        centreMeters: Double = 600,
        extentMeters: Double = 800,
        date: Date,
        name: String? = nil
    ) -> WorkoutRouteGroup {
        WorkoutRouteGroup(
            id: id,
            name: name,
            representativeSummary: WorkoutRouteGroupSummary(
                workoutID: id,
                startDate: date,
                facts: namingFacts(
                    bearingDegrees: bearingDegrees,
                    centreMeters: centreMeters,
                    extentMeters: extentMeters,
                    totalDistanceMeters: totalDistanceMeters,
                    closesLoop: closesLoop
                )
            )
        )
    }

    /// A deterministic population at the scale issue #130 produced (286
    /// routes from 317 activities), built so base names collide heavily
    /// and clusters reach every tier:
    ///
    /// - unique-distance loners (bare names);
    /// - sparse pairs across different coarse sectors (coarse-token tier);
    /// - triples sharing a coarse sector but split at the sixteen-point
    ///   tier (fine-token tier);
    /// - dense buckets — the bulk — whose members mostly share one fine
    ///   sector (digest tier), the rest spread over the compass;
    /// - a sprinkle of user-named groups, some sharing names.
    ///
    /// Bucket distances are chosen so the constructs do not bleed into
    /// each other's base names. Every id, date, and angle draw comes from
    /// the seeded source, so the population is reproducible from the seed
    /// alone.
    static func derivedNamePopulation(seed: UInt64, count: Int) -> [WorkoutRouteGroup] {
        var generator = SplitMix64RouteGrouping(seed: seed)
        var groups: [WorkoutRouteGroup] = []
        groups.reserveCapacity(count)
        func nextDate() -> Date {
            epoch.addingTimeInterval(Double(generator.next() % 100_000_000))
        }
        // Fine-sector-centre-ish angles, every one ≥4° from a compass
        // boundary, so the fixture/projection scale mismatch (≈0.3°)
        // cannot flip a sector.
        let angles: [Double] = [3, 27, 45, 63, 93, 117, 135, 159, 183, 207, 225, 249, 273, 297, 315, 339]

        // Loners: unique distances, bare names, alternating loop/route.
        for index in 0..<24 {
            groups.append(namingGroup(
                id: uuid(from: &generator),
                bearingDegrees: angles[Int(generator.next() % 16)],
                totalDistanceMeters: 9_000 + Double(index) * 1_000,
                closesLoop: index.isMultiple(of: 2),
                date: nextDate()
            ))
        }

        // Sparse pairs: shared distance, coarse sectors 90° apart.
        let pairBuckets: [Double] = [1_160, 1_240, 2_800, 3_400, 5_000, 6_200, 7_500, 10_100]
        for bucket in pairBuckets {
            let first = Int(generator.next() % 16)
            for angle in [first, (first + 4) % 16] {
                groups.append(namingGroup(
                    id: uuid(from: &generator),
                    bearingDegrees: angles[angle],
                    totalDistanceMeters: bucket,
                    date: nextDate()
                ))
            }
        }

        // Triples: shared distance and coarse sector (NE), distinct fine
        // sectors (NNE / NE / ENE).
        let tripleBuckets: [Double] = [1_320, 2_100, 2_900, 4_200, 5_400, 6_600, 8_800, 10_200]
        for bucket in tripleBuckets {
            for angle in [27.0, 45.0, 63.0] {
                groups.append(namingGroup(
                    id: uuid(from: &generator),
                    bearingDegrees: angle,
                    totalDistanceMeters: bucket,
                    date: nextDate()
                ))
            }
        }

        // User-named sprinkle, with repeated names — their choice.
        let userNames = ["Morning Run", "Home", "Commute", "Long One"]
        let userDistances: [Double] = [1_600, 2_400, 3_200]
        for index in 0..<10 {
            groups.append(namingGroup(
                id: uuid(from: &generator),
                bearingDegrees: angles[Int(generator.next() % 16)],
                totalDistanceMeters: userDistances[index % userDistances.count],
                date: nextDate(),
                name: userNames[index % userNames.count]
            ))
        }

        // Dense buckets: the bulk of the population. Distance jitter
        // stays within ±40 m so the %.1f base name cannot split.
        let denseBuckets: [Double] = [1_600, 2_400, 3_200, 4_800, 5_800, 7_200]
        let denseCount = max(0, count - groups.count)
        for bucketIndex in 0..<denseBuckets.count {
            let dominant = angles[Int(generator.next() % 16)]
            let members = denseCount / denseBuckets.count + (bucketIndex < denseCount % denseBuckets.count ? 1 : 0)
            for _ in 0..<members {
                let isDominant = generator.next() % 100 < 60
                groups.append(namingGroup(
                    id: uuid(from: &generator),
                    bearingDegrees: isDominant ? dominant : angles[Int(generator.next() % 16)],
                    totalDistanceMeters: denseBuckets[bucketIndex] + generator.symmetric(40),
                    date: nextDate()
                ))
            }
        }

        return groups
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
