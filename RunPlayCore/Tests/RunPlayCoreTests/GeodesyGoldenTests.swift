import XCTest
import RunPlayEngine
import RunPlayEngineTestSupport
@testable import RunPlayCore

/// Parity and golden coverage for the Swift engine geodesy primitives.
///
/// The production Swift `GeoDistance` implementation is the reference oracle.
/// These tests prove the engine kernel reproduces it, including its documented
/// limitations. The class keeps its name so the benchmark script filter in
/// `scripts/run-geodesy-benchmark.sh` still matches.
final class RunPlayGeodesyBridgeTests: XCTestCase {

    // MARK: - Tolerance

    /// Narrow documented tolerance for finite results.
    ///
    /// Absolute 1e-6 m dominates short distances; the relative 1e-12 term
    /// covers intercontinental magnitudes. Both implementations use the same
    /// formula and operation order, so on one platform they agree bit for bit.
    /// This margin exists only so macOS and Linux libm implementations of
    /// `sin`, `cos`, and `atan2` are not required to be bit-identical.
    private static func tolerance(forReference reference: Double) -> Double {
        max(1e-6, abs(reference) * 1e-12)
    }

    /// Compares an engine result against the Swift reference.
    ///
    /// Non-finite results are compared by classification, so a NaN or a signed
    /// infinity must appear on both sides rather than being silently accepted.
    private func assertParity(
        engine engineValue: Double,
        swift swiftReference: Double,
        _ label: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if swiftReference.isNaN || engineValue.isNaN {
            XCTAssertTrue(
                swiftReference.isNaN && engineValue.isNaN,
                "\(label()): NaN classification diverged "
                    + "(swift=\(swiftReference) engine=\(engineValue))",
                file: file,
                line: line
            )
            return
        }

        if swiftReference.isInfinite || engineValue.isInfinite {
            XCTAssertTrue(
                swiftReference.isInfinite && engineValue.isInfinite
                    && swiftReference.sign == engineValue.sign,
                "\(label()): infinity classification diverged "
                    + "(swift=\(swiftReference) engine=\(engineValue))",
                file: file,
                line: line
            )
            return
        }

        let allowed = Self.tolerance(forReference: swiftReference)
        XCTAssertLessThanOrEqual(
            abs(engineValue - swiftReference),
            allowed,
            "\(label()): swift=\(swiftReference) engine=\(engineValue) tolerance=\(allowed)",
            file: file,
            line: line
        )
    }

    // MARK: - Deterministic fixtures

