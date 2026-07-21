import XCTest
@testable import RunPlayCore

final class RouteMetricProfileTests: XCTestCase {
    private let builder = RouteMetricProfileBuilder()
    private let policy = RouteMetricColorPolicy.runningDefault

    // MARK: - Solid

    func testSolidModeNeedsNoMetricIntervals() throws {
        let workout = makeWorkout(pointCount: 20, paceSecondsPerKm: 300)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(
            workout: workout,
            context: context,
            mode: .solid
        )
        XCTAssertEqual(profile.mode, .solid)
        XCTAssertTrue(profile.intervals.isEmpty)
        XCTAssertNil(profile.scale)
    }

    // MARK: - Pace

    func testCleanPaceRouteProducesScaleAndBuckets() throws {
        let workout = makeWorkout(pointCount: 40, paceSecondsPerKm: 300, paceEnd: 420)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(workout: workout, context: context, mode: .pace)

        XCTAssertEqual(profile.mode, .pace)
        XCTAssertFalse(profile.intervals.isEmpty)
        XCTAssertNotNil(profile.scale)
        XCTAssertGreaterThan(profile.validCoverageDistanceMeters, 0)
        XCTAssertEqual(profile.diagnostics.bucketCount, 7)

        let levels = profile.intervals.compactMap { interval -> Int? in
            if case .level(let i) = interval.bucket { return i }
            return nil
        }
        XCTAssertFalse(levels.isEmpty)
        XCTAssertTrue(levels.contains { $0 == 0 } || levels.min()! < levels.max()!)
    }

