import Foundation
import XCTest
@testable import RunPlayCore

/// `RoutePoint.demAltitudeMeters` is derived data added beside the recorded
/// altitude. Uncorrected snapshots must keep their exact bytes, older
/// snapshots must decode unchanged, and nothing that reads the route today may
/// change because the field is present.
final class RoutePointDEMAltitudeCodingTests: XCTestCase {
    // MARK: - Encoding

    func testUncorrectedPointEncodesExactlyLikeThePreDEMShape() throws {
        let point = makePoint(demAltitudeMeters: nil)
        let legacyShape = PreDEMRoutePointShape(point)

        for encoder in [Self.libraryStoreEncoder(), Self.defaultOrderEncoder()] {
            let encoded = try encoder.encode(point)
            let expected = try encoder.encode(legacyShape)
            XCTAssertEqual(
                encoded,
                expected,
                "A point without DEM elevation must encode byte-for-byte as it did before the field existed"
            )
            let text = String(decoding: encoded, as: UTF8.self)
            XCTAssertFalse(text.contains("demAltitudeMeters"))
        }
    }

    func testCorrectedPointAddsOnlyTheDEMKey() throws {
        let uncorrected = makePoint(demAltitudeMeters: nil)
        let corrected = makePoint(demAltitudeMeters: 48.625)
        let encoder = Self.libraryStoreEncoder()

        let uncorrectedObject = try jsonObject(encoder.encode(uncorrected))
        let correctedObject = try jsonObject(encoder.encode(corrected))

        XCTAssertEqual(
            Set(correctedObject.keys).subtracting(uncorrectedObject.keys),
            ["demAltitudeMeters"]
        )
        XCTAssertEqual(correctedObject["demAltitudeMeters"] as? Double, 48.625)
        XCTAssertEqual(correctedObject["altitudeMeters"] as? Double, 41.5)
    }

    func testDEMAltitudeRoundTripsBesideRecordedAltitude() throws {
        let point = makePoint(demAltitudeMeters: -12.375)
        let decoded = try Self.libraryStoreDecoder().decode(
            RoutePoint.self,
            from: Self.libraryStoreEncoder().encode(point)
        )

        XCTAssertEqual(decoded, point)
        XCTAssertEqual(decoded.demAltitudeMeters, -12.375)
        XCTAssertEqual(decoded.altitudeMeters, 41.5, "DEM elevation never replaces recorded altitude")
    }