    /// Seeded linear-congruential generator.
    ///
    /// Fixtures must be reproducible across runs and platforms, so this never
    /// uses `SystemRandomNumberGenerator`.
    private struct DeterministicGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func nextUnitInterval() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        mutating func next(in range: ClosedRange<Double>) -> Double {
            range.lowerBound
                + nextUnitInterval() * (range.upperBound - range.lowerBound)
        }
    }

    private struct Coordinate {
        let latitude: Double
        let longitude: Double
    }

    private struct CoordinatePair {
        let first: Coordinate
        let second: Coordinate
        let label: String
    }

    /// Latitudes covering range boundaries, just-inside and just-outside
    /// values, signed zero, non-finite values, and every hemisphere.
    private static let latitudeMatrix: [Double] = [
        0, -0.0,
        90, -90,
        90.0.nextUp, (-90.0).nextDown,
        90.0.nextDown, (-90.0).nextUp,
        89.9999, -89.9999,
        91, -91,
        45, -45,
        37.7749, -33.8688,
        1.352083, 51.5074, 71.0, -17.0,
        180, -180,
        .nan, .infinity, -.infinity,
    ]

    /// Longitudes covering the same classes of value.
    private static let longitudeMatrix: [Double] = [
        0, -0.0,
        180, -180,
        180.0.nextUp, (-180.0).nextDown,
        180.0.nextDown, (-180.0).nextUp,
        179.9999, -179.9999,
        181, -181,
        90, -90,
        103.819836, -122.4194,
        151.2093, -0.1278, 25.0,
        .nan, .infinity, -.infinity,
    ]

    /// Explicit distance fixtures, including every coordinate pair asserted by
    /// the native C++ tests.
    private static let namedDistancePairs: [CoordinatePair] = [
        .init(
            first: .init(latitude: 37.7749, longitude: -122.4194),
            second: .init(latitude: 37.7749, longitude: -122.4194),
            label: "same point"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: 0),
            label: "origin to origin"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 1, longitude: 0),
            label: "one degree latitude at the equator"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: 1),
            label: "one degree longitude at the equator"
        ),
        .init(
            first: .init(latitude: 1.352083, longitude: 103.819836),
            second: .init(latitude: 1.353083, longitude: 103.820836),
            label: "Singapore short step"
        ),
        .init(
            first: .init(latitude: 37.7749, longitude: -122.4194),
            second: .init(latitude: 34.0522, longitude: -118.2437),
            label: "San Francisco to Los Angeles"
        ),
        .init(
            first: .init(latitude: 34.0522, longitude: -118.2437),
            second: .init(latitude: 37.7749, longitude: -122.4194),
            label: "Los Angeles to San Francisco"
        ),
        .init(
            first: .init(latitude: -33.8688, longitude: 151.2093),
            second: .init(latitude: -37.8136, longitude: 144.9631),
            label: "Sydney to Melbourne"
        ),
        .init(
            first: .init(latitude: 40.7128, longitude: -74.0060),
            second: .init(latitude: 51.5074, longitude: -0.1278),
            label: "New York to London"
        ),
        .init(
            first: .init(latitude: 0, longitude: 179.9995),
            second: .init(latitude: 0, longitude: -179.9995),
            label: "antimeridian crossing"
        ),
        .init(
            first: .init(latitude: -17, longitude: 179.5),
            second: .init(latitude: -17, longitude: -179.5),
            label: "antimeridian crossing at 17S"
        ),
        .init(
            first: .init(latitude: 90, longitude: 0),
            second: .init(latitude: 89, longitude: 0),
            label: "north pole boundary"
        ),
        .init(
            first: .init(latitude: -90, longitude: 0),
            second: .init(latitude: -89, longitude: 0),
            label: "south pole boundary"
        ),
        .init(
            first: .init(latitude: 90, longitude: 45),
            second: .init(latitude: 90, longitude: -135),
            label: "two longitudes at the north pole"
        ),
        .init(
            first: .init(latitude: 90, longitude: 0),
            second: .init(latitude: -90, longitude: 0),
            label: "pole to pole"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: 180),
            label: "equatorial antipodes"
        ),
        .init(
            first: .init(latitude: 45, longitude: 0),
            second: .init(latitude: -45, longitude: 180),
            label: "mid-latitude antipodes"
        ),
        .init(
            first: .init(latitude: 12, longitude: 34),
            second: .init(latitude: -12, longitude: -146),
            label: "antipodes whose haversine term rounds above one"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0.0001, longitude: 180),
            label: "nearly antipodal"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 1e-9, longitude: 180),
            label: "nearly antipodal by 1e-9 degrees"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: 179.999),
            label: "longitude-only near antipodal"
        ),
        .init(
            first: .init(latitude: 1.35, longitude: 103.8),
            second: .init(latitude: 1.350000001, longitude: 103.8),
            label: "1e-9 degree step"
        ),
        .init(
            first: .init(latitude: 1.35, longitude: 103.8),
            second: .init(latitude: 1.3500001, longitude: 103.8),
            label: "1e-7 degree step"
        ),
        .init(
            first: .init(latitude: -0.0, longitude: -0.0),
            second: .init(latitude: 0, longitude: 0),
            label: "signed zero to positive zero"
        ),
        .init(
            first: .init(latitude: 91, longitude: 0),
            second: .init(latitude: 0, longitude: 0),
            label: "invalid first latitude"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: 181),
            label: "invalid second longitude"
        ),
        .init(
            first: .init(latitude: .nan, longitude: 0),
            second: .init(latitude: 0, longitude: 0),
            label: "NaN first latitude"
        ),
        .init(
            first: .init(latitude: 0, longitude: 0),
            second: .init(latitude: 0, longitude: .nan),
            label: "NaN second longitude"
        ),
        .init(
            first: .init(latitude: .infinity, longitude: 0),
            second: .init(latitude: 0, longitude: 0),
            label: "infinite first latitude"
        ),
        .init(
            first: .init(latitude: 0, longitude: -.infinity),
            second: .init(latitude: 0, longitude: 0),
            label: "negative infinite first longitude"
        ),
    ]

    /// Builds the complete deterministic distance fixture set.
    private static func distanceFixtures() -> [CoordinatePair] {
        var pairs = namedDistancePairs

        // Coordinate grid across every hemisphere.
        let gridLatitudes = stride(from: -90.0, through: 90.0, by: 15.0)
        let gridLongitudes = stride(from: -180.0, through: 180.0, by: 30.0)
        for latitude in gridLatitudes {
            for longitude in gridLongitudes {
                pairs.append(
                    .init(
                        first: .init(latitude: latitude, longitude: longitude),
                        second: .init(latitude: 1.352083, longitude: 103.819836),
                        label: "grid (\(latitude), \(longitude)) to Singapore"
                    )
                )
                pairs.append(
                    .init(
                        first: .init(latitude: latitude, longitude: longitude),
                        second: .init(
                            latitude: min(90.0, latitude + 15.0),
                            longitude: max(-180.0, longitude - 30.0)
                        ),
                        label: "grid step from (\(latitude), \(longitude))"
                    )
                )
            }
        }

        // Antimeridian pairs at a range of latitudes.
        for latitude in stride(from: -80.0, through: 80.0, by: 10.0) {
            pairs.append(
                .init(
                    first: .init(latitude: latitude, longitude: 179.9),
                    second: .init(latitude: latitude, longitude: -179.9),
                    label: "antimeridian at \(latitude)"
                )
            )
        }

        // Near-pole pairs.
        for offset in [1e-7, 1e-5, 1e-3, 0.01, 0.5] {
            pairs.append(
                .init(
                    first: .init(latitude: 90 - offset, longitude: 12.5),
                    second: .init(latitude: 90, longitude: -167.5),
                    label: "near north pole by \(offset)"
                )
            )
            pairs.append(
                .init(
                    first: .init(latitude: -90 + offset, longitude: 12.5),
                    second: .init(latitude: -90, longitude: -167.5),
                    label: "near south pole by \(offset)"
                )
            )
        }

        // Short running-scale steps around a plausible route.
        var generator = DeterministicGenerator(seed: 0x2545_F491_4F6C_DD1D)
        for index in 0..<400 {
            let latitude = generator.next(in: 1.20...1.48)
            let longitude = generator.next(in: 103.60...103.99)
            let latitudeStep = generator.next(in: -0.00012...0.00012)
            let longitudeStep = generator.next(in: -0.00012...0.00012)
            pairs.append(
                .init(
                    first: .init(latitude: latitude, longitude: longitude),
                    second: .init(
                        latitude: latitude + latitudeStep,
                        longitude: longitude + longitudeStep
                    ),
                    label: "running-scale step \(index)"
                )
            )
        }

        // Long intercontinental distances.
        for index in 0..<200 {
            let first = Coordinate(
                latitude: generator.next(in: -89.0...89.0),
                longitude: generator.next(in: -179.0...179.0)
            )
            let second = Coordinate(
                latitude: generator.next(in: -89.0...89.0),
                longitude: generator.next(in: -179.0...179.0)
            )
            pairs.append(
                .init(first: first, second: second, label: "intercontinental \(index)")
            )
        }

        // Invalid coordinates paired against valid ones.
        let invalid: [Coordinate] = [
            .init(latitude: 90.0.nextUp, longitude: 0),
            .init(latitude: (-90.0).nextDown, longitude: 0),
            .init(latitude: 0, longitude: 180.0.nextUp),
            .init(latitude: 0, longitude: (-180.0).nextDown),
            .init(latitude: .nan, longitude: .nan),
            .init(latitude: .infinity, longitude: .infinity),
            .init(latitude: -.infinity, longitude: 0),
            .init(latitude: 0, longitude: .nan),
        ]
        for (index, coordinate) in invalid.enumerated() {
            pairs.append(
                .init(
                    first: coordinate,
                    second: .init(latitude: 1.352083, longitude: 103.819836),
                    label: "invalid first \(index)"
                )
            )
            pairs.append(
                .init(
                    first: .init(latitude: 1.352083, longitude: 103.819836),
                    second: coordinate,
                    label: "invalid second \(index)"
                )
            )
        }

        return pairs
    }

    // MARK: - Coordinate validation parity

    func testCoordinateValidationMatchesSwiftExactly() {
        var comparisons = 0
        for latitude in Self.latitudeMatrix {
            for longitude in Self.longitudeMatrix {
                let swiftResult = GeoDistance.isValidCoordinate(
                    lat: latitude,
                    lon: longitude
                )
                let engineResult = EngineGeodesy.isValidCoordinate(
                    latitude: latitude,
                    longitude: longitude
                )
                XCTAssertEqual(
                    engineResult,
                    swiftResult,
                    "validation diverged at (\(latitude), \(longitude))"
                )
                comparisons += 1
            }
        }
        XCTAssertGreaterThanOrEqual(
            comparisons,
            400,
            "the coordinate matrix must stay broad"
        )
    }

    func testCoordinateValidationAcceptsInclusiveBoundaries() {
        let boundaries: [(Double, Double)] = [
            (-90, -180), (90, 180), (-90, 180), (90, -180),
            (0, 0), (-0.0, -0.0),
        ]
        for (latitude, longitude) in boundaries {
            XCTAssertTrue(
                EngineGeodesy.isValidCoordinate(
                    latitude: latitude,
                    longitude: longitude
                ),
                "(\(latitude), \(longitude)) must be accepted"
            )
            XCTAssertTrue(
                GeoDistance.isValidCoordinate(lat: latitude, lon: longitude),
                "the Swift reference must also accept (\(latitude), \(longitude))"
            )
        }
    }

    // MARK: - Distance parity

    func testDistanceMatchesSwiftAcrossDeterministicFixtures() {
        let fixtures = Self.distanceFixtures()
        XCTAssertGreaterThanOrEqual(
            fixtures.count,
            1_000,
            "the distance fixture set must stay broad"
        )

        for fixture in fixtures {
            let swiftReference = GeoDistance.distanceMeters(
                fromLat: fixture.first.latitude,
                lon: fixture.first.longitude,
                toLat: fixture.second.latitude,
                lon: fixture.second.longitude
            )
            let engineValue = EngineGeodesy.distanceMeters(
                latitude1: fixture.first.latitude,
                longitude1: fixture.first.longitude,
                latitude2: fixture.second.latitude,
                longitude2: fixture.second.longitude
            )
            assertParity(engine: engineValue, swift: swiftReference, fixture.label)
        }
    }

    func testInvalidDistanceInputsReturnExactlyZeroInBothImplementations() {
        let invalidPairs = Self.namedDistancePairs.filter { pair in
            !GeoDistance.isValidCoordinate(
                lat: pair.first.latitude,
                lon: pair.first.longitude
            )
                || !GeoDistance.isValidCoordinate(
                    lat: pair.second.latitude,
                    lon: pair.second.longitude
                )
        }
        XCTAssertGreaterThanOrEqual(
            invalidPairs.count,
            6,
            "invalid-input coverage must stay present"
        )

        for pair in invalidPairs {
            let swiftReference = GeoDistance.distanceMeters(
                fromLat: pair.first.latitude,
                lon: pair.first.longitude,
                toLat: pair.second.latitude,
                lon: pair.second.longitude
            )
            let engineValue = EngineGeodesy.distanceMeters(
                latitude1: pair.first.latitude,
                longitude1: pair.first.longitude,
                latitude2: pair.second.latitude,
                longitude2: pair.second.longitude
            )
            XCTAssertEqual(swiftReference, 0, "\(pair.label): Swift must return zero")
            XCTAssertEqual(engineValue, 0, "\(pair.label): the engine must return zero")
            XCTAssertFalse(
                engineValue.sign == .minus,
                "\(pair.label): the engine must return positive zero"
            )
        }
    }

    /// The engine kernel must reproduce the Swift limitation, not silently repair
    /// it. Fixing this would change existing analysis results and belongs to a
    /// separate, explicitly scoped decision.
    func testExactlyAntipodalNaNLimitationIsPreservedIdentically() {
        let swiftReference = GeoDistance.distanceMeters(
            fromLat: 12, lon: 34,
            toLat: -12, lon: -146
        )
        let engineValue = EngineGeodesy.distanceMeters(
            latitude1: 12, longitude1: 34,
            latitude2: -12, longitude2: -146
        )
        XCTAssertTrue(
            swiftReference.isNaN,
            "the Swift reference is expected to produce NaN for this antipodal pair"
        )
        XCTAssertTrue(engineValue.isNaN, "the engine kernel must reproduce the NaN result")
    }

    // MARK: - Projection parity

    func testProjectionMatchesSwiftAcrossDeterministicFixtures() {
        // Centres spanning the equator, Singapore scale, high latitude,
        // antimeridian-adjacent longitudes, the poles, and signed zero.
        let centers: [Coordinate] = [
            .init(latitude: 0, longitude: 0),
            .init(latitude: -0.0, longitude: -0.0),
            .init(latitude: 0, longitude: 179.9999),
            .init(latitude: 0, longitude: -179.9999),
            .init(latitude: 1.352083, longitude: 103.819836),
            .init(latitude: -1.352083, longitude: -103.819836),
            .init(latitude: 37.7749, longitude: -122.4194),
            .init(latitude: 51.5074, longitude: -0.1278),
            .init(latitude: -33.8688, longitude: 151.2093),
            .init(latitude: 71.0, longitude: 25.0),
            .init(latitude: -71.0, longitude: -25.0),
            .init(latitude: 89.9999, longitude: 0),
            .init(latitude: -89.9999, longitude: 0),
            .init(latitude: 90, longitude: 180),
            .init(latitude: -90, longitude: -180),
            .init(latitude: 45, longitude: 90),
            .init(latitude: -45, longitude: -90),
            .init(latitude: 23.4368, longitude: 0),
            .init(latitude: -17.0, longitude: 179.5),
            .init(latitude: 60.0, longitude: -150.0),
        ]

        // Offsets from route scale up to continental scale, plus signed zero.
        let offsets: [Double] = [
            0, -0.0,
            1e-9, -1e-9,
            1e-6, -1e-6,
            0.001, -0.001,
            0.01, -0.01,
            0.1, -0.1,
            1, -1,
            5, -5,
            15, -15,
            45, -45,
            0.0001234, -0.0004321,
            2.5, -7.25,
            30, -30,
            0.5, -0.5,
            120, -120,
        ]

        // Pair each latitude offset with several longitude offsets by index, so
        // the combination count is exact and independent of float comparison.
        var comparisons = 0
        for center in centers {
            for (offsetIndex, latitudeOffset) in offsets.enumerated() {
                for shift in [0, 7, 13] {
                    let longitudeOffset = offsets[(offsetIndex + shift) % offsets.count]
                    let latitude = center.latitude + latitudeOffset
                    let longitude = center.longitude + longitudeOffset
                    let swiftReference = GeoDistance.latLonToMeters(
                        lat: latitude,
                        lon: longitude,
                        centerLat: center.latitude,
                        centerLon: center.longitude
                    )
                    let engineValue = EngineGeodesy.projectToLocalMeters(
                        latitude: latitude,
                        longitude: longitude,
                        centerLatitude: center.latitude,
                        centerLongitude: center.longitude
                    )
                    let label = "centre (\(center.latitude), \(center.longitude))"
                        + " offset (\(latitudeOffset), \(longitudeOffset))"
                    assertParity(
                        engine: engineValue.xMeters,
                        swift: swiftReference.x,
                        "\(label) x"
                    )
                    assertParity(
                        engine: engineValue.zMeters,
                        swift: swiftReference.z,
                        "\(label) z"
                    )
                    comparisons += 1
                }
            }
        }

        // A seeded sweep keeps coverage broad without a random generator.
        var generator = DeterministicGenerator(seed: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<800 {
            let center = Coordinate(
                latitude: generator.next(in: -90.0...90.0),
                longitude: generator.next(in: -180.0...180.0)
            )
            let point = Coordinate(
                latitude: center.latitude + generator.next(in: -5.0...5.0),
                longitude: center.longitude + generator.next(in: -5.0...5.0)
            )
            let swiftReference = GeoDistance.latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: center.latitude,
                centerLon: center.longitude
            )
            let engineValue = EngineGeodesy.projectToLocalMeters(
                latitude: point.latitude,
                longitude: point.longitude,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude
            )
            let label = "swept centre (\(center.latitude), \(center.longitude))"
            assertParity(engine: engineValue.xMeters, swift: swiftReference.x, "\(label) x")
            assertParity(engine: engineValue.zMeters, swift: swiftReference.z, "\(label) z")
            comparisons += 1
        }

        XCTAssertGreaterThanOrEqual(
            comparisons,
            1_000,
            "the projection fixture set must contain at least 1,000 combinations"
        )
    }

    func testProjectionNonFiniteClassificationMatchesSwift() {
        let nonFiniteCases: [(Coordinate, Coordinate, String)] = [
            (
                .init(latitude: .nan, longitude: 0),
                .init(latitude: 0, longitude: 0),
                "NaN latitude"
            ),
            (
                .init(latitude: 0, longitude: .nan),
                .init(latitude: 0, longitude: 0),
                "NaN longitude"
            ),
            (
                .init(latitude: 0, longitude: .infinity),
                .init(latitude: 0, longitude: 0),
                "positive infinite longitude"
            ),
            (
                .init(latitude: 0, longitude: -.infinity),
                .init(latitude: 0, longitude: 0),
                "negative infinite longitude"
            ),
            (
                .init(latitude: .infinity, longitude: 0),
                .init(latitude: 0, longitude: 0),
                "positive infinite latitude"
            ),
            (
                .init(latitude: -.infinity, longitude: 0),
                .init(latitude: 0, longitude: 0),
                "negative infinite latitude"
            ),
            (
                .init(latitude: 1, longitude: 1),
                .init(latitude: .nan, longitude: 0),
                "NaN centre latitude"
            ),
            (
                .init(latitude: 1, longitude: 1),
                .init(latitude: 0, longitude: .nan),
                "NaN centre longitude"
            ),
            (
                .init(latitude: 0, longitude: 0),
                .init(latitude: 0, longitude: .infinity),
                "infinite centre longitude"
            ),
            (
                .init(latitude: 0, longitude: 0),
                .init(latitude: .infinity, longitude: 0),
                "infinite centre latitude"
            ),
        ]

        for (point, center, label) in nonFiniteCases {
            let swiftReference = GeoDistance.latLonToMeters(
                lat: point.latitude,
                lon: point.longitude,
                centerLat: center.latitude,
                centerLon: center.longitude
            )
            let engineValue = EngineGeodesy.projectToLocalMeters(
                latitude: point.latitude,
                longitude: point.longitude,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude
            )
            assertParity(engine: engineValue.xMeters, swift: swiftReference.x, "\(label) x")
            assertParity(engine: engineValue.zMeters, swift: swiftReference.z, "\(label) z")
        }
    }

    func testProjectionCentreProducesExactlyZeroInBothImplementations() {
        let swiftReference = GeoDistance.latLonToMeters(
            lat: 1.352083,
            lon: 103.819836,
            centerLat: 1.352083,
            centerLon: 103.819836
        )
        let engineValue = EngineGeodesy.projectToLocalMeters(
            latitude: 1.352083,
            longitude: 103.819836,
            centerLatitude: 1.352083,
            centerLongitude: 103.819836
        )
        XCTAssertEqual(swiftReference.x, 0)
        XCTAssertEqual(swiftReference.z, 0)
        XCTAssertEqual(engineValue.xMeters, 0)
        XCTAssertEqual(engineValue.zMeters, 0)
    }

    // MARK: - Constants

    func testEarthRadiusConstantIsUnchanged() {
        XCTAssertEqual(GeoDistance.earthRadiusMeters, 6_371_000.0)
    }
}

