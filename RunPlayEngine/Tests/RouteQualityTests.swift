import RunPlayEngine
import Testing

struct RouteQualityTests {
    private let policy = EngineRouteQualityPolicy(
        maximumRunningSpeed: 12, usefulAccuracy: 100,
        minimumSpikeExcess: 200, minimumSpikeDistortion: 3, poorAccuracyMultiplier: 0.5,
        minimumGapDistance: 200, minimumGapInterval: 120, minimumGapRatio: 3,
        confirmationCount: 3, maximumClusterStep: 200
    )

    private func sample(
        _ source: Int, _ latitude: Double, _ seconds: Double,
        supplied: Double = 0, segment: Int64 = 0, longitude: Double = 0,
        accuracy: Double? = nil, dem: Double? = nil
    ) -> EngineRouteInputSample {
        EngineRouteInputSample(
            sourceIndex: UInt64(source), timestampSecondsSinceReferenceDate: seconds,
            latitude: latitude, longitude: longitude, altitudeMeters: nil,
            demAltitudeMeters: dem, distanceFromStartMeters: supplied, elapsedSeconds: seconds,
            speedMetersPerSecond: nil, paceSecondsPerKilometer: nil, heartRateBPM: nil,
            cadence: nil, powerWatts: nil, groundContactTimeMilliseconds: nil,
            verticalOscillationMillimeters: nil, verticalRatioPercent: nil,
            stanceTimeBalancePercent: nil, stepLengthMeters: nil,
            horizontalAccuracy: accuracy, routeSegmentIndex: segment
        )
    }

    private func lat(_ metres: Double) -> Double { metres / 111_132 }

    private func oscillating(_ metres: [Double]) -> [EngineRouteInputSample] {
        metres.enumerated().map { sample($0.offset, lat($0.element), Double($0.offset)) }
    }

    private func process(
        _ samples: [EngineRouteInputSample],
        _ strategy: EngineRouteDistancePolicy = .coordinates,
        selection: [UInt8]? = nil,
        geometry: EngineRouteQualityPolicy? = nil
    ) throws(RouteQualityError) -> EngineRouteQualityResult {
        if let selection {
            return try EngineRouteQuality.process(
                samples.span, policy: geometry ?? policy, distancePolicy: strategy, selection: selection.span
            )
        }
        return try EngineRouteQuality.process(
            samples.span, policy: geometry ?? policy, distancePolicy: strategy, selection: nil
        )
    }

    @Test func test_empty_and_boundary_errors() throws {
        let empty = try process([])
        #expect(empty.samples.isEmpty)
        #expect(empty.totalDistance.bitPattern == 0)

        let one = sample(0, 0, 0)
        #expect(try process([one]).samples.count == 1)
        let oversized = Array(repeating: one, count: EngineRouteLimits.maxRouteInputSamples + 1)
        #expect(throws: RouteQualityError.resourceLimit) { try process(oversized) }

        var bad = policy
        bad.minimumSpikeDistortion = 0.5
        #expect(throws: RouteQualityError.invalidPolicy) { try process([one], geometry: bad) }
        #expect(throws: RouteQualityError.invalidInputContract) { try process([sample(0, 200, 0)]) }
    }