    func testWorkoutSnapshotWithoutDEMContainsNoDEMKey() throws {
        // Typed locals keep each expression cheap for the type checker, which
        // times out on slower CI runners when literals and arithmetic nest
        // inside a closure passed to an initializer.
        var points: [RoutePoint] = []
        for index in 0..<4 {
            let step: Double = Double(index)
            let seconds: TimeInterval = 800_000_000 + step
            let latitude: Double = 1.3 + step * 0.0001
            let altitude: Double = 10 + step
            let distance: Double = step * 11
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                latitude: latitude,
                longitude: 103.8,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: step
            ))
        }
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Uncorrected"),
            source: .gpx,
            routePoints: points
        )

        let text = String(decoding: try Self.libraryStoreEncoder().encode(workout), as: UTF8.self)
        XCTAssertFalse(text.contains("demAltitudeMeters"))
    }

    // MARK: - Decoding older snapshots

    func testPointJSONWithoutDEMKeyDecodesAsNil() throws {
        let legacyJSON = """
        {
          "id": "3A0D9E55-7B0B-4E53-9A51-6F3B3C2D1E0F",
          "timestamp": 700000000,
          "latitude": 1.25,
          "longitude": -103.5,
          "altitudeMeters": 12.5,
          "distanceFromStartMeters": 100,
          "elapsedSeconds": 25,
          "routeSegmentIndex": 1
        }
        """
        let point = try JSONDecoder().decode(RoutePoint.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(point.demAltitudeMeters)
        XCTAssertEqual(point.altitudeMeters, 12.5)
    }

    func testLegacyWorkoutFixtureDecodesWithoutDEMElevation() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "legacy-paused-workout-v0", withExtension: "json")
        )
        let workout = try Self.libraryStoreDecoder().decode(RunWorkout.self, from: Data(contentsOf: url))

        XCTAssertEqual(workout.routePoints.count, 4)
        XCTAssertTrue(workout.routePoints.allSatisfy { $0.demAltitudeMeters == nil })
    }

    // MARK: - Nothing that reads the route today reads the new field

    func testRouteQualityProcessingIgnoresAndPreservesDEMAltitude() throws {
        var baseline: [RoutePoint] = []
        for index in 0..<12 {
            let step: Double = Double(index)
            // Point 6 is an isolated 5 km teleport the processor rejects.
            let north: Double = index == 6 ? 5_000 : step * 10
            let seconds: TimeInterval = 900_000_000 + step
            let latitude: Double = 1.3 + north / 111_132
            let altitude: Double = 20 + step
            baseline.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: seconds),
                latitude: latitude,
                longitude: 103.8,
                altitudeMeters: altitude,
                distanceFromStartMeters: 0,
                elapsedSeconds: step,
                horizontalAccuracy: 5
            ))
        }
        var withDEM = baseline
        for index in withDEM.indices where !index.isMultiple(of: 3) {
            let step: Double = Double(index)
            let demAltitude: Double = 300 - step * 7.25
            withDEM[index].demAltitudeMeters = demAltitude
        }

        let processor = RouteQualityProcessor()
        let expected = try processor.process(baseline)
        let actual = try processor.process(withDEM)

        XCTAssertEqual(expected.diagnostics.discardedCoordinatePointCount, 1, "the fixture rejects its teleport")
        XCTAssertEqual(actual.diagnostics, expected.diagnostics)
        XCTAssertEqual(actual.distanceSource, expected.distanceSource)
        XCTAssertEqual(actual.distanceProvenance, expected.distanceProvenance)
        XCTAssertEqual(actual.analysisWarnings, expected.analysisWarnings)
        XCTAssertEqual(actual.routePoints.map(\.id), expected.routePoints.map(\.id))
        XCTAssertEqual(
            actual.routePoints.map(\.distanceFromStartMeters.bitPattern),
            expected.routePoints.map(\.distanceFromStartMeters.bitPattern)
        )
        XCTAssertEqual(actual.routePoints.map(\.routeSegmentIndex), expected.routePoints.map(\.routeSegmentIndex))
        XCTAssertEqual(
            actual.elevationProfile.samples,
            expected.elevationProfile.samples,
            "the corrected elevation profile does not read DEM elevation yet"
        )

        let demByID = Dictionary(uniqueKeysWithValues: withDEM.map { ($0.id, $0.demAltitudeMeters) })
        for point in actual.routePoints {
            XCTAssertEqual(point.demAltitudeMeters, demByID[point.id] ?? nil, "retained points keep their DEM value")
        }
    }

    func testJSONImportDoesNotImportDerivedDEMAltitude() throws {
        let json = #"""
        {"source": "json", "routePoints": [
          {"timestamp": "2026-01-01T10:00:00Z", "latitude": 37.7749, "longitude": -122.4194, "altitudeMeters": 12, "demAltitudeMeters": 30},
          {"timestamp": "2026-01-01T10:00:05Z", "latitude": 37.7750, "longitude": -122.4194, "altitudeMeters": 13, "demAltitudeMeters": 31}
        ]}
        """#
        let workout = try JSONWorkoutImporter().importWorkout(from: Data(json.utf8))

        XCTAssertEqual(workout.routePoints.map(\.altitudeMeters), [12, 13])
        XCTAssertTrue(
            workout.routePoints.allSatisfy { $0.demAltitudeMeters == nil },
            "DEM elevation depends on the user's local tiles and is recomputed, never imported"
        )
    }

    func testInterpolatedPointCarriesInterpolatedDEMAltitude() throws {
        let points = [
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 0),
                latitude: 1.3,
                longitude: 103.8,
                altitudeMeters: 10,
                demAltitudeMeters: 100,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 10),
                latitude: 1.301,
                longitude: 103.8,
                altitudeMeters: 20,
                demAltitudeMeters: 120,
                distanceFromStartMeters: 100,
                elapsedSeconds: 10
            ),
        ]

        let midpoint = try XCTUnwrap(RoutePointInterpolator.point(at: 25, in: points))
        XCTAssertEqual(try XCTUnwrap(midpoint.demAltitudeMeters), 105, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(midpoint.altitudeMeters), 12.5, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makePoint(demAltitudeMeters: Double?) -> RoutePoint {
        RoutePoint(
            id: UUID(uuidString: "6C1B2E9A-3F4D-4B8E-9C7A-1D2E3F4A5B6C")!,
            // Whole seconds: the library store's ISO-8601 strategy writes no
            // fractional seconds, and this suite is about DEM altitude.
            timestamp: Date(timeIntervalSinceReferenceDate: 812_345_678),
            latitude: 1.2875,
            longitude: 103.8515625,
            altitudeMeters: 41.5,
            demAltitudeMeters: demAltitudeMeters,
            distanceFromStartMeters: 1_234.5,
            elapsedSeconds: 456.25,
            speedMetersPerSecond: 3.5,
            heartRateBPM: 152,
            cadence: 178,
            powerWatts: 250,
            horizontalAccuracy: 4.5,
            routeSegmentIndex: 2
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The exact encoder configuration `FileWorkoutLibraryStore` writes with.
    private static func libraryStoreEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func libraryStoreDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Unsorted output exposes key order as well as key set.
    private static func defaultOrderEncoder() -> JSONEncoder {
        JSONEncoder()
    }
}

/// The `RoutePoint` field set immediately before `demAltitudeMeters`, with the
/// synthesized `Encodable` conformance `RoutePoint` used then. Comparing
/// against it proves the hand-written encoder emits the same bytes for points
/// that carry no DEM elevation.
private struct PreDEMRoutePointShape: Encodable {
    let id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var distanceFromStartMeters: Double
    var elapsedSeconds: Double
    var speedMetersPerSecond: Double?
    var paceSecondsPerKilometer: Double?
    var heartRateBPM: Double?
    var cadence: Double?
    var powerWatts: Double?
    var groundContactTimeMilliseconds: Double?
    var verticalOscillationMillimeters: Double?
    var verticalRatioPercent: Double?
    var stanceTimeBalancePercent: Double?
    var stepLengthMeters: Double?
    var horizontalAccuracy: Double?
    var routeSegmentIndex: Int

    init(_ point: RoutePoint) {
        id = point.id
        timestamp = point.timestamp
        latitude = point.latitude
        longitude = point.longitude
        altitudeMeters = point.altitudeMeters
        distanceFromStartMeters = point.distanceFromStartMeters
        elapsedSeconds = point.elapsedSeconds
        speedMetersPerSecond = point.speedMetersPerSecond
        paceSecondsPerKilometer = point.paceSecondsPerKilometer
        heartRateBPM = point.heartRateBPM
        cadence = point.cadence
        powerWatts = point.powerWatts
        groundContactTimeMilliseconds = point.groundContactTimeMilliseconds
        verticalOscillationMillimeters = point.verticalOscillationMillimeters
        verticalRatioPercent = point.verticalRatioPercent
        stanceTimeBalancePercent = point.stanceTimeBalancePercent
        stepLengthMeters = point.stepLengthMeters
        horizontalAccuracy = point.horizontalAccuracy
        routeSegmentIndex = point.routeSegmentIndex
    }
}