/// The golden corpus: the established fixtures plus a reproducible seeded
/// corpus. It is the corpus of the former Swift-versus-C++ differential test.
extension RunPlayGeodesyBridgeTests {
    private typealias GeodesyPair = (Double, Double, Double, Double)
    private typealias GeodesyWords = (UInt64, UInt64, UInt64, UInt64)

    private static func words(_ pair: GeodesyPair) -> GeodesyWords {
        let (lat, lon, centerLat, centerLon) = pair
        let valid = EngineGeodesy.isValidCoordinate(latitude: lat, longitude: lon)
        let distance = EngineGeodesy.distanceMeters(
            latitude1: lat, longitude1: lon, latitude2: centerLat, longitude2: centerLon
        )
        let projection = EngineGeodesy.projectToLocalMeters(
            latitude: lat, longitude: lon, centerLatitude: centerLat, centerLongitude: centerLon
        )
        return (valid ? 1 : 0, distance.bitPattern, projection.xMeters.bitPattern, projection.zMeters.bitPattern)
    }

    private static func fixtures() -> [GeodesyPair] {
        var fixtures = distanceFixtures().map {
            ($0.first.latitude, $0.first.longitude, $0.second.latitude, $0.second.longitude)
        }
        for latitude in latitudeMatrix {
            for longitude in longitudeMatrix {
                fixtures.append((latitude, longitude, 1.352083, 103.819836))
            }
        }
        let small = Double.leastNonzeroMagnitude
        let mercator = 85.0511287798066
        fixtures += [
            (small, -small, -small, small),
            (0, 179.9995, 0, -179.9995),
            (90, 45, 90, -135),
            (-90, -180, 90, 180),
            (mercator.nextDown, 0, mercator, 0),
            (mercator, 0, mercator.nextUp, 0),
            (1, 1, .nan, 0),
            (1, 1, .infinity, 0),
            (1, 1, -.infinity, 0),
            (1, 1, 0, .infinity),
            (1, 1, 0, -.infinity),
            (1000, 4000, 0, 0),
        ]
        return fixtures
    }

