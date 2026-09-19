import XCTest
@testable import RunPlayCore

/// Personal-record window detection, aggregation, persistence, and backfill.
///
/// All fixtures are synthetic constant-pace routes; no real workout data.
final class PersonalRecordsTests: XCTestCase {

    // MARK: - Fixtures

    /// Constant-pace synthetic route. `pauseAtDistance` inserts a recording
    /// gap at that distance: a plateau point in the next route segment whose
    /// elapsed clock jumps by `pauseDuration` while distance holds.
    private func makeRoute(
        totalDistance: Double,
        interval: Double = 100,
        secondsPerMeter: Double = 0.25,
        pauseAtDistance: Double? = nil,
        pauseDuration: Double = 500,
        start: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> [RoutePoint] {
        var points: [RoutePoint] = []
        var segment = 0
        var elapsed = 0.0
        var distance = 0.0
        while distance <= totalDistance {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 1,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                routeSegmentIndex: segment
            ))
            if distance == pauseAtDistance, distance < totalDistance {
                elapsed += pauseDuration
                segment += 1
                points.append(RoutePoint(
                    timestamp: start.addingTimeInterval(elapsed),
                    latitude: 1 + distance / 100_000,
                    longitude: 1,
                    distanceFromStartMeters: distance,
                    elapsedSeconds: elapsed,
                    routeSegmentIndex: segment
                ))
            }
            distance += interval
            elapsed += interval * secondsPerMeter
        }
        return points
    }

    private func detectRecords(_ points: [RoutePoint]) -> WorkoutPersonalRecords {
        let context = WorkoutAnalysisContext(
            routePoints: points,
            elevationProfile: ElevationProfile(routePoints: points)
        )
        return SegmentDetector.detectPersonalRecords(
            from: RunWorkout(routePoints: points),
            context: context
        )
    }

    // MARK: - Detection

    func testMarathonRouteAttemptsAllWindowsWithExactLengths() {
        let records = detectRecords(makeRoute(totalDistance: 43_000))
        let categories = Set(records.windows.map(\.category))
        XCTAssertEqual(categories, [
            .fastest400m, .fastest1km, .fastest1mile, .fastest5km,
            .fastest10km, .fastestHalfMarathon, .fastestMarathon
        ])
        for window in records.windows {
            let nominal = window.category.nominalWindowDistanceMeters
            XCTAssertEqual(
                window.endDistanceMeters - window.startDistanceMeters,
                nominal,
                "\(window.category.displayName) window must cover its nominal length exactly"
            )
            XCTAssertEqual(
                window.paceSecondsPerKilometer, 250, accuracy: 1e-6,
                "\(window.category.displayName) constant-pace value"
            )
        }
    }

    func testWindowsLongerThanRouteAreNotAttempted() {
        let records = detectRecords(makeRoute(totalDistance: 4_000))
        let categories = Set(records.windows.map(\.category))
        XCTAssertEqual(categories, [.fastest400m, .fastest1km, .fastest1mile])
        // Not attempted means absent, never a zero-valued placeholder.
        for window in records.windows {
            XCTAssertGreaterThan(window.paceSecondsPerKilometer, 0)
        }
    }

    func testRecordWindowSpanningPauseUsesActiveTime() {
        // Pause at 2 km so the first (tie-winning) 5 km window spans it.
        // Active pace is 250 s/km; elapsed pace would be far slower.
        let points = makeRoute(totalDistance: 5_000, pauseAtDistance: 2_000)
        let records = detectRecords(points)
        let window = records.window(for: .fastest5km)
        XCTAssertNotNil(window, "5 km record should be attempted")
        guard let window else { return }
        XCTAssertEqual(window.paceSecondsPerKilometer, 250, accuracy: 1e-6,
                       "pause time must not count toward record pace")
        let elapsedSpan = window.endElapsedSeconds - window.startElapsedSeconds
        XCTAssertGreaterThan(elapsedSpan, window.activeSeconds,
                             "elapsed span includes the pause; active time excludes it")
        XCTAssertEqual(window.activeSeconds, 1_250, accuracy: 1e-6,
                       "5 km at 250 s/km is 1,250 active seconds")
    }

    func testMileAndOneKilometerWindowsOverlapAndPickDifferentStarts() {
        // The bridge parity tests compare only the five segment kinds, so the
        // dedicated record tests alone must prove the overlapping windows
        // search independently. Three speed sections over 3 km — 260, 240,
        // and 270 s/km — make the fast block exactly 1 km: the 1 km record
        // sits inside it (start 1 km), while the mile must cover the whole
        // fast block plus both slow sides and starts earlier (400 m, where
        // the cheaper leading slow section wins). The two windows overlap
        // between 1.0 km and 2.009 km.
        let sections: [(end: Double, secondsPerMeter: Double)] = [
            (1_000, 0.26), (2_000, 0.24), (3_000, 0.27)
        ]
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        var elapsed = 0.0
        for index in 0...30 {
            let distance = Double(index) * 100
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: 1 + distance / 100_000,
                longitude: 1,
                distanceFromStartMeters: distance,
                elapsedSeconds: elapsed,
                routeSegmentIndex: 0
            ))
            if index < 30 {
                let speed = sections.first { distance < $0.end }!.secondsPerMeter
                elapsed += 100 * speed
            }
        }

        let records = detectRecords(points)
        let oneKm = records.window(for: .fastest1km)
        let mile = records.window(for: .fastest1mile)
        XCTAssertNotNil(oneKm)
        XCTAssertNotNil(mile)
        guard let oneKm, let mile else { return }

        // The 1 km record is the fast block itself: exactly 240 s/km.
        XCTAssertEqual(oneKm.startDistanceMeters, 1_000, accuracy: 1e-9)
        XCTAssertEqual(oneKm.paceSecondsPerKilometer, 240, accuracy: 1e-9)

        // The mile starts at 400 m: 600 m at 260, the full fast kilometre,
        // and 9.344 m at 270 = 398.52288 s over 1'609.344 m.
        XCTAssertEqual(mile.startDistanceMeters, 400, accuracy: 1e-9)
        XCTAssertEqual(
            mile.endDistanceMeters,
            400 + PersonalRecordCategory.fastest1mile.nominalWindowDistanceMeters!,
            accuracy: 1e-9
        )
        let expectedMilePace = 398.52288
            / PersonalRecordCategory.fastest1mile.nominalWindowDistanceMeters!
            * 1_000
        XCTAssertEqual(mile.paceSecondsPerKilometer, expectedMilePace, accuracy: 1e-6)

        // The windows overlap yet pick different starts.
        XCTAssertNotEqual(oneKm.startDistanceMeters, mile.startDistanceMeters)
        XCTAssertLessThan(mile.startDistanceMeters, oneKm.startDistanceMeters)
        XCTAssertLessThan(oneKm.startDistanceMeters, mile.endDistanceMeters)
        XCTAssertLessThan(oneKm.endDistanceMeters - 1e-9, 3_000)
    }

    func testSinglePointRouteProducesEmptyComputedRecords() {
        // Computed-with-nothing, not nil: the marker semantics distinguish
        // "attempted none" from "never computed".
        let records = detectRecords([
            RoutePoint(timestamp: Date(), latitude: 1, longitude: 1,
                       distanceFromStartMeters: 0, elapsedSeconds: 0)
        ])
        XCTAssertTrue(records.windows.isEmpty)
    }
}