    @Test func test_ordinary_route_and_teleport() throws {
        let straight = (0..<5).map { sample(100 + $0, lat(100 * Double($0)), Double($0)) }
        let ordinary = try process(straight)
        #expect(ordinary.retainedCount == 5)
        #expect(ordinary.discardedCount == 0)
        #expect(ordinary.inferredGapCount == 0)
        #expect(ordinary.segmentCount == 1)
        #expect(ordinary.distanceSource == .coordinates)
        #expect(ordinary.samples[0].normalizedDistance.bitPattern == 0)
        #expect(abs(ordinary.samples[4].normalizedDistance - 400) <= 5)
        for (input, output) in zip(straight, ordinary.samples) {
            #expect(output.sourceIndex == input.sourceIndex)
            #expect(output.retained && !output.rejected)
        }

        let teleport = try process(oscillating([0, 10, 5_000, 20, 30]))
        #expect(teleport.retainedCount == 4)
        #expect(teleport.discardedCount == 1)
        #expect(teleport.inferredGapCount == 0)
        #expect(!teleport.samples[2].retained && teleport.samples[2].rejected)
        for index in [0, 1, 3, 4] { #expect(teleport.samples[index].retained) }
    }

    @Test func test_adjacent_candidates_and_endpoints() throws {
        let two = try process(oscillating([0, 0, 5_000, 0, 5_000, 5_000]))
        #expect(two.retainedCount == 6)
        #expect(two.discardedCount == 0)
        for index in 2...3 { #expect(two.samples[index].retained && !two.samples[index].rejected) }

        let three = try process(oscillating([0, 0, 5_000, 0, 5_000, 0, 0]))
        #expect(three.retainedCount == 7)
        #expect(three.discardedCount == 0)
        for index in 2...4 { #expect(three.samples[index].retained && !three.samples[index].rejected) }

        let isolated = try process(oscillating([0, 0, 5_000, 0, 0, 0]))
        #expect(isolated.discardedCount == 1)
        #expect(!isolated.samples[2].retained && isolated.samples[2].rejected)
    }

    @Test func test_gap_inference_and_segments() throws {
        let jump = lat(1_000)
        var samples = (0..<4).map { sample($0, lat(10 * Double($0)), Double($0)) }
        samples += (4..<8).map { sample($0, jump + lat(10 * Double($0 - 4)), Double($0)) }
        let result = try process(samples)
        #expect(result.inferredGapCount == 1)
        #expect(result.samples[4].inferredBoundary)
        #expect(result.segmentCount == 2)
        #expect(result.samples[0].normalizedSegmentIndex == 0)
        #expect(result.samples[4].normalizedSegmentIndex == 1)
        #expect(abs(result.samples[4].normalizedDistance - result.samples[3].normalizedDistance) <= 1e-9)
    }

    @Test func test_supplied_distance_policies() throws {
        var samples = (0..<4).map { sample($0, lat(100 * Double($0)), Double($0), supplied: 10 * Double($0)) }
        let supplied = try process(samples, .allSupplied)
        #expect(supplied.distanceSource == .supplied)
        #expect(abs(supplied.samples[3].normalizedDistance - 30) <= 1e-9)
        #expect(supplied.samples[1].distanceSource == .supplied)

        samples[2] = sample(2, lat(200), 2, supplied: -5)
        #expect(try process(samples, .allSupplied).distanceSource == .coordinates)
        samples = (0..<3).map { sample($0, lat(50 * Double($0)), Double($0), supplied: 5 * Double($0)) }
        // Explicit closure types and one step per line: Swift 6.3.3 cannot
        // type-check the single-expression form in reasonable time.
        samples += (0..<3).map { (index: Int) -> EngineRouteInputSample in
            let offset = Double(index)
            let latitude: Double = 1 + lat(50 * offset)
            let supplied: Double = index == 1 ? .nan : 5 * offset
            return sample(10 + index, latitude, 10 + offset, supplied: supplied, segment: 1)
        }
        let mixed = try process(samples, .suppliedPerSegment)
        #expect(mixed.distanceSource == .mixed)
        #expect(mixed.segmentCount == 2)
        #expect(mixed.samples[0].distanceSource == .supplied)
        #expect(mixed.samples[3].distanceSource == .coordinates)

        let selected = try process(samples, .suppliedForSelection, selection: [1, 1, 1, 0, 0, 0])
        #expect(selected.distanceSource == .mixed || selected.distanceSource == .supplied)
        #expect(selected.samples[0].distanceSource == .supplied)
        #expect(selected.samples[3].distanceSource == .coordinates)
        #expect(throws: RouteQualityError.invalidSelectionBuffer) {
            try process(samples, .suppliedForSelection, selection: [1])
        }
    }

    @Test func test_segment_contract_and_identity() throws {
        var samples = [sample(42, 0, 0), sample(7, lat(50), 1),
                       sample(99, 1, 2, segment: 1), sample(3, 1 + lat(50), 3, segment: 1)]
        let result = try process(samples)
        #expect(result.segmentCount == 2)
        #expect(result.samples.map(\.sourceIndex) == [42, 7, 99, 3])
        #expect(abs(result.samples[2].normalizedDistance - result.samples[1].normalizedDistance) <= 1e-9)
        samples[2] = sample(99, 1, 2, segment: 2)
        #expect(throws: RouteQualityError.invalidInputContract) { try process(samples) }
    }

    @Test func test_large_route() throws {
        let count = 100_000
        let samples = (0..<count).map {
            sample($0, lat(Double($0)), Double($0), segment: Int64($0 / 25_000), longitude: lat(Double($0)) * 0.01)
        }
        let result = try process(samples)
        #expect(result.samples.count == count)
        #expect(result.retainedCount == count)
        #expect(result.segmentCount == 4)
        #expect(result.samples[0].normalizedDistance.bitPattern == 0)
        #expect(result.samples[count - 1].normalizedDistance >= 0)
    }

    @Test func test_many_segments() throws {
        let count = 100_000
        let length = 100
        let samples = (0..<count).map {
            sample($0, lat(Double($0)), Double($0), supplied: Double($0 % length), segment: Int64($0 / length))
        }
        for strategy in [EngineRouteDistancePolicy.coordinates, .suppliedPerSegment, .allSupplied] {
            let result = try process(samples, strategy)
            #expect(result.retainedCount == count)
            #expect(result.segmentCount == count / length)
            #expect(result.samples[count - 1].normalizedSegmentIndex == Int64(count / length - 1))
            var previous = -1.0
            var monotone = true
            for entry in result.samples {
                monotone = monotone && entry.normalizedDistance >= previous
                previous = entry.normalizedDistance
            }
            #expect(monotone)
            #expect(result.samples[0].normalizedDistance.bitPattern == 0)
            #expect(result.distanceSource == (strategy == .coordinates ? .coordinates : .supplied))
        }
    }

    @Test func test_dem_altitude_is_never_read() throws {
        var rows: [(Double, Double, Double, Int64)] = []
        for i in 0..<6 { let p = Double(i); rows.append((10*p, p, 10*p, 0)) }
        rows.append((5_000, 6, 60, 0))
        for i in 7..<10 { let p = Double(i); rows.append((10*p, p, 10*p, 0)) }
        for i in 0..<4 { let p = Double(i); rows.append((3_000 + 10*p, 10 + p, 100 + 10*p, 0)) }
        for i in 0..<4 { let p = Double(i); rows.append((3_100 + 10*p, 20 + p, 140 + 10*p, 1)) }

        let dem: [Double] = [.nan, .infinity, -.infinity, -0.0, 0.0, 1e308, -1e308, 123.456]
        let baseline = rows.enumerated().map {
            sample($0.offset, lat($0.element.0), $0.element.1, supplied: $0.element.2, segment: $0.element.3, accuracy: 5)
        }
        let changed = rows.enumerated().map {
            sample(
                $0.offset, lat($0.element.0), $0.element.1, supplied: $0.element.2, segment: $0.element.3,
                accuracy: 5, dem: $0.offset % 3 == 2 ? nil : dem[$0.offset % dem.count]
            )
        }
        for strategy in [EngineRouteDistancePolicy.coordinates, .allSupplied, .suppliedPerSegment, .suppliedForSelection] {
            let selection: [UInt8]? = strategy == .suppliedForSelection ? Array(repeating: 1, count: rows.count) : nil
            let expected = try process(baseline, strategy, selection: selection)
            let actual = try process(changed, strategy, selection: selection)
            #expect(expected.discardedCount == 1)
            #expect(expected.inferredGapCount == 1)
            #expect(actual.samples.count == expected.samples.count)
            #expect(actual.retainedCount == expected.retainedCount)
            #expect(actual.discardedCount == expected.discardedCount)
            #expect(actual.inferredGapCount == expected.inferredGapCount)
            #expect(actual.segmentCount == expected.segmentCount)
            #expect(actual.distanceSource == expected.distanceSource)
            #expect(actual.totalDistance.bitPattern == expected.totalDistance.bitPattern)
            for (lhs, rhs) in zip(actual.samples, expected.samples) {
                #expect(lhs.sourceIndex == rhs.sourceIndex)
                #expect(lhs.normalizedSegmentIndex == rhs.normalizedSegmentIndex)
                #expect(lhs.normalizedDistance.bitPattern == rhs.normalizedDistance.bitPattern)
                #expect(lhs.distanceSource == rhs.distanceSource)
                #expect(lhs.retained == rhs.retained)
                #expect(lhs.rejected == rhs.rejected)
                #expect(lhs.inferredBoundary == rhs.inferredBoundary)
            }
        }
    }
}