    private static func seededPair(_ random: inout SplitMix64) -> GeodesyPair {
        func unit() -> Double { Double(random.next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
        return (unit() * 180.0 - 90.0, unit() * 360.0 - 180.0,
                unit() * 180.0 - 90.0, unit() * 360.0 - 180.0)
    }

    private static func append(_ result: GeodesyWords, to digest: inout FNV1a64) {
        digest.append(word: result.0)
        digest.append(word: result.1)
        digest.append(word: result.2)
        digest.append(word: result.3)
    }

    func testSwiftEngineGeodesyGolden() {
        var swiftDigest = FNV1a64()
        func record(_ pair: GeodesyPair) {
            Self.append(Self.words(pair), to: &swiftDigest)
        }
        let fixtures = Self.fixtures()
        swiftDigest.append(word: UInt64(fixtures.count))
        for pair in fixtures { record(pair) }

        var random = SplitMix64(seed: 0xa45e_8e75_7bc6_9c2e)
        // Prefix batch lengths so empty and one-element inputs are observable.
        // The kernel is scalar: these sizes do not imply a production buffer allocation.
        let ceiling = RunPlayEngineLimits.maxRouteInputSamples
        let batchSizes = [0, 1, 4_096, WorkoutImportResourceLimits.maxRoutePointCount, ceiling, ceiling + 1]
        for count in batchSizes {
            swiftDigest.append(word: UInt64(count))
            for _ in 0..<count {
                record(Self.seededPair(&random))
            }
        }

        if let golden = Self.golden {
            XCTAssertEqual(swiftDigest.value, golden)
        }
    }

    // Both values were derived from the C++ kernel before its removal; the
    // Swift kernel was asserted bit-identical to it on every pair.
    private static let golden: UInt64? = {
        #if os(macOS) && arch(arm64)
        // Captured from the former C++ kernel with Xcode 27.2 on arm64.
        0x9906_b023_91c7_8489
        #elseif os(Linux) && arch(x86_64)
        // Captured from the former C++ kernel in hosted Linux CI run 45273058519.
        0xc1b2_5289_5d30_ee7d
        #else
        nil
        #endif
    }()

    /// Fails when a platform condition leaves `golden` nil on a platform that
    /// pins it, which would otherwise make the golden test pass silently.
    func testGoldenIsPinnedOnPinnedPlatforms() {
        XCTAssertTrue(
            !GoldenPlatform.current.pinsKernelGoldens || Self.golden != nil,
            GoldenPlatform.unpinnedMessage("golden")
        )
    }
}

extension RunPlayGeodesyBridgeTests {
    func testSwiftEngineGeodesyKernelBenchmark() throws {
        guard ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RUNPLAY_BENCHMARK=1 via scripts/run-geodesy-benchmark.sh to measure the release kernels")
        }

        let includeProductLimit = ProcessInfo.processInfo.environment["RUNPLAY_BENCHMARK_PRODUCT_LIMIT"] == "1"
        let sizes = includeProductLimit ? [100_000, WorkoutImportResourceLimits.maxRoutePointCount] : [100_000]
        let clock = ContinuousClock()
        for size in sizes {
            var random = SplitMix64(seed: 0xae15_57f3_6c0f_12b8)
            let pairs = (0..<size).map { _ in Self.seededPair(&random) }
            func timed() -> (Double, UInt64) {
                var sink: UInt64 = 0
                let duration = clock.measure {
                    for pair in pairs {
                        let words = Self.words(pair)
                        sink &+= words.0 &+ words.1 &+ words.2 &+ words.3
                    }
                }
                let parts = duration.components
                return (Double(parts.seconds) * 1_000 + Double(parts.attoseconds) * 1e-15, sink)
            }
            let reference = timed().1
            XCTAssertEqual(timed().1, reference)
            var swiftTimes: [Double] = []
            for _ in 0..<9 {
                let run = timed()
                XCTAssertEqual(run.1, reference)
                swiftTimes.append(run.0)
            }
            let swiftMedian = swiftTimes.sorted()[4]
            print("Geodesy kernel-level: pairs=\(size) Swift=\(swiftMedian)ms")
        }
    }
}
