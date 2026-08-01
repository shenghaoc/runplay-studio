import XCTest
@testable import RunPlayCore

/// Compares the C++23 bridge candidate selection against the independent
/// Swift oracle across deterministic generated fixtures.
final class RunPlaySegmentDetectorBridgeTests: XCTestCase {

    // MARK: - Named fixtures

    func testPauseSpanningUsesActiveTime() throws {
        let points = TestFixtures.makePauseSpanningRoute()
        _ = RunWorkout(routePoints: points)
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        let config = makeDefaultConfig(
            points: points,
            timeline: timeline,
            elevationProfile: elevationProfile
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points, timeline: timeline,
            elevationProfile: elevationProfile, configuration: config,
            cancellationCheckStride: 2048, isCancelled: { false }
        )

        let oracleConfig = makeOracleConfig(timeline: timeline, bridgeConfig: config)
        let oracleResult = SwiftSegmentDetectorOracle.search(
            timeline: timeline, elevationProfile: elevationProfile, config: oracleConfig
        )

        // Must have fastest 1km
        let bridge1km = bridgeResult.candidates.first { $0.kind == .fastest1km }
        let oracle1km = oracleResult.first { $0.kind == .fastest1km }
        XCTAssertNotNil(bridge1km, "Bridge should find fastest 1km")
        XCTAssertNotNil(oracle1km, "Oracle should find fastest 1km")
        if let b = bridge1km, let o = oracle1km {
            assertClose(b.startDistanceMeters, o.startDistanceMeters)
            assertClose(b.endDistanceMeters, o.endDistanceMeters)
            assertClose(b.selectionValue, o.selectionValue)
        }

        XCTAssertEqual(bridgeResult.candidates.count, oracleResult.count,
                       "Same candidate count")
    }

    func testConstantPaceRoute() throws {
        let points = TestFixtures.makeConstantPaceRoute()
        _ = RunWorkout(routePoints: points)
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        let config = makeDefaultConfig(
            points: points,
            timeline: timeline,
            elevationProfile: elevationProfile
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points, timeline: timeline,
            elevationProfile: elevationProfile, configuration: config,
            cancellationCheckStride: 2048, isCancelled: { false }
        )
        XCTAssertFalse(bridgeResult.candidates.isEmpty, "Should find at least fastest 400m")
    }

    func testElevationRoute() throws {
        let points = TestFixtures.makeClimbingRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)