    func testActivePaceExcludesRecordingPause() throws {
        // Continuous movement, then a pause with no distance, then resume.
        var points: [RoutePoint] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 10 points @ 5:00/km (300 s/km) for 1 km
        for i in 0..<10 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 30),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30,
                heartRateBPM: 140,
                routeSegmentIndex: 0
            ))
        }
        // Pause 5 minutes at same location (same distance, same segment — if
        // sanitizer keeps them). We model pause as zero-distance interval.
        let pauseStart = start.addingTimeInterval(9 * 30)
        points.append(RoutePoint(
            timestamp: pauseStart.addingTimeInterval(300),
            latitude: points.last!.latitude,
            longitude: points.last!.longitude,
            distanceFromStartMeters: points.last!.distanceFromStartMeters,
            elapsedSeconds: 9 * 30 + 300,
            heartRateBPM: 140,
            routeSegmentIndex: 0
        ))
        // Resume another 500 m
        let resumeBase = points.last!
        for i in 1...5 {
            points.append(RoutePoint(
                timestamp: resumeBase.timestamp.addingTimeInterval(Double(i) * 30),
                latitude: resumeBase.latitude + Double(i) * 0.0001,
                longitude: resumeBase.longitude,
                distanceFromStartMeters: resumeBase.distanceFromStartMeters + Double(i) * 100,
                elapsedSeconds: resumeBase.elapsedSeconds + Double(i) * 30,
                heartRateBPM: 140,
                routeSegmentIndex: 0
            ))
        }

        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(workout: workout, context: context, mode: .pace)

        // Zero-distance pause interval must not invent a pace value.
        let zeroDistance = profile.intervals.filter { $0.distanceMeters <= 0 || abs($0.endDistanceMeters - $0.startDistanceMeters) < 1e-9 }
        for interval in zeroDistance {
            XCTAssertNil(interval.metricValue)
            if case .noData = interval.bucket {
                // expected
            } else if interval.distanceMeters <= 0 {
                // intervals with zero distance may be omitted entirely
            }
        }

        // Valid pace values should be near 300 s/km, not inflated by the pause wall clock.
        let valid = profile.intervals.compactMap(\.metricValue)
        XCTAssertFalse(valid.isEmpty)
        for pace in valid {
            XCTAssertGreaterThan(pace, 200)
            XCTAssertLessThan(pace, 500)
        }
    }

    func testNoPaceAcrossRouteSegmentBoundary() throws {
        var points: [RoutePoint] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 30),
                latitude: 37.77 + Double(i) * 0.0001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 30,
                routeSegmentIndex: 0
            ))
        }
        // Gap: segment 1 continues with non-adjacent geometry
        for i in 0..<5 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(600 + Double(i) * 30),
                latitude: 37.78 + Double(i) * 0.0001,
                longitude: -122.43,
                distanceFromStartMeters: 400 + Double(i) * 100,
                elapsedSeconds: 600 + Double(i) * 30,
                routeSegmentIndex: 1
            ))
        }

        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(workout: workout, context: context, mode: .pace)

        // No interval may cross segments.
        for interval in profile.intervals {
            let startSeg = points[interval.startPointIndex].routeSegmentIndex
            let endSeg = points[interval.endPointIndex].routeSegmentIndex
            XCTAssertEqual(startSeg, endSeg)
            XCTAssertEqual(interval.routeSegmentIndex, startSeg)
        }

        // Adjacent pair at the gap (index 4→5) must not appear.
        let cross = profile.intervals.contains {
            $0.startPointIndex == 4 && $0.endPointIndex == 5
        }
        XCTAssertFalse(cross)
    }

    func testUnreasonablePaceRejected() throws {
        // Extremely fast fabricated pace via tiny time / large distance is hard
        // with timeline; use zero active by duplicate timestamps with distance.
        var points: [RoutePoint] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            points.append(RoutePoint(
                timestamp: start, // identical timestamps → zero active delta
                latitude: 37.77 + Double(i) * 0.001,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * 1000,
                elapsedSeconds: 0,
                routeSegmentIndex: 0
            ))
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(workout: workout, context: context, mode: .pace)

        for interval in profile.intervals {
            XCTAssertNil(interval.metricValue)
        }
    }

    func testDifferentSampleFrequenciesProduceSimilarScales() throws {
        let dense = makeWorkout(pointCount: 100, paceSecondsPerKm: 300, paceEnd: 400, stepMeters: 20)
        let sparse = makeWorkout(pointCount: 20, paceSecondsPerKm: 300, paceEnd: 400, stepMeters: 100)

        let denseProfile = try builder.build(
            workout: dense,
            context: WorkoutAnalysisContext(workout: dense),
            mode: .pace
        )
        let sparseProfile = try builder.build(
            workout: sparse,
            context: WorkoutAnalysisContext(workout: sparse),
            mode: .pace
        )

        guard let d = denseProfile.scale, let s = sparseProfile.scale else {
            return XCTFail("Expected scales")
        }
        // Distance-weighted scales should be within ~15% relative.
        XCTAssertEqual(d.median / s.median, 1, accuracy: 0.15)
        XCTAssertEqual(d.lowerBound / s.lowerBound, 1, accuracy: 0.2)
        XCTAssertEqual(d.upperBound / s.upperBound, 1, accuracy: 0.2)
    }

    // MARK: - Heart rate

    func testHeartRateFullCoverage() throws {
        let workout = makeWorkout(pointCount: 30, paceSecondsPerKm: 320, hrStart: 130, hrEnd: 170)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .heartRate
        )
        XCTAssertNotNil(profile.scale)
        XCTAssertGreaterThan(profile.validCoverageFraction, 0.9)
        XCTAssertEqual(profile.scale?.direction, .higherIsMore)
    }

    func testHeartRateMissingIntervalRemainsNil() throws {
        var points = makePoints(pointCount: 20, paceSecondsPerKm: 320, hrStart: 140, hrEnd: 160)
        // Clear HR in the middle
        for i in 8..<12 {
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                altitudeMeters: points[i].altitudeMeters,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                heartRateBPM: nil,
                routeSegmentIndex: points[i].routeSegmentIndex
            )
        }
        let workout = RunWorkout(routePoints: points)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .heartRate
        )

        let middle = profile.intervals.filter { $0.startPointIndex >= 8 && $0.endPointIndex <= 12 }
        // At least some middle intervals should be no-data (not median-filled).
        let noData = middle.filter {
            if case .noData = $0.bucket { return true }
            return false
        }
        XCTAssertFalse(noData.isEmpty, "Missing HR must remain no-data, not median-filled")
        for interval in noData {
            XCTAssertNil(interval.metricValue)
        }
    }

    func testInvalidHRRejected() throws {
        var points = makePoints(pointCount: 10, paceSecondsPerKm: 300)
        for i in points.indices {
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                heartRateBPM: 500, // invalid
                routeSegmentIndex: 0
            )
        }
        let workout = RunWorkout(routePoints: points)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .heartRate
        )
        XCTAssertNil(profile.scale)
        XCTAssertEqual(profile.diagnostics.validIntervalCount, 0)
    }

    // MARK: - Elevation

    func testCorrectedElevationUsedNotRaw() throws {
        // Build points with raw altitude spikes; ElevationProfile corrects them.
        var points = makePoints(pointCount: 30, paceSecondsPerKm: 300)
        for i in points.indices {
            let base = 100.0 + Double(i)
            // Spike at one index
            let alt = i == 15 ? 900.0 : base
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                altitudeMeters: alt,
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                routeSegmentIndex: 0
            )
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let profile = try builder.build(workout: workout, context: context, mode: .correctedElevation)

        guard let scale = profile.scale else {
            // If elevation profile rejects too much, scale may be nil — still
            // must not use raw 900 as a bound if we have a scale from corrected.
            return
        }
        // Corrected profile should not put 900 in the upper quantile for a
        // gentle climb. Allow some margin but far below the spike.
        XCTAssertLessThan(scale.upperBound, 400)
    }

    func testBelowSeaLevelElevationRetained() throws {
        var points = makePoints(pointCount: 20, paceSecondsPerKm: 300)
        for i in points.indices {
            points[i] = RoutePoint(
                id: points[i].id,
                timestamp: points[i].timestamp,
                latitude: points[i].latitude,
                longitude: points[i].longitude,
                altitudeMeters: -20 + Double(i), // below sea level rising
                distanceFromStartMeters: points[i].distanceFromStartMeters,
                elapsedSeconds: points[i].elapsedSeconds,
                routeSegmentIndex: 0
            )
        }
        let workout = RunWorkout(routePoints: points)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .correctedElevation
        )
        if let scale = profile.scale {
            XCTAssertLessThan(scale.lowerBound, 0)
        }
        let values = profile.intervals.compactMap(\.metricValue)
        XCTAssertTrue(values.contains { $0 < 0 })
    }

    func testMissingCorrectedElevationIsNoData() throws {
        // No altitude data
        let workout = makeWorkout(pointCount: 15, paceSecondsPerKm: 300)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .correctedElevation
        )
        // Without altitudes, elevation mode has no scale.
        XCTAssertNil(profile.scale)
        for interval in profile.intervals {
            XCTAssertNil(interval.metricValue)
            if case .noData = interval.bucket {
                // ok
            } else {
                XCTFail("Expected noData bucket")
            }
        }
    }

    func testElevationBelowMinimumScaleSpanIsUnavailable() throws {
        var points = makePoints(pointCount: 20, paceSecondsPerKm: 300)
        for index in points.indices {
            points[index] = RoutePoint(
                id: points[index].id,
                timestamp: points[index].timestamp,
                latitude: points[index].latitude,
                longitude: points[index].longitude,
                altitudeMeters: 50 + Double(index) * 0.01,
                distanceFromStartMeters: points[index].distanceFromStartMeters,
                elapsedSeconds: points[index].elapsedSeconds,
                routeSegmentIndex: points[index].routeSegmentIndex
            )
        }
        let workout = RunWorkout(routePoints: points)
        let context = WorkoutAnalysisContext(workout: workout)
        let strictPolicy = RouteMetricColorPolicy(minimumElevationSpanMeters: 5)

        let profile = try builder.build(
            workout: workout,
            context: context,
            mode: .correctedElevation,
            policy: strictPolicy
        )
        let availability = try builder.availability(
            routePoints: points,
            context: context,
            policy: strictPolicy
        )

        XCTAssertNil(profile.scale)
        XCTAssertFalse(availability.correctedElevation)
        XCTAssertTrue(profile.intervals.allSatisfy { $0.bucket == .noData })
    }

    func testNonMeaningfulCorrectedElevationProfileProducesNoData() throws {
        var points = makePoints(pointCount: 3, paceSecondsPerKm: 300)
        for index in points.indices {
            points[index] = RoutePoint(
                id: points[index].id,
                timestamp: points[index].timestamp,
                latitude: points[index].latitude,
                longitude: points[index].longitude,
                altitudeMeters: 100 + Double(index) * 10,
                distanceFromStartMeters: points[index].distanceFromStartMeters,
                elapsedSeconds: points[index].elapsedSeconds,
                routeSegmentIndex: points[index].routeSegmentIndex
            )
        }
        let elevation = ElevationProfile(
            routePoints: points,
            policy: RouteQualityPolicy(minimumReliableAltitudeSampleCount: 4)
        )
        XCTAssertFalse(elevation.hasMeaningfulElevation)
        XCTAssertEqual(elevation.samples.compactMap(\.correctedAltitudeMeters).count, points.count)

        let context = WorkoutAnalysisContext(routePoints: points, elevationProfile: elevation)
        let profile = try builder.build(
            routePoints: points,
            context: context,
            mode: .correctedElevation
        )
        let availability = try builder.availability(
            routePoints: points,
            context: context
        )

        XCTAssertNil(profile.scale)
        XCTAssertEqual(profile.validCoverageDistanceMeters, 0)
        XCTAssertTrue(profile.intervals.allSatisfy { $0.bucket == .noData })
        XCTAssertFalse(availability.correctedElevation)
    }

    // MARK: - Statistics & buckets

    func testWeightedQuantilesIgnoreZeroDistance() {
        let samples: [DistanceWeightedStatistics.WeightedSample] = [
            .init(value: 100, weight: 0),
            .init(value: 200, weight: 10),
            .init(value: 300, weight: 10),
        ]
        let median = DistanceWeightedStatistics.weightedMedian(samples)
        XCTAssertNotNil(median)
        // Discrete CDF median lands on the first sample that accumulates half weight.
        XCTAssertEqual(median!, 200, accuracy: 0.01)
        // Zero-weight outlier is ignored entirely.
        let onlyValid = DistanceWeightedStatistics.weightedQuantile(
            [.init(value: 100, weight: 0), .init(value: 400, weight: 5)],
            quantile: 0.5
        )
        XCTAssertEqual(onlyValid!, 400, accuracy: 0.01)
    }

    func testWeightedQuantileRejectsNonFiniteQuantile() {
        let samples: [DistanceWeightedStatistics.WeightedSample] = [
            .init(value: 100, weight: 5),
            .init(value: 200, weight: 5),
        ]
        XCTAssertNil(DistanceWeightedStatistics.weightedQuantile(samples, quantile: .nan))
        XCTAssertNil(DistanceWeightedStatistics.weightedQuantile(samples, quantile: .infinity))
        XCTAssertNil(DistanceWeightedStatistics.weightedQuantile(samples, quantile: -.infinity))
    }

    func testWeightedQuantileAvoidsFiniteWeightOverflow() {
        let samples: [DistanceWeightedStatistics.WeightedSample] = [
            .init(value: 100, weight: .greatestFiniteMagnitude),
            .init(value: 200, weight: .greatestFiniteMagnitude),
        ]

        XCTAssertEqual(
            DistanceWeightedStatistics.weightedQuantile(samples, quantile: 0.5),
            100
        )
        XCTAssertEqual(
            DistanceWeightedStatistics.weightedQuantile(samples, quantile: 0.9),
            200
        )
    }

    func testOneValidIntervalScale() throws {
        // Only two points → one interval
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RoutePoint(
                timestamp: start,
                latitude: 37.77,
                longitude: -122.42,
                distanceFromStartMeters: 0,
                elapsedSeconds: 0,
                heartRateBPM: 150,
                routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: start.addingTimeInterval(300),
                latitude: 37.78,
                longitude: -122.42,
                distanceFromStartMeters: 1000,
                elapsedSeconds: 300,
                heartRateBPM: 150,
                routeSegmentIndex: 0
            ),
        ]
        let workout = RunWorkout(routePoints: points)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .pace
        )
        XCTAssertNotNil(profile.scale)
        XCTAssertEqual(profile.intervals.count, 1)
    }

    func testEqualValuedScaleSafe() throws {
        let workout = makeWorkout(pointCount: 20, paceSecondsPerKm: 300, paceEnd: 300)
        let profile = try builder.build(
            workout: workout,
            context: WorkoutAnalysisContext(workout: workout),
            mode: .pace
        )
        guard let scale = profile.scale else {
            return XCTFail("Expected scale")
        }
        for interval in profile.intervals {
            if let n = interval.normalizedValue {
                XCTAssertGreaterThanOrEqual(n, 0)
                XCTAssertLessThanOrEqual(n, 1)
            }
        }
        _ = scale
    }

    func testBucketNormalizationClamps() {
        let scale = RouteMetricScale(
            lowerBound: 100,
            median: 150,
            upperBound: 200,
            lowerLabel: "a",
            medianLabel: "b",
            upperLabel: "c",
            direction: .higherIsMore
        )
        XCTAssertEqual(builder.normalize(value: 50, scale: scale), 0, accuracy: 1e-9)
        XCTAssertEqual(builder.normalize(value: 250, scale: scale), 1, accuracy: 1e-9)
        XCTAssertEqual(builder.bucketIndex(normalized: 0, bucketCount: 7), 0)
        XCTAssertEqual(builder.bucketIndex(normalized: 1, bucketCount: 7), 6)
    }

    func testDeterministicResult() throws {
        let workout = makeWorkout(pointCount: 50, paceSecondsPerKm: 280, paceEnd: 400, hrStart: 120, hrEnd: 160)
        let context = WorkoutAnalysisContext(workout: workout)
        let a = try builder.build(workout: workout, context: context, mode: .pace)
        let b = try builder.build(workout: workout, context: context, mode: .pace)
        XCTAssertEqual(a, b)
    }

    func testCancellationThrows() {
        let workout = makeWorkout(pointCount: 5_000, paceSecondsPerKm: 300, paceEnd: 400)
        let context = WorkoutAnalysisContext(workout: workout)
        let counter = CancellationCounter()
        XCTAssertThrowsError(
            try builder.build(
                workout: workout,
                context: context,
                mode: .pace,
                isCancelled: { counter.shouldCancel(after: 2) }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private final class CancellationCounter: @unchecked Sendable {
        private var calls = 0
        private let lock = NSLock()
        func shouldCancel(after threshold: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls > threshold
        }
    }

    func testLargeRouteBoundedWork() throws {
        // 100k points: exercise O(n) smoothing/scale without movement analysis.
        let points = makePoints(pointCount: 100_000, paceSecondsPerKm: 300, paceEnd: 450, stepMeters: 5)
        // ElevationProfile with nil altitudes stays cheap enough for this size.
        let elevation = ElevationProfile(routePoints: points)
        let context = WorkoutAnalysisContext(
            routePoints: points,
            elevationProfile: elevation,
            movementProfile: nil
        )
        let started = Date()
        let profile = try builder.build(
            routePoints: points,
            context: context,
            mode: .pace
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(profile.intervals.count, 99_999)
        XCTAssertNotNil(profile.scale)
        XCTAssertLessThanOrEqual(profile.diagnostics.bucketCount, 7)
        // Bound wall time so quadratic regressions fail CI.
        XCTAssertLessThan(elapsed, 15.0, "Pace profile for 100k points should finish under 15s")
    }

    // MARK: - Availability

    func testAvailabilityFlags() throws {
        let withHR = makeWorkout(pointCount: 30, paceSecondsPerKm: 300, hrStart: 130, hrEnd: 160)
        let availability = try builder.availability(
            routePoints: withHR.routePoints,
            context: WorkoutAnalysisContext(workout: withHR)
        )
        XCTAssertTrue(availability.solid)
        XCTAssertTrue(availability.pace)
        XCTAssertTrue(availability.heartRate)
    }

    // MARK: - Fixtures

    private func makeWorkout(
        pointCount: Int,
        paceSecondsPerKm: Double,
        paceEnd: Double? = nil,
        hrStart: Double? = nil,
        hrEnd: Double? = nil,
        stepMeters: Double = 50
    ) -> RunWorkout {
        RunWorkout(routePoints: makePoints(
            pointCount: pointCount,
            paceSecondsPerKm: paceSecondsPerKm,
            paceEnd: paceEnd,
            hrStart: hrStart,
            hrEnd: hrEnd,
            stepMeters: stepMeters
        ))
    }

    private func makePoints(
        pointCount: Int,
        paceSecondsPerKm: Double,
        paceEnd: Double? = nil,
        hrStart: Double? = nil,
        hrEnd: Double? = nil,
        stepMeters: Double = 50
    ) -> [RoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        var elapsed = 0.0
        for i in 0..<pointCount {
            let t = Double(i) / Double(max(1, pointCount - 1))
            let pace = paceSecondsPerKm + ((paceEnd ?? paceSecondsPerKm) - paceSecondsPerKm) * t
            if i > 0 {
                elapsed += (stepMeters / 1000.0) * pace
            }
            let hr: Double?
            if let hrStart {
                let end = hrEnd ?? hrStart
                hr = hrStart + (end - hrStart) * t
            } else {
                hr = nil
            }
            // Move north approximately stepMeters
            let lat = 37.77 + (Double(i) * stepMeters) / 111_320.0
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(elapsed),
                latitude: lat,
                longitude: -122.42,
                distanceFromStartMeters: Double(i) * stepMeters,
                elapsedSeconds: elapsed,
                paceSecondsPerKilometer: pace,
                heartRateBPM: hr,
                routeSegmentIndex: 0
            ))
        }
        return points
    }
}
