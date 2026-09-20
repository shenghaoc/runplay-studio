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

    // MARK: - Collision-aware derived names

    private func derivedNames(
        _ groups: [WorkoutRouteGroup]
    ) -> [UUID: String] {
        WorkoutRouteGroup.derivedDisplayNames(
            for: groups,
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )
    }

    private func derivedName(
        of group: WorkoutRouteGroup,
        in names: [UUID: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(names[group.id], file: file, line: line)
    }

    /// `%.1f km` rounding widens collisions: 1.16 km and 1.24 km both render
    /// "1.2 km". Two such loops sharing start AND finish points must still
    /// be distinguishable — the token is the start-to-extent-centre bearing,
    /// never the start-to-finish bearing, which for a loop is atan2(0, 0)
    /// noise.
    func testSameRoundedDistanceLoopsWithSharedEndpointsGetDistinctTokens() throws {
        let north = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 200, heightMeters: 1_200, date: RouteGroupingFixtures.epoch),
            date: RouteGroupingFixtures.epoch
        )
        let east = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 1_200, heightMeters: 200, mirrored: true, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )
        // The loop-degeneracy premise, asserted so the fixture cannot drift
        // into something a start-to-finish bearing would accidentally
        // distinguish.
        for group in [north, east] {
            let facts = try XCTUnwrap(group.representativeSummary).facts
            XCTAssertEqual(facts.startLatitude, facts.finishLatitude, accuracy: 1e-12)
            XCTAssertEqual(facts.startLongitude, facts.finishLongitude, accuracy: 1e-12)
        }

        let names = derivedNames([north, east])

        let northName = try derivedName(of: north, in: names)
        let eastName = try derivedName(of: east, in: names)
        XCTAssertTrue(northName.hasSuffix("Loop (N)"), "got \(northName)")
        XCTAssertTrue(eastName.hasSuffix("Loop (E)"), "got \(eastName)")
        XCTAssertNotEqual(northName, eastName)
    }

    func testPointToPointCollisionsUseDirectionTokens() throws {
        let north = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.straightLine(distanceMeters: 6_000),
            date: RouteGroupingFixtures.epoch
        )
        let east = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.eastLine(distanceMeters: 6_000, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let names = derivedNames([north, east])

        let northName = try derivedName(of: north, in: names)
        let eastName = try derivedName(of: east, in: names)
        XCTAssertTrue(northName.hasSuffix("Route (N)"), "got \(northName)")
        XCTAssertTrue(eastName.hasSuffix("Route (E)"), "got \(eastName)")
        XCTAssertNotEqual(northName, eastName)
    }

    /// A group whose base name nobody else holds is emitted unchanged —
    /// byte-identical to `defaultDisplayName`, composed not replaced.
    func testUncollidedNamesAreUnchanged() throws {
        let loop = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: RouteGroupingFixtures.epoch
        )
        let route = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.straightLine(distanceMeters: 10_000, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )

        let names = derivedNames([loop, route])

        XCTAssertEqual(
            try derivedName(of: loop, in: names),
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )
        XCTAssertEqual(
            try derivedName(of: route, in: names),
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 10_000, closesLoop: false)
        )
        for name in names.values {
            XCTAssertFalse(name.contains("("), "uncollided names must carry no suffix: \(name)")
        }
    }

    func testUserNamesAreVerbatimAndNeverParticipate() throws {
        let renamed = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: RouteGroupingFixtures.epoch,
            name: "Morning Run"
        )
        // A user name that equals another group's derived base must not
        // push that group into disambiguation: user names never participate.
        let shadowing = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400),
            name: WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )
        let derived = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: RouteGroupingFixtures.epoch.addingTimeInterval(172_800)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(172_800)
        )

        let names = derivedNames([renamed, shadowing, derived])

        XCTAssertEqual(try derivedName(of: renamed, in: names), "Morning Run")
        XCTAssertEqual(
            try derivedName(of: shadowing, in: names),
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )
        XCTAssertEqual(
            try derivedName(of: derived, in: names),
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )
    }

    /// Two identically user-named groups stay identical — the user's choice,
    /// not a collision the rule repairs.
    func testIdenticallyUserNamedGroupsStayIdentical() throws {
        let first = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: RouteGroupingFixtures.epoch,
            name: "Home"
        )
        let second = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.straightLine(distanceMeters: 6_000, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400),
            name: "Home"
        )

        let names = derivedNames([first, second])

        XCTAssertEqual(try derivedName(of: first, in: names), "Home")
        XCTAssertEqual(try derivedName(of: second, in: names), "Home")
    }

    /// Three routes whose distances all round to "1.2 km" and share loop
    /// closure resolve to three distinct compass tokens.
    func testThreeWayCollisionResolvesToDistinctNames() throws {
        let northeast = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 290),
            date: RouteGroupingFixtures.epoch
        )
        let east = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 480, heightMeters: 100, mirrored: true, date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(86_400)
        )
        let north = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 100, heightMeters: 480, date: RouteGroupingFixtures.epoch.addingTimeInterval(172_800)),
            date: RouteGroupingFixtures.epoch.addingTimeInterval(172_800)
        )

        let names = derivedNames([northeast, east, north])

        XCTAssertTrue(try derivedName(of: northeast, in: names).hasSuffix("Loop (NE)"))
        XCTAssertTrue(try derivedName(of: east, in: names).hasSuffix("Loop (E)"))
        XCTAssertTrue(try derivedName(of: north, in: names).hasSuffix("Loop (N)"))
        XCTAssertEqual(Set(names.values).count, 3, "names: \(names)")
    }

    /// The terminal fallback: same base name AND same compass token still
    /// never collides — a numeric ordinal separates them, assigned by the
    /// stable order (earliest representative start date keeps the bare
    /// token).
    func testTokenCollisionFallsBackToNumericOrdinals() throws {
        let day = RouteGroupingFixtures.epoch
        let oldest = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 290, date: day),
            date: day
        )
        let middle = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 300, date: day.addingTimeInterval(86_400)),
            date: day.addingTimeInterval(86_400)
        )
        let newest = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 310, date: day.addingTimeInterval(172_800)),
            date: day.addingTimeInterval(172_800)
        )

        let names = derivedNames([oldest, middle, newest])

        XCTAssertTrue(try derivedName(of: oldest, in: names).hasSuffix("Loop (NE)"))
        XCTAssertTrue(try derivedName(of: middle, in: names).hasSuffix("Loop (NE 2)"))
        XCTAssertTrue(try derivedName(of: newest, in: names).hasSuffix("Loop (NE 3)"))
        XCTAssertEqual(Set(names.values).count, 3, "names: \(names)")
    }

    /// Pure function of the input set: shuffling the input array must not
    /// change a single entry.
    func testNamesAreInputOrderIndependent() {
        let day = RouteGroupingFixtures.epoch
        let a = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 290, date: day),
            date: day
        )
        let b = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 480, heightMeters: 100, mirrored: true, date: day.addingTimeInterval(86_400)),
            date: day.addingTimeInterval(86_400)
        )
        let c = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.rectangleLoop(widthMeters: 100, heightMeters: 480, date: day.addingTimeInterval(172_800)),
            date: day.addingTimeInterval(172_800)
        )

        let reference = derivedNames([a, b, c])

        XCTAssertEqual(derivedNames([a, b, c]), reference)
        XCTAssertEqual(derivedNames([c, a, b]), reference)
        XCTAssertEqual(derivedNames([b, c, a]), reference)
        XCTAssertEqual(derivedNames([c, b, a]), reference)
    }

    /// Re-running on the same set is identical, and adding a group that
    /// does not collide renames nothing.
    func testNamesAreStableAcrossRunsAndUnrelatedAdditions() throws {
        let day = RouteGroupingFixtures.epoch
        let loop = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: day),
            date: day
        )
        let line = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.straightLine(distanceMeters: 6_000, date: day.addingTimeInterval(86_400)),
            date: day.addingTimeInterval(86_400)
        )
        let set = [loop, line]

        let first = derivedNames(set)
        XCTAssertEqual(derivedNames(set), first)

        let unrelated = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 2_000, date: day.addingTimeInterval(172_800)),
            date: day.addingTimeInterval(172_800)
        )
        var grown = derivedNames(set + [unrelated])
        grown[unrelated.id] = nil

        XCTAssertEqual(grown, first, "adding a non-colliding group must not rename existing ones")
    }

    /// Ordinary GPS jitter on the representative must not flip the compass
    /// sector: the token is a property of the route's extent, and sectors
    /// are 45° wide.
    func testTokenStableAcrossRepresentativeGPSNoise() throws {
        let day = RouteGroupingFixtures.epoch
        let clean = RouteGroupingFixtures.squareLoop(sideMeters: 1_250, date: day)
        let noisy = RouteGroupingFixtures.seededNoise(on: clean, noiseMeters: 12, seed: 4_242)
        // Same base name, different compass sector — the collision partner
        // that forces the token to appear at all.
        let partner = RouteGroupingFixtures.rectangleLoop(widthMeters: 2_400, heightMeters: 100, mirrored: true, date: day.addingTimeInterval(86_400))

        let cleanGroup = RouteGroupingFixtures.group(representative: clean, date: day)
        let noisyGroup = RouteGroupingFixtures.group(representative: noisy, date: day)
        let partnerGroup = RouteGroupingFixtures.group(
            representative: partner,
            date: day.addingTimeInterval(86_400)
        )

        let withClean = try derivedName(of: cleanGroup, in: derivedNames([cleanGroup, partnerGroup]))
        let withNoisy = try derivedName(of: noisyGroup, in: derivedNames([noisyGroup, partnerGroup]))

        XCTAssertTrue(withClean.hasSuffix("Loop (NE)"), "got \(withClean)")
        XCTAssertEqual(withNoisy, withClean)
    }

    func testMissingRepresentativeSummaryFallsBackWithoutCrashing() throws {
        let plain = WorkoutRouteGroup()
        let healthy = RouteGroupingFixtures.group(
            representative: RouteGroupingFixtures.squareLoop(sideMeters: 1_250),
            date: RouteGroupingFixtures.epoch
        )

        let names = derivedNames([plain, healthy])

        XCTAssertEqual(try derivedName(of: plain, in: names), "Route")
        XCTAssertEqual(
            try derivedName(of: healthy, in: names),
            WorkoutRouteGroup.defaultDisplayName(distanceMeters: 5_000, closesLoop: true)
        )

        // Two summary-less groups still never collide: the numeric terminal
        // fallback applies to the plain fallback name too. Their relative
        // order is id-tiebroken, so assert the pair, not the assignment.
        let other = WorkoutRouteGroup()
        let pair = derivedNames([plain, other])
        let pairNames = Set(pair.values)
        XCTAssertEqual(pairNames, ["Route", "Route (2)"])
    }
}
