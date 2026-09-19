import XCTest
@testable import RunPlayCore

/// Two-stage route-grouping matching tests over synthetic routes.
///
/// Containment semantics — deliberately reversed from the original plan's
/// superset rule: a run that covers a route plus extra distance (spur,
/// warm-up, or longer finish) does NOT group with the route. Mutual
/// coverage — matched distance ÷ total distance on BOTH routes, from the
/// single existing solve — is the guard; the manual merge action is the
/// recovery path for genuine containment pairs. The measured grid behind
/// the product (budget, threshold) pair is in `RouteGroupingMeasurementTests`.
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

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), mutual \(outcome.mutualCoverage), median \(outcome.medianSeparationMeters), p90 \(outcome.p90SeparationMeters)")
        XCTAssertFalse(outcome.isReversed)
        XCTAssertGreaterThanOrEqual(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
        XCTAssertLessThanOrEqual(outcome.medianSeparationMeters, 35)
        XCTAssertLessThanOrEqual(outcome.p90SeparationMeters, 100)
    }

    /// The short-route interaction: at the product budget a ~2 km identical
    /// pair must still clear the threshold — a budget/threshold mismatch
    /// here would reject identical short routes outright.
    func testIdenticalShortLoopWithGPSNoiseGroups() throws {
        let clean = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 500),
            date: RouteGroupingFixtures.epoch
        )
        let noisy = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.seededNoise(
                on: RouteGroupingFixtures.squareLoop(
                    sideMeters: 500,
                    date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
                ),
                noiseMeters: 12,
                seed: 4_242
            ),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let outcome = try match(noisy, against: clean)

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), mutual \(outcome.mutualCoverage) — the budget/coverage interaction must keep short identical routes above the threshold")
        XCTAssertGreaterThanOrEqual(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
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

        XCTAssertTrue(outcome.matches, "reason: \(String(describing: outcome.noMatchReason)), mutual \(outcome.mutualCoverage), median \(outcome.medianSeparationMeters)")
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

    // MARK: - Containment (superset rule deliberately reversed)

    func testLoopPlusSpurDoesNotGroupWithLoop() throws {
        // 5 km loop + 800 m spur = 5.8 km, ratio 1.16 — inside [0.8, 1.25],
        // so stage 1 admits the pair and mutual coverage must reject it:
        // the superset side covers at most 5.0/5.8 ≈ 0.86 of itself. The
        // original plan grouped this pair; the reversal is deliberate (see
        // this file's header and the containment section of
        // docs/architecture.md).
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

        let outcome = try match(superset, against: loop)

        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage) — containment must not group; manual merge is the recovery path")
        XCTAssertLessThan(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
    }

    func testLoopMatchedAgainstItsOwnSupersetDoesNotGroup() throws {
        // Direction of matching follows the incremental pass: the new run
        // is matched against the existing group's representative, which may
        // be the longer superset. Containment is symmetric — the shorter
        // side is fully covered but the superset side is not.
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

        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage) — containment must not group from either side")
        XCTAssertLessThan(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
    }

    func testFiveKilometrePrefixOfSixKilometreRouteDoesNotGroup() throws {
        // Ratio 0.833 sits inside the stage-1 bounds, so this pair reaches
        // the solve and mutual coverage must be the guard: the 5 km side is
        // fully covered but the 6 km side covers at most 5/6.
        let long = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 6_000),
            date: RouteGroupingFixtures.epoch
        )
        let prefix = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 5_000),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let outcome = try match(prefix, against: long)

        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage) — a prefix is not the same route")
        XCTAssertLessThan(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
    }

    func testFiveKilometrePrefixOfTenKilometreRouteDoesNotGroup() throws {
        // Ratio 0.5 — historically filtered by the stage-1 distance-ratio
        // bound, which was removed after measurement (it saved 1 solve in
        // 1,760 on the benchmark library). The pair now reaches the solve
        // and mutual coverage rejects it on the numbers: the 10 km side
        // covers at most 0.5 of itself.
        let long = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 10_000),
            date: RouteGroupingFixtures.epoch
        )
        let prefix = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.straightLine(distanceMeters: 5_000),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let outcome = try match(prefix, against: long)

        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage) — the prefix must not group")
        XCTAssertLessThan(outcome.mutualCoverage, RouteGroupingPolicy.default.minimumMutualCoverageFraction)
    }

    // MARK: - Boundary around the mutual-coverage threshold

    func testSharedPrefixSlightlyAboveThresholdGroups() throws {
        // Shared 4.9 km of a 5 km route → mutual coverage ≈ 0.97 (engine
        // fraction cap keeps ~2% unmatched), above the 0.90 threshold with
        // margin. Same length, same start: stage 1 admits easily.
        let dateA = RouteGroupingFixtures.epoch
        let dateB = dateA.addingTimeInterval(86_400)
        let east = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.divergingRoute(sharedMeters: 4_900, totalMeters: 5_000, tailEast: true, date: dateA),
            date: dateA
        )
        let west = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.divergingRoute(sharedMeters: 4_900, totalMeters: 5_000, tailEast: false, date: dateB),
            date: dateB
        )

        let outcome = try match(west, against: east)

        XCTAssertTrue(outcome.matches, "mutual \(outcome.mutualCoverage) — a ~0.97-coverage near-repeat must group above the 0.90 threshold")
    }

    func testSharedPrefixWellBelowThresholdDoesNotGroup() throws {
        // Shared 3.75 km of a 5 km route → mutual coverage ≈ 0.72 (with the
        // fraction cap), below the 0.90 threshold: the diverging 1.25 km
        // tails are real different routes even though both start
        // identically. Sits between the loop+spur ceiling (0.862) and the
        // accept class floor, guarding the line from below.
        let dateA = RouteGroupingFixtures.epoch
        let dateB = dateA.addingTimeInterval(86_400)
        let east = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.divergingRoute(sharedMeters: 3_750, totalMeters: 5_000, tailEast: true, date: dateA),
            date: dateA
        )
        let west = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.divergingRoute(sharedMeters: 3_750, totalMeters: 5_000, tailEast: false, date: dateB),
            date: dateB
        )

        let outcome = try match(west, against: east)

        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage) — a ~0.72-coverage pair must not group below the 0.90 threshold")
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
        XCTAssertFalse(outcome.matches, "mutual \(outcome.mutualCoverage), median \(outcome.medianSeparationMeters), p90 \(outcome.p90SeparationMeters)")
        XCTAssertFalse(
            outcome.mutualCoverage >= RouteGroupingPolicy.default.minimumMutualCoverageFraction
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
        XCTAssertEqual(policy.minimumMutualCoverageFraction, 0.9)
        XCTAssertEqual(policy.maximumMedianSeparationMeters, 35)
        XCTAssertEqual(policy.maximumP90SeparationMeters, 100)
        XCTAssertTrue(policy.matchesOppositeDirection)
        XCTAssertEqual(policy.unmatchedBudgetMeters, 100)
        // The grouping DTW variant tightens the unmatched budget to the
        // measured grouping parameter (comparison keeps 500 m) and lifts
        // only the warp-run cap; the band-cell ceiling stays.
        XCTAssertEqual(policy.alignment.maximumUnmatchedPrefixSuffixMeters, 100)
        XCTAssertNotEqual(policy.alignment.maximumUnmatchedPrefixSuffixMeters, RouteAlignmentPolicy.default.maximumUnmatchedPrefixSuffixMeters)
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
