import Foundation
import XCTest
@testable import RunPlayCore

/// Elevation analysis reads a point's DEM elevation in place of its recorded
/// altitude, and a switch between the two sources ends one elevation run and
/// starts the next, so the offset between sources never becomes ascent,
/// descent, or a climb highlight.
final class ElevationProfileDEMSourceTests: XCTestCase {
    func testDEMElevationIsTheAnalysedAltitudeWhereverPresent() {
        let points = makePoints(count: 40) { index in
            (recorded: 100 + Double(index), dem: (10..<30).contains(index) ? 500 : nil)
        }
        let profile = ElevationProfile(routePoints: points)

        for (index, sample) in profile.samples.enumerated() {
            let fromDEM = (10..<30).contains(index)
            XCTAssertEqual(sample.sourceAltitudeIsDEM, fromDEM, "point \(index)")
            if fromDEM {
                XCTAssertEqual(sample.correctedAltitudeMeters, 500, "point \(index)")
            } else {
                XCTAssertEqual(try XCTUnwrap(sample.correctedAltitudeMeters), 100 + Double(index), accuracy: 1)
            }
        }
        XCTAssertEqual(profile.sourceCounts, ElevationSourceCounts(demPointCount: 20, recordedPointCount: 20))
    }

    func testNonFiniteDEMReadsAsAbsent() {
        let points = makePoints(count: 12) { index in
            (recorded: index == 4 ? nil : 100, dem: [Double.nan, .infinity, -.infinity][index % 3])
        }
        let profile = ElevationProfile(routePoints: points)

        XCTAssertFalse(profile.samples.contains(where: \.sourceAltitudeIsDEM))
        XCTAssertEqual(profile.sourceCounts, ElevationSourceCounts(demPointCount: 0, recordedPointCount: 11))
        XCTAssertEqual(profile.samples[0].correctedAltitudeMeters, 100)
    }

    /// The step between recorded altitude at 100 m and DEM at 130 m is 30 m
    /// either way; only a single-source route may count it.
    func testASourceSwitchEndsTheRunSoTheStepIsNotAscent() throws {
        let demPlateau = makePoints(count: 60) { index in
            (recorded: 100, dem: (20..<40).contains(index) ? 130 : nil)
        }
        let profile = ElevationProfile(routePoints: demPlateau)
        XCTAssertTrue(profile.hasMeaningfulElevation)
        XCTAssertEqual(profile.totalAscentMeters, 0)
        XCTAssertEqual(profile.totalDescentMeters, 0)

        let distance = { (index: Int) in demPlateau[index].distanceFromStartMeters }
        XCTAssertFalse(profile.hasContinuousReliableElevation(from: distance(10), to: distance(30)))
        XCTAssertTrue(profile.hasContinuousReliableElevation(from: distance(21), to: distance(38)))
        XCTAssertNil(
            profile.correctedAltitude(atDistance: (distance(19) + distance(20)) / 2),
            "no interpolation across the switch"
        )

        let recordedPlateau = makePoints(count: 60) { index in
            (recorded: (20..<40).contains(index) ? 130 : 100, dem: nil)
        }
        let recorded = ElevationProfile(routePoints: recordedPlateau)
        XCTAssertEqual(try XCTUnwrap(recorded.totalAscentMeters), 30, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(recorded.totalDescentMeters), 30, accuracy: 0.5)
    }

    /// Where DEM ends and recorded altitude 30 m higher takes over, a climb
    /// window must not find a 30 m climb; the same altitudes from one source
    /// are a real climb.
    func testBiggestClimbIgnoresTheStepAtASourceSwitch() throws {
        let switched = makeWorkout(count: 201) { index in
            (recorded: 100, dem: index <= 100 ? 70 : nil)
        }
        let switchedSegments = SegmentDetector.detectSegments(from: switched)
        XCTAssertFalse(switchedSegments.contains { $0.type == .biggestClimb })
        XCTAssertFalse(switchedSegments.contains { $0.type == .biggestDescent })

        let singleSource = makeWorkout(count: 201) { index in
            (recorded: index <= 100 ? 70 : 100, dem: nil)
        }
        let climb = try XCTUnwrap(SegmentDetector.detectSegments(from: singleSource).first { $0.type == .biggestClimb })
        XCTAssertEqual(try XCTUnwrap(climb.elevationDeltaMeters), 30, accuracy: 0.5)
    }

