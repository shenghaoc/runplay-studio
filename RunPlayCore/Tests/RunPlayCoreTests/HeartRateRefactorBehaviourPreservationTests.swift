import XCTest
@testable import RunPlayCore

/// Proves the heart-rate single-accessor refactor changes no computed value for
/// any existing workout.
///
/// The goldens in `HeartRateRefactorGoldens.swift` were captured at commit
/// `1f5ee25`, before the refactor, by running these exact fixtures through the
/// same public entry points used here. This suite is therefore expected to pass
/// **both** before and after the refactor; a failure after it means a value
/// moved, which is the whole thing this layer must not do.
///
/// That is a stronger claim than "the new tests pass". The refactor swaps the
/// route-point loops in the summary pass, the training-load interval builder
/// and the timeline's distance-range average for reads through one accessor.
/// Each of those is a place a subtle change — a different validation range, a
/// dropped boundary sample, an altered accumulation order — would silently shift
/// a number. Pinning the outputs is what makes the swap reviewable as
/// behaviour-preserving rather than as plausible.
///
/// Fixtures are chosen to cover the paths the refactor touches:
/// - A: steady measured run, the simplest accumulation.
/// - B: a segment boundary and nil readings, so the interval builder must drop
///   weight across the gap and keep gap *positions* for weighting.
/// - C: no heart rate at all, so the summary stays nil and the estimator runs.
/// - D: out-of-range, zero and duplicate-elapsed readings, pinning the
///   validation range and the duplicate-time handling.
/// - E: measured path *with* a recording gap — 1,200s of coverage clears both
///   measured thresholds, so this exercises same-segment interval construction
///   across two segments rather than falling back to the estimator.
/// - F: measured path with nil readings interspersed among valid ones, so
///   `intervalRate` is sometimes nil while weights still accrue.
/// - G: measured path with rates spread across all five zones (with maxHR 150
///   the zone lower bounds are 0/90/105/120/135), pinning zone bucketing.
final class HeartRateRefactorBehaviourPreservationTests: XCTestCase {

    private let profile = AthleteProfile(
        restingHeartRateBPM: 50,
        maximumHeartRateBPM: 150
    )

