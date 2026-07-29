import XCTest
@testable import RunPlayCore

/// End-to-end parity between the shipping `PersonalHeatmapBuilder` (C++23
/// coverage kernel) and `SwiftPersonalHeatmapBuilderOracle`, which reproduces
/// the pre-migration pure-Swift builder.
///
/// The bridge fixture tests cover the coverage kernel itself. These tests cover
/// the surrounding Swift orchestration that the migration reshaped: statistics
/// and diagnostics moved from preparation-time derivation (`has ≥1 projected
/// point`) to per-pass derivation (`produced ≥1 coverage cell`), and
/// `totalDistanceMeters` is now accumulated during aggregation rather than
/// reduced over a prepared array. `PersonalHeatmapSnapshot` is `Hashable`, so a
/// whole-snapshot comparison pins cells, intensities, bounds, statistics, and
/// diagnostics at once.
final class PersonalHeatmapBuilderOracleParityTests: XCTestCase {

    private let builder = PersonalHeatmapBuilder()
    private let oracle = SwiftPersonalHeatmapBuilderOracle()
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func point(
        lat: Double,
        lon: Double,
        distance: Double = 0,
        elapsed: Double = 0,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: origin.addingTimeInterval(elapsed),
            latitude: lat,
            longitude: lon,
            distanceFromStartMeters: distance,
            elapsedSeconds: elapsed,
            routeSegmentIndex: segment
        )
    }

    private func workout(
        name: String,
        points: [RoutePoint],
        startDate: Date?,
        distanceMeters: Double
    ) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: name, startDate: startDate),
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: distanceMeters,
                totalElapsedSeconds: points.last?.elapsedSeconds ?? 0
            )
        )
    }

    /// Deterministic library exercising every exclusion, gap, and overlap path.
    private func makeLibrary() -> [RunWorkout] {
        var seed: UInt64 = 0x5DEECE66D
        func nextUnit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }

        var library: [RunWorkout] = []

        // Overlapping corridor runs: drive maximumOverlap and the min-repeat filter.
        for w in 0..<12 {
            var points: [RoutePoint] = []
            var lat = 1.3000 + Double(w % 3) * 0.000_05
            var lon = 103.8000
            for p in 0..<40 {
                lon += 0.000_08
                lat += (nextUnit() - 0.5) * 0.000_02
                points.append(point(
                    lat: lat,
                    lon: lon,
                    distance: Double(p) * 9,
                    elapsed: Double(p) * 5,
                    segment: p < 20 ? 0 : 1  // explicit segment break mid-route
                ))
            }
            library.append(workout(
                name: "Corridor \(w)",
                points: points,
                startDate: origin.addingTimeInterval(Double(w) * 86_400),
                distanceMeters: 360
            ))
        }

        // Invalid intermediate coordinates: must break effective segments in both.
        for w in 0..<4 {
            var points: [RoutePoint] = []
            var lat = 1.3100
            var lon = 103.8100
            for p in 0..<30 {
                if p % 7 == 3 {
                    points.append(point(lat: 200.0, lon: lon, elapsed: Double(p), segment: 0))
                    continue
                }
                lat += 0.000_06
                lon += 0.000_04
                points.append(point(lat: lat, lon: lon, elapsed: Double(p), segment: 0))
            }
            library.append(workout(
                name: "Broken \(w)",
                points: points,
                startDate: origin.addingTimeInterval(Double(w) * 3_600),
                distanceMeters: 275
            ))
        }

        // Oversized intervals: drive invalidRouteIntervalsSkipped.
        library.append(workout(
            name: "Teleport",
            points: [
                point(lat: 1.3200, lon: 103.8200, elapsed: 0),
                point(lat: 1.9000, lon: 104.4000, elapsed: 10),
                point(lat: 1.3201, lon: 103.8201, elapsed: 20)
            ],
            startDate: origin,
            distanceMeters: 120
        ))

        // Stationary duplicates: zero-length interval path.
        library.append(workout(
            name: "Stationary",
            points: (0..<15).map { point(lat: 1.3300, lon: 103.8300, elapsed: Double($0)) },
            startDate: origin,
            distanceMeters: 0
        ))

        // Single point.
        library.append(workout(
            name: "Single",
            points: [point(lat: 1.3400, lon: 103.8400)],
            startDate: origin,
            distanceMeters: 5
        ))

        // No route at all: excludedNoRoute.
        library.append(workout(name: "Empty", points: [], startDate: origin, distanceMeters: 900))

        // Every coordinate invalid: excludedNoRoute via projection rejection.
        // This is the exact path where "has projected points" and "produced
        // cells" could disagree between the two derivations.
        library.append(workout(
            name: "AllInvalid",
            points: (0..<10).map { point(lat: 91.0 + Double($0), lon: 400.0, elapsed: Double($0)) },
            startDate: origin,
            distanceMeters: 750
        ))

        // Undated workouts with and without route-point fallback timestamps.
        library.append(workout(
            name: "Undated",
            points: (0..<12).map { point(lat: 1.3500 + Double($0) * 0.000_05, lon: 103.8500) },
            startDate: nil,
            distanceMeters: 300
        ))
        library.append(workout(name: "UndatedEmpty", points: [], startDate: nil, distanceMeters: 60))

        // Non-finite and negative summary distances: safe-distance clamp.
        library.append(workout(
            name: "NaNDistance",
            points: (0..<10).map { point(lat: 1.3600 + Double($0) * 0.000_05, lon: 103.8600) },
            startDate: origin,
            distanceMeters: .nan
        ))
        library.append(workout(
            name: "NegativeDistance",
            points: (0..<10).map { point(lat: 1.3700 + Double($0) * 0.000_05, lon: 103.8700) },
            startDate: origin,
            distanceMeters: -500
        ))

        return library
    }

    // MARK: - Parity

    private func assertParity(
        _ configuration: PersonalHeatmapConfiguration,
        _ workouts: [RunWorkout],
        _ label: String,
        line: UInt = #line
    ) throws {
        let expected = try oracle.build(workouts: workouts, configuration: configuration)
        let actual = try builder.build(workouts: workouts, configuration: configuration)

        // Compare the parts individually first so a failure names the field.
        XCTAssertEqual(actual.statistics, expected.statistics, "\(label): statistics", line: line)
        XCTAssertEqual(actual.diagnostics, expected.diagnostics, "\(label): diagnostics", line: line)
        XCTAssertEqual(actual.bounds, expected.bounds, "\(label): bounds", line: line)
        XCTAssertEqual(actual.cells, expected.cells, "\(label): cells", line: line)
        XCTAssertEqual(actual, expected, "\(label): snapshot", line: line)
    }

    func testSnapshotParityAcrossConfigurations() throws {
        let library = makeLibrary()

        let configurations: [(String, PersonalHeatmapConfiguration)] = [
            ("default", PersonalHeatmapConfiguration()),
            ("fine", PersonalHeatmapConfiguration(cellSizeMeters: 25)),
            ("broad", PersonalHeatmapConfiguration(cellSizeMeters: 100)),
            ("minRepeat2", PersonalHeatmapConfiguration(cellSizeMeters: 50, minimumWorkoutCount: 2)),
            ("minRepeat5", PersonalHeatmapConfiguration(cellSizeMeters: 25, minimumWorkoutCount: 5)),
            (
                "tightInterval",
                PersonalHeatmapConfiguration(cellSizeMeters: 50, maximumIntervalMeters: 100)
            )
        ]

        for (label, configuration) in configurations {
            try assertParity(configuration, library, label)
        }
    }

    /// Small cell size against a small render budget forces repeated coarsening,
    /// so `includedWorkoutCount`, `totalDistanceMeters`, and
    /// `invalidRouteIntervalsSkipped` are recomputed on every adaptive pass.
    func testSnapshotParityUnderAdaptiveCoarsening() throws {
        let library = makeLibrary()

        var maximumRetriesObserved = 0

        for budget in [1, 10, 100, 500] {
            let configuration = PersonalHeatmapConfiguration(
                cellSizeMeters: 5,
                maximumRenderedCellCount: budget
            )
            let snapshot = try builder.build(workouts: library, configuration: configuration)
            maximumRetriesObserved = max(
                maximumRetriesObserved,
                snapshot.diagnostics.adaptiveResolutionRetries
            )
            try assertParity(configuration, library, "adaptive-budget-\(budget)")
        }

        // Guard the fixture: if coarsening stopped being reachable, the parity
        // assertions above would silently stop covering the adaptive path.
        XCTAssertGreaterThan(
            maximumRetriesObserved,
            0,
            "fixture no longer exercises adaptive coarsening"
        )
    }

    func testSnapshotParityUnderDateFiltering() throws {
        let library = makeLibrary()

        let filters: [(String, PersonalHeatmapDateFilter)] = [
            ("allTime", .allTime),
            (
                "narrowRange",
                .range(start: origin, end: origin.addingTimeInterval(3 * 86_400))
            ),
            (
                "wideRange",
                .range(
                    start: origin.addingTimeInterval(-86_400),
                    end: origin.addingTimeInterval(30 * 86_400)
                )
            ),
            (
                "emptyRange",
                .range(
                    start: origin.addingTimeInterval(400 * 86_400),
                    end: origin.addingTimeInterval(401 * 86_400)
                )
            )
        ]

        for (label, filter) in filters {
            try assertParity(
                PersonalHeatmapConfiguration(dateFilter: filter, cellSizeMeters: 50),
                library,
                "date-\(label)"
            )
        }
    }

    func testSnapshotParityForDegenerateLibraries() throws {
        let configuration = PersonalHeatmapConfiguration(cellSizeMeters: 50)

        try assertParity(configuration, [], "empty-library")

        try assertParity(
            configuration,
            [workout(name: "Empty", points: [], startDate: origin, distanceMeters: 100)],
            "only-routeless"
        )

        try assertParity(
            configuration,
            [workout(
                name: "AllInvalid",
                points: (0..<8).map { point(lat: 95.0, lon: 200.0, elapsed: Double($0)) },
                startDate: origin,
                distanceMeters: 100
            )],
            "only-invalid-coordinates"
        )

        try assertParity(
            configuration,
            [workout(name: "Undated", points: [], startDate: nil, distanceMeters: 0)],
            "only-undated-routeless"
        )
    }
}
