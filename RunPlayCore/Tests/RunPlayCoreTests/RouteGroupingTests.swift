import XCTest
@testable import RunPlayCore

/// Two-stage route-grouping matching tests over synthetic routes.
final class RouteGroupingTests: XCTestCase {
    private var matcher: RouteGroupingMatcher!

    override func setUp() {
        super.setUp()
        matcher = RouteGroupingMatcher()
    }

    private func match(
        _ workout: RunWorkout,
        against representative: RunWorkout,
        policy: RouteGroupingPolicy = .default
    ) throws -> RouteGroupingMatchOutcome {
        try matcher.match(
            workout: workout,
            workoutFacts: RouteGroupingRouteFacts(workout: workout),
            representative: representative,
            representativeFacts: RouteGroupingRouteFacts(workout: representative),
            policy: policy,
            isCancelled: { false }
        )
    }

    // MARK: - Same route, different noise

    func testIdenticalLoopWithGPSNoiseGroups() throws {
        let base = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0, noiseMeters: 0)
        let noisy = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 1, noiseMeters: 12)

        let outcome = try match(noisy, against: base)

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), coverage \(outcome.coverageOfShorterRoute), median \(outcome.medianSeparationMeters), p90 \(outcome.p90SeparationMeters)")
        XCTAssertFalse(outcome.isReversed)
        XCTAssertGreaterThanOrEqual(outcome.coverageOfShorterRoute, 0.85)
        XCTAssertLessThanOrEqual(outcome.medianSeparationMeters, 35)
        XCTAssertLessThanOrEqual(outcome.p90SeparationMeters, 100)
    }

    // MARK: - Reversed direction

    func testSameLoopReversedGroupsWithReversedFlag() throws {
        let forward = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0, noiseMeters: 0)
        let reversedPoints = RouteGroupingFixtures.reversed(
            forward.routePoints,
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )
        let reversed = RouteGroupingFixtures.workout(points: reversedPoints, date: reversedPoints[0].timestamp)

        let outcome = try match(reversed, against: forward)

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), coverage \(outcome.coverageOfShorterRoute), median \(outcome.medianSeparationMeters)")
        XCTAssertTrue(outcome.isReversed, "the reversed traversal must be marked")
    }

    func testOppositeDirectionExcludedWhenPolicyDisablesIt() throws {
        let forward = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0, noiseMeters: 0)
        let reversedPoints = RouteGroupingFixtures.reversed(
            forward.routePoints,
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )
        let reversed = RouteGroupingFixtures.workout(points: reversedPoints, date: reversedPoints[0].timestamp)
        let policy = RouteGroupingPolicy(matchesOppositeDirection: false)

        let outcome = try match(reversed, against: forward, policy: policy)

        XCTAssertFalse(outcome.matches)
        XCTAssertEqual(outcome.noMatchReason, .oppositeDirectionExcluded)
    }

    // MARK: - Superset (loop plus spur)

    func testLoopPlusSpurGroupsWithLoop() throws {
        let loopDate = RouteGroupingFixtures.epoch
        let spurDate = loopDate.addingTimeInterval(86_400)
        // 5 km loop + 800 m spur = 5.8 km, ratio 1.16 — inside [0.8, 1.25].
        let loop = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: loopDate
        )
        let superset = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.loopWithSpur(sideMeters: 1_250, spurMeters: 800, date: spurDate),
            date: spurDate
        )

        // The shorter route (loop) is the representative here; the superset
        // must join it because only coverage of the shorter route counts.
        let outcome = try match(superset, against: loop)

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), coverage \(outcome.coverageOfShorterRoute), median \(outcome.medianSeparationMeters)")
        XCTAssertGreaterThanOrEqual(outcome.coverageOfShorterRoute, 0.85)
    }

    func testLoopMatchedAgainstItsOwnSupersetAlsoGroups() throws {
        // Direction of matching follows the incremental pass: the new run is
        // matched against the existing group's representative, which may be
        // the longer superset.
        let loopDate = RouteGroupingFixtures.epoch
        let spurDate = loopDate.addingTimeInterval(86_400)
        let loop = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: loopDate
        )
        let superset = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.loopWithSpur(sideMeters: 1_250, spurMeters: 800, date: spurDate),
            date: spurDate
        )

        let outcome = try match(loop, against: superset)

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), coverage \(outcome.coverageOfShorterRoute), median \(outcome.medianSeparationMeters)")
    }

    // MARK: - Containment (the subset hole)

    func testShortRouteWhollyContainedInLongerRouteDoesNotGroup() throws {
        // A 5 km route that is a strict prefix of a 10 km route must not
        // group: coverage of the shorter route alone would admit it, so the
        // stage-1 distance-ratio bound is the guard.
        let long = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 10_000),
            date: RouteGroupingFixtures.epoch
        )
        let short = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 5_000),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let outcome = try match(short, against: long)

        XCTAssertFalse(outcome.matches)
        XCTAssertEqual(outcome.noMatchReason, .filteredOut)
    }

    // MARK: - Partial overlap

    func testLoopsSharingOneEdgeDoNotGroup() throws {
        // Two rectangle loops sharing the full bottom edge (~36% of each
        // perimeter): same start corner, same distance, overlapping bbox —
        // stage 1 admits the pair and the coverage threshold must reject it.
        let dateA = RouteGroupingFixtures.epoch
        let dateB = dateA.addingTimeInterval(86_400)
        let north = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.rectangleLoop(widthMeters: 1_000, heightMeters: 400, date: dateA),
            date: dateA
        )
        let south = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.rectangleLoop(widthMeters: 1_000, heightMeters: 400, mirrored: true, date: dateB),
            date: dateB
        )

        let outcome = try match(south, against: north)

        // The rejection may come from coverage or separation — the DTW can
        // warp the unshared sides together, but the separation statistics
        // expose it. Either axis must fail.
        XCTAssertFalse(outcome.matches, "coverage \(outcome.coverageOfShorterRoute), median \(outcome.medianSeparationMeters), p90 \(outcome.p90SeparationMeters)")
        XCTAssertFalse(
            outcome.coverageOfShorterRoute >= 0.85
                && outcome.medianSeparationMeters <= 35
                && outcome.p90SeparationMeters <= 100
        )
    }

    func testRoutesFarApartDoNotGroup() throws {
        let dateA = RouteGroupingFixtures.epoch
        let dateB = dateA.addingTimeInterval(86_400)
        let near = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: dateA),
            date: dateA
        )
        // Same shape offset ~30 km east: bbox overlap fails stage 1.
        let farPoints = RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: dateB).map { point in
            RoutePoint(
                timestamp: point.timestamp,
                latitude: point.latitude,
                longitude: point.longitude + 30_000 / RouteGroupingFixtures.metersPerDegreeLongitude,
                distanceFromStartMeters: point.distanceFromStartMeters,
                elapsedSeconds: point.elapsedSeconds,
                paceSecondsPerKilometer: point.paceSecondsPerKilometer,
                routeSegmentIndex: point.routeSegmentIndex
            )
        }
        let far = RouteGroupingFixtures.workout(points: farPoints, date: dateB)

        let outcome = try match(far, against: near)

        XCTAssertFalse(outcome.matches)
        XCTAssertEqual(outcome.noMatchReason, .filteredOut)
    }

    // MARK: - Participation minimums

    func testBelowMinimumDistanceYieldsNoParticipation() {
        let date = RouteGroupingFixtures.epoch
        let tiny = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 80),
            date: date
        )
        let facts = RouteGroupingRouteFacts(workout: tiny)
        XCTAssertFalse(facts.canParticipate(policy: .default))
    }

    // MARK: - Facts

    func testFactsCaptureBoundsEndpointsAndDistance() {
        let date = RouteGroupingFixtures.epoch
        let workout = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 1_000),
            date: date
        )
        let facts = RouteGroupingRouteFacts(workout: workout)

        XCTAssertEqual(facts.totalDistanceMeters, 4_000, accuracy: 1)
        XCTAssertEqual(facts.routePointCount, 201)
        XCTAssertEqual(facts.startLatitude, RouteGroupingFixtures.baseLatitude, accuracy: 1e-9)
        XCTAssertEqual(facts.startLongitude, RouteGroupingFixtures.baseLongitude, accuracy: 1e-9)
        XCTAssertEqual(facts.finishLatitude, RouteGroupingFixtures.baseLatitude, accuracy: 1e-9)
        XCTAssertEqual(facts.finishLongitude, RouteGroupingFixtures.baseLongitude, accuracy: 1e-9)
        XCTAssertGreaterThan(facts.maxLatitude, facts.minLatitude)
        XCTAssertGreaterThan(facts.maxLongitude, facts.minLongitude)
    }

    // MARK: - Reversal sample mirroring

    func testReversedSamplesMirrorDistancesProgressAndHeadings() {
        let samples = [
            RouteAlignmentSample(
                xMeters: 0, zMeters: 0,
                distanceFromStartMeters: 0,
                routeSegmentIndex: 0,
                elapsedSeconds: 0,
                headingRadians: 0,
                normalizedProgress: 0
            ),
            RouteAlignmentSample(
                xMeters: 100, zMeters: 0,
                distanceFromStartMeters: 100,
                routeSegmentIndex: 0,
                elapsedSeconds: 30,
                headingRadians: .pi / 2,
                normalizedProgress: 0.5
            ),
            RouteAlignmentSample(
                xMeters: 200, zMeters: 0,
                distanceFromStartMeters: 200,
                routeSegmentIndex: 0,
                elapsedSeconds: 60,
                headingRadians: .pi,
                normalizedProgress: 1
            )
        ]

        let reversed = RouteGroupingMatcher.reversedSamples(samples, totalDistanceMeters: 200)

        // The reversed traversal starts at the old finish, so distances and
        // progress restart from zero and ascend.
        XCTAssertEqual(reversed.count, 3)
        XCTAssertEqual(reversed[0].distanceFromStartMeters, 0, accuracy: 1e-9)
        XCTAssertEqual(reversed[2].distanceFromStartMeters, 200, accuracy: 1e-9)
        XCTAssertLessThan(reversed[0].distanceFromStartMeters, reversed[1].distanceFromStartMeters)
        XCTAssertLessThan(reversed[1].distanceFromStartMeters, reversed[2].distanceFromStartMeters)
        XCTAssertEqual(reversed[0].normalizedProgress, 0, accuracy: 1e-9)
        XCTAssertEqual(reversed[2].normalizedProgress, 1, accuracy: 1e-9)
        XCTAssertEqual(reversed[0].elapsedSeconds ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(reversed[2].elapsedSeconds ?? -1, 60, accuracy: 1e-9)
        // Headings flip by pi (wrapped) so the reversed traversal's headings
        // stay geometrically truthful.
        XCTAssertEqual(reversed[1].headingRadians!, -.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(reversed[2].headingRadians!, .pi, accuracy: 1e-9)
    }

    // MARK: - Policy

    func testDefaultPolicyThresholdsAndDirectionFlag() {
        let policy = RouteGroupingPolicy.default
        XCTAssertEqual(policy.minimumShorterRouteCoverageFraction, 0.85)
        XCTAssertEqual(policy.maximumMedianSeparationMeters, 35)
        XCTAssertEqual(policy.maximumP90SeparationMeters, 100)
        XCTAssertTrue(policy.matchesOppositeDirection)
        XCTAssertEqual(policy.distanceRatioBounds, 0.8...1.25)
        // The grouping DTW variant keeps the comparison unmatched budget (a
        // wider budget lets zero-cost identical paths stop early) and lifts
        // only the warp-run cap so supersets can solve; the band-cell
        // ceiling stays.
        XCTAssertEqual(policy.alignment.maximumUnmatchedPrefixSuffixMeters, RouteAlignmentPolicy.default.maximumUnmatchedPrefixSuffixMeters)
        XCTAssertGreaterThan(policy.alignment.maximumConsecutiveWarpSteps, RouteAlignmentPolicy.default.maximumConsecutiveWarpSteps)
        XCTAssertEqual(policy.alignment.maximumBandCells, RouteAlignmentPolicy.default.maximumBandCells)
    }

    // MARK: - Derived default name

    func testDefaultDisplayNameDescribesGeometry() {
        let loop = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_234, closesLoop: true)
        XCTAssertTrue(loop.hasSuffix("Loop"))
        XCTAssertTrue(loop.hasPrefix("5.2 km"))

        let route = WorkoutRouteGroup.defaultDisplayName(distanceMeters: 10_050, closesLoop: false)
        XCTAssertTrue(route.hasSuffix("Route"))
        XCTAssertTrue(route.hasPrefix("10.1 km") || route.hasPrefix("10,1 km"))
    }
}
