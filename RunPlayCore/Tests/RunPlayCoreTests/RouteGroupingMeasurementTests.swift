import XCTest
@testable import RunPlayCore

/// Measurement harness for the mutual-coverage match rule.
///
/// Env-gated (RUNPLAY_ROUTE_GROUPING_MEASURE=1); never runs in CI. Prints a
/// grid over {budget: 500, 250, 100, 40 m} × the fixture classes, giving
/// for each cell: coverage of each route, median and p90 separation, and
/// whether the solve succeeded. This grid is the evidence behind the
/// product (budget, coverage-threshold) pair; re-run it before changing
/// either value.
///
/// The interaction to watch before choosing a pair: the engine truncates
/// freely within the unmatched budget, so a route's own coverage ceiling is
/// 1 − budget/route-length (whenever the 10 % fraction cap does not bite
/// first). At a 500 m budget a 3 km route tops out near 0.83, so a fixed
/// 0.85 threshold would reject identical short routes — which is why the
/// grid includes a 2 km identical pair and the chosen pair keeps it above
/// the threshold with margin.
final class RouteGroupingMeasurementTests: XCTestCase {
    private let matcher = RouteGroupingMatcher()

    private func measure(
        _ name: String,
        workout: RunWorkout,
        representative: RunWorkout,
        policy: RouteGroupingPolicy
    ) throws {
        let outcome = try matcher.match(
            workout: workout,
            workoutFacts: RouteGroupingRouteFacts(workout: workout),
            representative: representative,
            representativeFacts: RouteGroupingRouteFacts(workout: representative),
            policy: policy,
            isCancelled: { false }
        )
        let solved = outcome.noMatchReason != .noPath
            && outcome.noMatchReason != .resourceLimit
            && outcome.noMatchReason != .filteredOut
        print(String(
            format: "MEASURE | %@ | solved=%@ | match=%@ | covPrimary=%.3f | covComparison=%.3f | mutual=%.3f | med=%.1f | p90=%.1f | unmatchedAbs=%.1f | unmatchedFrac=%.4f",
            name,
            solved ? "yes" : "NO",
            outcome.matches ? "MATCH" : "no",
            outcome.primaryCoverage,
            outcome.comparisonCoverage,
            outcome.mutualCoverage,
            outcome.medianSeparationMeters.isFinite ? outcome.medianSeparationMeters : -1,
            outcome.p90SeparationMeters.isFinite ? outcome.p90SeparationMeters : -1,
            outcome.unmatchedLongerRouteMeters.isFinite ? outcome.unmatchedLongerRouteMeters : -1,
            outcome.unmatchedLongerRouteFraction.isFinite ? outcome.unmatchedLongerRouteFraction : -1
        ))
    }

    func testMutualCoverageGrid() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUNPLAY_ROUTE_GROUPING_MEASURE"] == "1",
            "Set RUNPLAY_ROUTE_GROUPING_MEASURE=1 to print the mutual-coverage grid"
        )
        let epoch = RouteGroupingFixtures.epoch
        let day: (Int) -> Date = { epoch.addingTimeInterval(Double($0) * 86_400) }

        // Fixture classes (must-match: identical-with-noise, reversed,
        // identical-short; must-reject: loop-plus-spur, both prefixes,
        // 40 %-shared).
        let cleanLoop = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 0, noiseMeters: 0)
        let noisyLoop = RouteGroupingFixtures.loopRepeat(sideMeters: 1_250, index: 1, noiseMeters: 12)
        let reversedPoints = RouteGroupingFixtures.reversed(cleanLoop.routePoints, date: day(1))
        let reversedLoop = RouteGroupingFixtures.workout(points: reversedPoints, date: day(1))
        let superset = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.loopWithSpur(sideMeters: 1_250, spurMeters: 800, date: day(2)),
            date: day(2)
        )
        let line6 = RouteGroupingFixtures.workout(points: RouteGroupingFixtures.straightLine(distanceMeters: 6_000, date: day(3)), date: day(3))
        let prefix5of6 = RouteGroupingFixtures.workout(points: RouteGroupingFixtures.straightLine(distanceMeters: 5_000, date: day(4)), date: day(4))
        let line10 = RouteGroupingFixtures.workout(points: RouteGroupingFixtures.straightLine(distanceMeters: 10_000, date: day(5)), date: day(5))
        let prefix5of10 = RouteGroupingFixtures.workout(points: RouteGroupingFixtures.straightLine(distanceMeters: 5_000, date: day(6)), date: day(6))
        let north = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.rectangleLoop(widthMeters: 1_000, heightMeters: 400, date: day(7)),
            date: day(7)
        )
        let south = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.rectangleLoop(widthMeters: 1_000, heightMeters: 400, mirrored: true, date: day(8)),
            date: day(8)
        )
        // Short identical pair (~2 km): the budget/coverage interaction made
        // explicit in the grid rather than inferred.
        let cleanShort = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.squareLoop(sideMeters: 500, date: day(9)),
            date: day(9)
        )
        let noisyShort = RouteGroupingFixtures.workout(
            points: RouteGroupingFixtures.seededNoise(
                on: RouteGroupingFixtures.squareLoop(sideMeters: 500, date: day(10)),
                noiseMeters: 12,
                seed: 4_242
            ),
            date: day(10)
        )

        for budget in [500.0, 250.0, 100.0, 40.0] {
            var policy = RouteGroupingPolicy.default
            policy.unmatchedBudgetMeters = budget
            // Neutralize stage 1 so every class reaches the solve at every
            // budget — the grid measures stage 2, and distant fixtures
            // would otherwise be filtered before measurement.
            policy.boundingBoxOverlapMarginMeters = 1e9
            policy.endpointProximityMeters = 1e9

            print("MEASURE-GRID budget=\(Int(budget))")
            try measure("identical-noise       new=noisy    rep=clean ", workout: noisyLoop, representative: cleanLoop, policy: policy)
            try measure("identical-short(~2km) new=noisy    rep=clean ", workout: noisyShort, representative: cleanShort, policy: policy)
            try measure("reversed              new=rev      rep=fwd   ", workout: reversedLoop, representative: cleanLoop, policy: policy)
            try measure("loop+spur             new=superset rep=loop  ", workout: superset, representative: cleanLoop, policy: policy)
            try measure("loop+spur             new=loop     rep=superset", workout: cleanLoop, representative: superset, policy: policy)
            try measure("prefix 5of6           new=prefix   rep=long  ", workout: prefix5of6, representative: line6, policy: policy)
            try measure("prefix 5of6           new=long     rep=prefix", workout: line6, representative: prefix5of6, policy: policy)
            try measure("prefix 5of10          new=prefix   rep=long  ", workout: prefix5of10, representative: line10, policy: policy)
            try measure("40pct-shared          new=south    rep=north ", workout: south, representative: north, policy: policy)
        }
    }
}