    private func point(
        elapsed: Double,
        rate: Double?,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + elapsed),
            latitude: 37,
            longitude: -122,
            altitudeMeters: 100,
            distanceFromStartMeters: 3 * elapsed,
            elapsedSeconds: elapsed,
            heartRateBPM: rate,
            routeSegmentIndex: segment
        )
    }

    /// The seven fixtures, keyed by the names the goldens use.
    private func fixtures() -> [(String, [RoutePoint])] {
        var a: [RoutePoint] = []
        for index in 0...40 {
            a.append(point(elapsed: Double(index) * 30, rate: 100))
        }

        let b = [
            point(elapsed: 0, rate: 100),
            point(elapsed: 600, rate: nil),
            point(elapsed: 1_200, rate: 120, segment: 0),
            point(elapsed: 3_000, rate: 130, segment: 1),
            point(elapsed: 3_600, rate: nil, segment: 1),
            point(elapsed: 4_200, rate: 140, segment: 1),
        ]

        var c: [RoutePoint] = []
        for index in 0...9 {
            c.append(point(elapsed: Double(index) * 60, rate: nil))
        }

        let d = [
            point(elapsed: 0, rate: 10),
            point(elapsed: 60, rate: 500),
            point(elapsed: 120, rate: 145.5),
            point(elapsed: 180, rate: 0),
            point(elapsed: 240, rate: 152.25),
            point(elapsed: 240, rate: 160, segment: 1),
            point(elapsed: 300, rate: 88, segment: 1),
        ]

        var e: [RoutePoint] = []
        for index in 0...19 {
            e.append(point(elapsed: Double(index) * 30, rate: 140, segment: 0))
        }
        for index in 20...39 {
            e.append(point(elapsed: 1_800 + Double(index - 20) * 30, rate: 155, segment: 1))
        }

        var f: [RoutePoint] = []
        for index in 0...39 {
            let rate: Double? = (index % 5 == 3) ? nil : 130 + Double(index % 7)
            f.append(point(elapsed: Double(index) * 30, rate: rate))
        }

        let gRates: [Double] = [85, 95, 110, 125, 140]
        var g: [RoutePoint] = []
        for index in 0...39 {
            g.append(point(elapsed: Double(index) * 30, rate: gRates[index % gRates.count]))
        }

        return [("A", a), ("B", b), ("C", c), ("D", d), ("E", e), ("F", f), ("G", g)]
    }

    // MARK: - Summary heart rate

    func testSummaryHeartRateIsUnchanged() {
        for (name, points) in fixtures() {
            let golden = BehaviourPreservationGoldens.summary[name]!
            var workout = RunWorkout(
                metadata: WorkoutMetadata(name: "golden-\(name)"),
                routePoints: points,
                summary: RunSummary(totalActiveSeconds: 0)
            )
            WorkoutAnalyzer().analyze(&workout)
            let summary = workout.summary

            XCTAssertEqual(
                summary.averageHeartRateBPM, golden.averageHeartRateBPM,
                "\(name): average heart rate moved"
            )
            XCTAssertEqual(
                summary.maxHeartRateBPM, golden.maxHeartRateBPM,
                "\(name): maximum heart rate moved"
            )
            XCTAssertEqual(
                summary.totalActiveSeconds, golden.totalActiveSeconds,
                "\(name): active seconds moved"
            )
            XCTAssertEqual(
                summary.totalDistanceMeters, golden.totalDistanceMeters,
                "\(name): distance moved"
            )
        }
    }

    // MARK: - Training load

    func testTrainingLoadIsUnchanged() throws {
        for (name, points) in fixtures() {
            let golden = BehaviourPreservationGoldens.load[name]!
            var workout = RunWorkout(
                metadata: WorkoutMetadata(name: "golden-\(name)"),
                routePoints: points,
                summary: RunSummary(totalActiveSeconds: 0)
            )
            WorkoutAnalyzer().analyze(&workout)
            let load = try XCTUnwrap(workout.trainingLoad, "\(name): no training load")

            XCTAssertEqual(load.kind, golden.kind, "\(name): measured/estimated decision moved")
            XCTAssertEqual(
                load.banisterTRIMP, golden.banisterTRIMP,
                accuracy: BehaviourPreservationGoldens.trimpAccuracy,
                "\(name): TRIMP moved beyond the libm tolerance"
            )
            XCTAssertEqual(load.meanHeartRateBPM, golden.meanHeartRateBPM, "\(name): mean heart rate moved")
            XCTAssertEqual(
                load.validHeartRateSeconds, golden.validHeartRateSeconds,
                "\(name): valid heart-rate seconds moved"
            )
            XCTAssertEqual(
                load.coveredActiveSeconds, golden.coveredActiveSeconds,
                "\(name): covered seconds moved"
            )
            XCTAssertEqual(load.estimateBasis, golden.estimateBasis, "\(name): estimate basis moved")
            XCTAssertEqual(
                load.assumedHeartRateReserve, golden.assumedHeartRateReserve,
                "\(name): assumed reserve moved"
            )

            // Zone bucketing: nil for estimated loads, five entries otherwise.
            switch (load.zoneSeconds, golden.zoneSeconds) {
            case (nil, nil):
                break
            case let (actual?, golden?):
                XCTAssertEqual(actual.count, golden.count, "\(name): zone count moved")
                for (index, value) in actual.enumerated() {
                    XCTAssertEqual(
                        value.bitPattern, golden[index].bitPattern,
                        "\(name): zone \(index + 1) seconds moved"
                    )
                }
            default:
                XCTFail("\(name): zone presence moved")
            }
        }
    }

    /// The measured-versus-estimated decision is the refactor's riskiest
    /// output: a single dropped interval can push coverage below the 0.5
    /// threshold and silently switch a run to an estimate. Assert which
    /// fixtures land on which path so a switch cannot pass unnoticed.
    func testMeasuredPathFixturesAreActuallyMeasured() throws {
        for (name, points) in fixtures() {
            var workout = RunWorkout(
                metadata: WorkoutMetadata(name: "golden-\(name)"),
                routePoints: points,
                summary: RunSummary(totalActiveSeconds: 0)
            )
            WorkoutAnalyzer().analyze(&workout)
            let load = try XCTUnwrap(workout.trainingLoad, "\(name): no training load")
            let expected = BehaviourPreservationGoldens.load[name]!.kind

            XCTAssertEqual(load.kind, expected, "\(name): expected \(expected)")
            if expected == .measured {
                XCTAssertNotNil(load.zoneSeconds, "\(name): measured load has no zones")
                XCTAssertGreaterThan(
                    load.validHeartRateSeconds,
                    TrainingLoadPolicy.minimumMeasuredValidHeartRateSeconds - 1,
                    "\(name): measured fixture sits at the coverage threshold"
                )
            }
        }
    }

    // MARK: - Timeline distance-range heart rate

    func testTimelineDistanceRangeHeartRateIsUnchanged() {
        for (name, points) in fixtures() {
            let golden = BehaviourPreservationGoldens.timeline[name]!
            let timeline = WorkoutTimeline(routePoints: points)

            XCTAssertEqual(
                timeline.totalDistanceMeters, golden.totalDistanceMeters,
                "\(name): total distance moved"
            )

            let total = golden.totalDistanceMeters
            for index in 0..<golden.quarters.count {
                let actual = timeline.averageHeartRate(
                    from: total * Double(index) / 4,
                    to: total * Double(index + 1) / 4
                )
                XCTAssertEqual(
                    actual, golden.quarters[index],
                    "\(name): quarter \(index + 1) average heart rate moved"
                )
            }

            XCTAssertEqual(
                timeline.averageHeartRate(from: 0, to: total),
                golden.whole,
                "\(name): whole-range average heart rate moved"
            )
            XCTAssertEqual(
                timeline.averageHeartRate(from: total, to: total * 2),
                golden.outOfBounds,
                "\(name): out-of-bounds average heart rate moved"
            )
        }
    }

    // MARK: - Legacy snapshot bytes

    /// A snapshot written before standalone heart rate existed must re-encode
    /// byte for byte identically: the new field is optional, absent keys decode
    /// to nil, and nil is omitted on encode. Without this, opening an existing
    /// library and saving it would rewrite every file.
    func testLegacySnapshotReEncodesWithoutTheNewKey() throws {
        let points = [
            point(elapsed: 0, rate: 120),
            point(elapsed: 30, rate: 128),
        ]
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "legacy"),
            routePoints: points,
            summary: RunSummary(totalDistanceMeters: 90, totalElapsedSeconds: 30)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let first = try encoder.encode(workout)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertFalse(
            text.contains("heartRateSeries"),
            "a workout with no standalone series must not emit the key"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunWorkout.self, from: first)
        let second = try encoder.encode(decoded)

        XCTAssertEqual(first, second, "legacy bytes are not stable across a decode/encode round trip")
    }
}