        let config = SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: 50,
            oneKilometerDistanceMeters: 1000, oneKilometerStepMeters: 50,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1200,
            elevationEnabled: elevationProfile.hasMeaningfulElevation,
            elevationWindowDistanceMeters: 500,
            elevationStepMeters: 100,
            maximumEvaluationsPerSearch: 10000
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points, timeline: timeline,
            elevationProfile: elevationProfile, configuration: config,
            cancellationCheckStride: 2048, isCancelled: { false }
        )

        let climb = bridgeResult.candidates.first { $0.kind == .biggestClimb }
        XCTAssertNotNil(climb, "Should find biggest climb")
    }

    func testNoElevationWhenDisabled() throws {
        let points = TestFixtures.makeClimbingRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)

        let config = SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: 50,
            oneKilometerDistanceMeters: 1000, oneKilometerStepMeters: 50,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1200,
            elevationEnabled: false,
            elevationWindowDistanceMeters: 0,
            elevationStepMeters: 0,
            maximumEvaluationsPerSearch: 10000
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points, timeline: timeline,
            elevationProfile: elevationProfile, configuration: config,
            cancellationCheckStride: 2048, isCancelled: { false }
        )

        let climb = bridgeResult.candidates.first { $0.kind == .biggestClimb }
        XCTAssertNil(climb, "No climb when elevation disabled")
        let descent = bridgeResult.candidates.first { $0.kind == .biggestDescent }
        XCTAssertNil(descent, "No descent when elevation disabled")
    }

    func testSameSegmentDistancePlateauMatchesTimelineOracle() throws {
        let points = TestFixtures.makeSameSegmentPlateauRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        let config = SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: 50,
            oneKilometerDistanceMeters: 1_000, oneKilometerStepMeters: 50,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1_200,
            elevationEnabled: false,
            elevationWindowDistanceMeters: 0,
            elevationStepMeters: 0,
            maximumEvaluationsPerSearch: 100
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: config,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        let oracleResult = SwiftSegmentDetectorOracle.search(
            timeline: timeline,
            elevationProfile: elevationProfile,
            config: makeOracleConfig(timeline: timeline, bridgeConfig: config)
        )

        XCTAssertEqual(bridgeResult.candidates.count, oracleResult.count)
        XCTAssertEqual(bridgeResult.candidates.first?.startDistanceMeters, 400)
        assertClose(
            bridgeResult.candidates.first?.selectionValue ?? .nan,
            oracleResult.first?.selectionValue ?? .nan
        )
        assertClose(bridgeResult.candidates.first?.selectionValue ?? .nan, 500)
    }

    func testSeparatedReliableElevationRunsRemainValid() throws {
        let points = TestFixtures.makeSeparatedElevationRunsRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        XCTAssertTrue(elevationProfile.hasMeaningfulElevation)

        let config = SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: 50,
            oneKilometerDistanceMeters: 1_000, oneKilometerStepMeters: 50,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1_200,
            elevationEnabled: true,
            elevationWindowDistanceMeters: 200,
            elevationStepMeters: 100,
            maximumEvaluationsPerSearch: 1_000
        )

        let bridgeResult = try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: config,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )
        let oracleResult = SwiftSegmentDetectorOracle.search(
            timeline: timeline,
            elevationProfile: elevationProfile,
            config: makeOracleConfig(timeline: timeline, bridgeConfig: config)
        )

        XCTAssertEqual(
            bridgeResult.candidates.map(\.kind).count,
            oracleResult.count,
            "Missing-altitude gaps must separate, not invalidate, reliable runs"
        )
    }

    func testEachInternalSearchRetainsItsOwnEvaluationBudget() throws {
        let points = TestFixtures.makeBudgetRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        let config = SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: 100,
            oneKilometerDistanceMeters: 1_000, oneKilometerStepMeters: 100,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1_200,
            elevationEnabled: false,
            elevationWindowDistanceMeters: 0,
            elevationStepMeters: 0,
            maximumEvaluationsPerSearch: 20
        )

        let result = try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: config,
            cancellationCheckStride: 2_048,
            isCancelled: { false }
        )

        XCTAssertEqual(result.paceEvaluationCount, 28)
        XCTAssertGreaterThan(result.candidates.count, 0)
    }

    func testCancellationPropagatesDuringInputConversion() {
        let points = TestFixtures.makeBudgetRoute()
        let timeline = WorkoutTimeline(routePoints: points)
        let elevationProfile = ElevationProfile(routePoints: points)
        let config = makeDefaultConfig(
            points: points,
            timeline: timeline,
            elevationProfile: elevationProfile
        )

        XCTAssertThrowsError(try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: timeline,
            elevationProfile: elevationProfile,
            configuration: config,
            cancellationCheckStride: 1,
            isCancelled: { true }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Generated fixture parity

    func testDeterministicGeneratedParityFixtures() throws {
        for index in 0..<SegmentDetectorParityFixtures.generatedFixtureCount {
            let points = SegmentDetectorParityFixtures.generatedFixture(index: index)
            let timeline = WorkoutTimeline(routePoints: points)
            let elevationProfile = ElevationProfile(routePoints: points)
            let config = makeDefaultConfig(
                points: points,
                timeline: timeline,
                elevationProfile: elevationProfile
            )

            let bridgeResult = try RunPlaySegmentDetectorBridge.search(
                routePoints: points, timeline: timeline,
                elevationProfile: elevationProfile, configuration: config,
                cancellationCheckStride: 2048, isCancelled: { false }
            )

            let oracleConfig = makeOracleConfig(timeline: timeline, bridgeConfig: config)
            let oracleResult = SwiftSegmentDetectorOracle.search(
                timeline: timeline, elevationProfile: elevationProfile,
                config: oracleConfig
            )

            // Same count
            XCTAssertEqual(bridgeResult.candidates.count, oracleResult.count,
                           "Fixture \(index): candidate count mismatch")

            // Each candidate matches
            for (bi, bc) in bridgeResult.candidates.enumerated() {
                let oc = oracleResult[bi]
                let oracleKind = SwiftSegmentDetectorOracle.Candidate.Kind(rawValue: String(describing: bc.kind).replacingOccurrences(of: "RunPlay.", with: "")) ?? {
                    switch bc.kind {
                    case .fastest400m: return .fastest400m
                    case .fastest1km: return .fastest1km
                    case .slowest1km: return .slowest1km
                    case .biggestClimb: return .biggestClimb
                    case .biggestDescent: return .biggestDescent
                    }
                }()
                XCTAssertEqual(oracleKind, oc.kind,
                               "Fixture \(index): kind mismatch at position \(bi)")
                assertClose(bc.startDistanceMeters, oc.startDistanceMeters,
                            message: "Fixture \(index) candidate \(bi) startDistance")
                assertClose(bc.endDistanceMeters, oc.endDistanceMeters,
                            message: "Fixture \(index) candidate \(bi) endDistance")
                assertClose(bc.selectionValue, oc.selectionValue,
                            message: "Fixture \(index) candidate \(bi) selectionValue")
            }
        }
    }

    func testBridgeHandlesEmptyRoute() throws {
        let result = try RunPlaySegmentDetectorBridge.search(
            routePoints: [], timeline: WorkoutTimeline(routePoints: []),
            elevationProfile: ElevationProfile(routePoints: []),
            configuration: makeDefaultConfig(
                points: [],
                timeline: WorkoutTimeline(routePoints: []),
                elevationProfile: ElevationProfile(routePoints: [])
            ),
            cancellationCheckStride: 1, isCancelled: { false }
        )
        XCTAssertEqual(result.candidates.count, 0)
    }

    func testBridgeHandlesSinglePoint() throws {
        let point = RoutePoint(timestamp: Date(), latitude: 0, longitude: 0,
                               altitudeMeters: 10, distanceFromStartMeters: 0, elapsedSeconds: 0)
        let points = [point]
        let result = try RunPlaySegmentDetectorBridge.search(
            routePoints: points,
            timeline: WorkoutTimeline(routePoints: points),
            elevationProfile: ElevationProfile(routePoints: points),
            configuration: makeDefaultConfig(
                points: points,
                timeline: WorkoutTimeline(routePoints: points),
                elevationProfile: ElevationProfile(routePoints: points)
            ),
            cancellationCheckStride: 1, isCancelled: { false }
        )
        XCTAssertEqual(result.candidates.count, 0)
    }

    // MARK: - Helpers

    private func makeDefaultConfig(
        points: [RoutePoint],
        timeline: WorkoutTimeline,
        elevationProfile: ElevationProfile
    ) -> SegmentDetectorSearchConfiguration {
        let distanceSpan = timeline.totalDistanceMeters - timeline.startDistanceMeters
        let routeCount = points.count
        let bounded400Step = RouteAnalysisBudget.boundedStep(
            preferredStep: 50, distanceSpan: distanceSpan,
            routePointCount: routeCount
        )
        let bounded1kmStep = RouteAnalysisBudget.boundedStep(
            preferredStep: 50, distanceSpan: distanceSpan,
            routePointCount: routeCount
        )
        let policy = RouteQualityPolicy.runningDefault
        let elevationEnabled = elevationProfile.hasMeaningfulElevation
            && timeline.totalDistanceMeters
                >= policy.elevationHighlightMinimumWindowMeters
        let elevationWindow = elevationEnabled
            ? max(
                policy.elevationHighlightMinimumWindowMeters,
                min(
                    policy.elevationHighlightMaximumWindowMeters,
                    timeline.totalDistanceMeters
                        * policy.elevationHighlightWindowRouteFraction
                )
            )
            : 0
        let elevationStep = elevationEnabled
            ? RouteAnalysisBudget.boundedStep(
                preferredStep: max(
                    policy.elevationHighlightMinimumStepMeters,
                    elevationWindow
                        / Double(policy.elevationHighlightStepsPerWindow)
                ),
                distanceSpan: distanceSpan,
                routePointCount: routeCount
            )
            : 0

        return SegmentDetectorSearchConfiguration(
            fastest400mDistanceMeters: 400, fastest400mStepMeters: bounded400Step,
            oneKilometerDistanceMeters: 1000, oneKilometerStepMeters: bounded1kmStep,
            minimumValidPaceSecondsPerKilometer: 120,
            maximumValidPaceSecondsPerKilometer: 1200,
            elevationEnabled: elevationEnabled,
            elevationWindowDistanceMeters: elevationWindow,
            elevationStepMeters: elevationStep,
            maximumEvaluationsPerSearch: UInt64(
                RouteAnalysisBudget.maximumEvaluations(forRoutePointCount: routeCount)
            )
        )
    }

    private func makeOracleConfig(
        timeline: WorkoutTimeline,
        bridgeConfig: SegmentDetectorSearchConfiguration
    ) -> SwiftSegmentDetectorOracle.SearchConfig {
        SwiftSegmentDetectorOracle.SearchConfig(
            fastest400mDistance: bridgeConfig.fastest400mDistanceMeters,
            fastest400mStep: bridgeConfig.fastest400mStepMeters,
            oneKmDistance: bridgeConfig.oneKilometerDistanceMeters,
            oneKmStep: bridgeConfig.oneKilometerStepMeters,
            minPace: bridgeConfig.minimumValidPaceSecondsPerKilometer,
            maxPace: bridgeConfig.maximumValidPaceSecondsPerKilometer,
            elevationEnabled: bridgeConfig.elevationEnabled,
            elevationWindow: bridgeConfig.elevationWindowDistanceMeters,
            elevationStep: bridgeConfig.elevationStepMeters
        )
    }

    private func assertClose(
        _ a: Double, _ b: Double,
        message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let tol = max(1e-9, abs(a) * 1e-12)
        XCTAssertTrue(abs(a - b) <= tol,
                      "\(message): \(a) != \(b) (tol=\(tol))",
                      file: file, line: line)
    }
}

/// Deterministic test fixtures for bridge parity tests.
private enum TestFixtures {

    static func makePauseSpanningRoute() -> [RoutePoint] {
        let start = Date()
        return [
            segmentPoint(start: start, time: 0, distance: 0, segment: 0),
            segmentPoint(start: start, time: 150, distance: 500, segment: 0),
            segmentPoint(start: start, time: 1_150, distance: 500, segment: 1),
            segmentPoint(start: start, time: 1_300, distance: 1_000, segment: 1),
            segmentPoint(start: start, time: 1_600, distance: 1_500, segment: 1),
            segmentPoint(start: start, time: 1_900, distance: 2_000, segment: 1),
        ]
    }

    static func makeConstantPaceRoute() -> [RoutePoint] {
        let start = Date()
        return (0...10).map { i in
            let d = Double(i) * 100
            return segmentPoint(start: start, time: d * 0.25, distance: d, segment: 0)
        }
    }

    static func makeClimbingRoute() -> [RoutePoint] {
        let start = Date()
        return (0...10).map { i in
            let d = Double(i) * 100
            return RoutePoint(
                timestamp: start.addingTimeInterval(d * 0.25),
                latitude: 1 + d / 100_000,
                longitude: 1,
                altitudeMeters: 10 + Double(i) * 5,
                distanceFromStartMeters: d,
                elapsedSeconds: d * 0.25,
                routeSegmentIndex: 0
            )
        }
    }

    static func makeSameSegmentPlateauRoute() -> [RoutePoint] {
        let start = Date()
        return [
            segmentPoint(start: start, time: 0, distance: 0, segment: 0),
            segmentPoint(start: start, time: 300, distance: 400, segment: 0),
            segmentPoint(start: start, time: 400, distance: 400, segment: 0),
            segmentPoint(start: start, time: 500, distance: 800, segment: 0),
        ]
    }

    static func makeSeparatedElevationRunsRoute() -> [RoutePoint] {
        let start = Date()
        return (0..<10).map { index in
            let distance = Double(index) * 100
            let altitude: Double?
            switch index {
            case 0...3:
                altitude = 100 + Double(index) * 4
            case 4...5:
                altitude = nil
            default:
                altitude = 140 + Double(index - 6) * 5
            }
            return RoutePoint(
                timestamp: start.addingTimeInterval(distance * 0.3),
                latitude: 1 + distance / 100_000,
                longitude: 1,
                altitudeMeters: altitude,
                distanceFromStartMeters: distance,
                elapsedSeconds: distance * 0.3,
                routeSegmentIndex: 0
            )
        }
    }

    static func makeBudgetRoute() -> [RoutePoint] {
        let start = Date()
        return (0...20).map { index in
            let distance = Double(index) * 100
            return segmentPoint(
                start: start,
                time: distance * 0.3,
                distance: distance,
                segment: 0
            )
        }
    }

    private static func segmentPoint(
        start: Date, time: Double, distance: Double, segment: Int
    ) -> RoutePoint {
        RoutePoint(
            timestamp: start.addingTimeInterval(time),
            latitude: 1 + distance / 100_000,
            longitude: 1,
            altitudeMeters: 10,
            distanceFromStartMeters: distance,
            elapsedSeconds: time,
            routeSegmentIndex: segment
        )
    }
}