    /// The source rule is an input mapping and nothing more: a route with DEM
    /// builds the same profile as the independent pre-migration oracle on a
    /// copy whose altitude is the analysed one and whose route segment breaks
    /// wherever a segment or the altitude source changes.
    func testDEMRoutesMatchTheOracleOnSubstitutedAltitudeAndSplitSegments() throws {
        var random = DemSplitMix64(seed: 0xD3_5EED)
        for fixture in 0..<400 {
            let points = randomRoute(&random)
            let native = try RunPlayElevationProfileBridge.build(
                routePoints: points,
                policy: .runningDefault,
                isCancelled: { false }
            )
            let oracle = SwiftElevationProfileOracle.build(routePoints: Self.oracleInput(points))

            XCTAssertEqual(native.rejectedAltitudeCount, oracle.rejectedAltitudeCount, "fixture \(fixture)")
            XCTAssertEqual(native.hasMeaningfulElevation, oracle.hasMeaningfulElevation, "fixture \(fixture)")
            XCTAssertTrue(Self.near(native.totalAscentMeters, oracle.totalAscentMeters), "fixture \(fixture)")
            XCTAssertTrue(Self.near(native.totalDescentMeters, oracle.totalDescentMeters), "fixture \(fixture)")
            for (index, (built, expected)) in zip(native.samples, oracle.samples).enumerated() {
                let label = "fixture \(fixture) point \(index)"
                XCTAssertTrue(Self.near(built.correctedAltitudeMeters, expected.correctedAltitudeMeters), label)
                XCTAssertEqual(built.sourceAltitudeWasRejected, expected.sourceAltitudeWasRejected, label)
                XCTAssertTrue(Self.near(built.cumulativeAscentMeters, expected.cumulativeAscentMeters), label)
                XCTAssertTrue(Self.near(built.cumulativeDescentMeters, expected.cumulativeDescentMeters), label)
                XCTAssertTrue(Self.near(built.cumulativeSignedChangeMeters, expected.cumulativeSignedChangeMeters), label)
                XCTAssertEqual(built.reliableIntervalCount, expected.reliableIntervalCount, label)
                XCTAssertEqual(built.runIdentifier, expected.runIdentifier, label)
                XCTAssertEqual(built.reliableRunIdentifier, expected.reliableRunIdentifier, label)
            }
        }
    }

    // MARK: - Helpers

    private func makePoints(
        count: Int,
        spacing: Double = 10,
        altitudes: (Int) -> (recorded: Double?, dem: Double?)
    ) -> [RoutePoint] {
        (0..<count).map { index in
            let values = altitudes(index)
            let distance = Double(index) * spacing
            return RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + distance / 3),
                latitude: 46.44 + distance / 111_000,
                longitude: 7.3,
                altitudeMeters: values.recorded,
                demAltitudeMeters: values.dem,
                distanceFromStartMeters: distance,
                elapsedSeconds: distance / 3,
                speedMetersPerSecond: 3,
                paceSecondsPerKilometer: 1_000 / 3.0
            )
        }
    }

    private func makeWorkout(
        count: Int,
        altitudes: (Int) -> (recorded: Double?, dem: Double?)
    ) -> RunWorkout {
        RunWorkout(
            metadata: WorkoutMetadata(name: "Source switch"),
            source: .fit,
            routePoints: makePoints(count: count, altitudes: altitudes)
        )
    }

    private func randomRoute(_ random: inout DemSplitMix64) -> [RoutePoint] {
        let count = 3 + random.nextInt(below: 118)
        var points: [RoutePoint] = []
        var distance = 0.0
        var segment = 0
        var recorded = random.nextDouble(in: 0...2_000)
        var usesDEM = random.nextBool(probability: 0.5)
        for index in 0..<count {
            if index > 0, random.nextBool(probability: 0.03) { segment += 1 }
            if random.nextBool(probability: 0.12) { usesDEM.toggle() }
            distance += random.nextBool(probability: 0.05) ? 0 : random.nextDouble(in: 0.5...40)
            recorded += random.nextDouble(in: -6...6)

            var altitude: Double? = recorded
            if random.nextBool(probability: 0.06) { altitude = nil }
            if random.nextBool(probability: 0.03) { altitude = .nan }
            if random.nextBool(probability: 0.04) { altitude = recorded + random.nextDouble(in: -200...200) }

            var dem: Double?
            if usesDEM {
                dem = recorded + random.nextDouble(in: -40...40)
                if random.nextBool(probability: 0.03) { dem = .infinity }
                if random.nextBool(probability: 0.03) { dem = 12_000 }
            } else if random.nextBool(probability: 0.02) {
                dem = .nan
            }
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)),
                latitude: 46.44,
                longitude: 7.3,
                altitudeMeters: altitude,
                demAltitudeMeters: dem,
                distanceFromStartMeters: distance,
                routeSegmentIndex: segment
            ))
        }
        return points
    }

    /// The analysed altitude as recorded altitude, and a new route segment at
    /// every segment or source change; no DEM field.
    private static func oracleInput(_ points: [RoutePoint]) -> [RoutePoint] {
        var group = 0
        var mapped: [RoutePoint] = []
        for (index, point) in points.enumerated() {
            let dem = point.demAltitudeMeters.flatMap { $0.isFinite ? $0 : nil }
            if index > 0 {
                let previous = points[index - 1]
                let previousDEM = previous.demAltitudeMeters.map(\.isFinite) ?? false
                if point.routeSegmentIndex != previous.routeSegmentIndex || (dem != nil) != previousDEM {
                    group += 1
                }
            }
            var copy = point
            copy.altitudeMeters = dem ?? point.altitudeMeters
            copy.demAltitudeMeters = nil
            copy.routeSegmentIndex = group
            mapped.append(copy)
        }
        return mapped
    }

    private static func near(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return near(a, b)
        default: return false
        }
    }

    private static func near(_ a: Double, _ b: Double) -> Bool {
        a == b || abs(a - b) <= max(1e-9, abs(b) * 1e-12)
    }
}
