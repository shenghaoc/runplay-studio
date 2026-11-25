import Testing
import RunPlayEngine
import RunPlayEngineTestSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite
struct RouteAlignmentDtwTests {
    private typealias Sample = RouteAlignmentDtwSample
    private typealias Policy = RouteAlignmentDtwPolicy
    private typealias Path = RouteAlignmentDtwPath
    private typealias Cell = RouteAlignmentDtwCell
    private typealias Step = RouteAlignmentDtwStep

    private static var tight: Policy {
        var policy = Policy()
        policy.bandWidthFraction = 1
        policy.maximumConsecutiveWarpSteps = 6
        policy.spatialDistanceCostScaleMeters = 1
        policy.maximumSpatialCost = 1e9
        policy.maximumBandCells = 1_000_000
        return policy
    }

    private static var product: Policy {
        var policy = tight
        policy.bandWidthFraction = 0.15
        policy.maximumUnmatchedPrefixSuffixMeters = 500
        policy.maximumUnmatchedPrefixSuffixFraction = 0.10
        policy.nonDiagonalStepPenalty = 0.35
        policy.spatialDistanceCostScaleMeters = 50
        policy.maximumSpatialCost = 8
        policy.headingPenaltyWeight = 0.45
        policy.progressPenaltyWeight = 1.5
        policy.maximumBandCells = 4_000_000
        return policy
    }

    private static let six = line([0, 10, 20, 30, 40, 50])
    private static let five = line([0, 10, 20, 30, 40])
    private static let stretched = line([0, 10, 10, 20, 30, 40])
    private static let prefixBase = line([0, 25, 50, 75, 100, 125])

    private static func line(_ positions: [Double]) -> [Sample] {
        positions.map { Sample(xMeters: $0) }
    }

    private static func samples(_ count: Int, spacing: Double) -> [Sample] {
        (0..<count).map { Sample(xMeters: Double($0) * spacing, normalizedProgress: Double($0) / Double(count - 1)) }
    }

    private static func cell(_ i: Int, _ j: Int, _ step: Step = .diagonal) -> Cell {
        Cell(primaryIndex: i, comparisonIndex: j, step: step)
    }

    private static func diagonal(_ count: Int) -> [Cell] { (0..<count).map { cell($0, $0) } }

    private static func solve(
        _ primary: [Sample], _ comparison: [Sample], policy: Policy = tight,
        primaryMeters: Double = 1_000, comparisonMeters: Double = 1_000, interval: Double = 20
    ) throws(RouteAlignmentDtwError) -> Path {
        try RouteAlignmentDtw.solve(
            primary: primary.span, comparison: comparison.span, primaryRouteDistanceMeters: primaryMeters,
            comparisonRouteDistanceMeters: comparisonMeters, effectiveSampleIntervalMeters: interval, policy: policy
        )
    }

    private static func accepted(
        _ primary: [Sample], _ comparison: [Sample], policy: Policy = tight,
        primaryMeters: Double = 1_000, comparisonMeters: Double = 1_000, interval: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Path {
        let path = try solve(
            primary, comparison, policy: policy,
            primaryMeters: primaryMeters, comparisonMeters: comparisonMeters, interval: interval
        )
        #expect(!path.cells.isEmpty, sourceLocation: sourceLocation)
        #expect(path.cells.count <= primary.count + comparison.count + 1, sourceLocation: sourceLocation)
        #expect(path.cells.first == cell(0, 0), sourceLocation: sourceLocation)
        for entry in path.cells {
            #expect((0..<primary.count).contains(entry.primaryIndex), sourceLocation: sourceLocation)
            #expect((0..<comparison.count).contains(entry.comparisonIndex), sourceLocation: sourceLocation)
        }
        for (previous, next) in zip(path.cells, path.cells.dropFirst()) {
            let di = next.primaryIndex - previous.primaryIndex
            let dj = next.comparisonIndex - previous.comparisonIndex
            switch next.step {
            case .diagonal: #expect(di == 1 && dj == 1, sourceLocation: sourceLocation)
            case .primaryOnly: #expect(di == 1 && dj == 0, sourceLocation: sourceLocation)
            case .comparisonOnly: #expect(di == 0 && dj == 1, sourceLocation: sourceLocation)
            }
        }
        return path
    }

    private static func rejected(
        _ error: RouteAlignmentDtwError, _ primary: [Sample], _ comparison: [Sample], policy: Policy = tight,
        primaryMeters: Double = 1_000, comparisonMeters: Double = 1_000, interval: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let sentinel = try? solve(six, six, policy: tight)
        var output = sentinel
        do {
            output = try solve(
                primary, comparison, policy: policy,
                primaryMeters: primaryMeters, comparisonMeters: comparisonMeters, interval: interval
            )
            Issue.record("Unexpected success rather than \(error)", sourceLocation: sourceLocation)
        } catch let failure {
            #expect(failure == error, sourceLocation: sourceLocation)
        }
        #expect(output?.cells == sentinel?.cells, sourceLocation: sourceLocation)
        #expect(output?.bestEndCost.bitPattern == sentinel?.bestEndCost.bitPattern, sourceLocation: sourceLocation)
    }

    @Test func test_type_contract() {
        #expect(Step.diagonal.rawValue == 0)
        #expect(Step.primaryOnly.rawValue == 1)
        #expect(Step.comparisonOnly.rawValue == 2)
        let sample = Sample()
        #expect(sample.xMeters == 0)
        #expect(sample.zMeters == 0)
        #expect(sample.normalizedProgress == 0)
        #expect(sample.headingRadians == 0)
        #expect(sample.hasHeading == 0)
        let policy = Policy()
        #expect(policy.bandWidthFraction == 0)
        #expect(policy.maximumConsecutiveWarpSteps == 0)
        #expect(policy.maximumBandCells == 0)
        // No zeroed success summary exists; only a successful solve can make
        // the owned output. Its first path cell has the native default fields.
    }

    @Test func test_buffer_contracts() throws {
        // Span cannot describe a positive count with a null pointer.
        Self.rejected(.invalidInputContract, [], Self.six)
        Self.rejected(.invalidInputContract, Self.six, [])
        Self.rejected(.invalidInputContract, [], [])
        // The solver owns output capacity and returns only initialized cells.
        let solved = try Self.accepted(Self.six, Self.six)
        #expect(solved.cells == Self.diagonal(5))
        #expect(solved.bandRadius == 6)
        #expect(solved.bandCellCount == 36)
    }

    @Test func test_input_contracts() throws {
        let invalid: [Sample] = [
            Sample(xMeters: .nan), Sample(xMeters: .infinity),
            Sample(zMeters: .nan), Sample(zMeters: .infinity),
            Sample(normalizedProgress: -0.1), Sample(normalizedProgress: 1.1),
            Sample(normalizedProgress: .nan), Sample(hasHeading: 2), Sample(hasHeading: 255),
            Sample(headingRadians: .nan, hasHeading: 1), Sample(headingRadians: .infinity, hasHeading: 1),
        ]
        for point in invalid {
            var primary = Self.six
            primary[2] = point
            Self.rejected(.invalidInputContract, primary, Self.six)
            Self.rejected(.invalidInputContract, Self.six, primary)
        }
        for measure: Double in [.nan, .infinity, 0, -1] {
            Self.rejected(.invalidInputContract, Self.six, Self.six, primaryMeters: measure)
            Self.rejected(.invalidInputContract, Self.six, Self.six, comparisonMeters: measure)
            Self.rejected(.invalidInputContract, Self.six, Self.six, interval: measure)
        }
        var accepted = Self.six
        accepted[0] = Sample(normalizedProgress: 0, headingRadians: .pi, hasHeading: 1)
        accepted[5] = Sample(xMeters: 50, normalizedProgress: 1, headingRadians: .nan, hasHeading: 0)
        _ = try Self.accepted(accepted, accepted)
    }

    @Test func test_policy_contracts() {
        for (field, value): (WritableKeyPath<Policy, Double>, Double) in [
            (\.bandWidthFraction, .nan), (\.bandWidthFraction, .infinity),
            (\.maximumUnmatchedPrefixSuffixMeters, .infinity), (\.maximumUnmatchedPrefixSuffixFraction, .nan),
            (\.nonDiagonalStepPenalty, .nan), (\.spatialDistanceCostScaleMeters, .infinity),
            (\.maximumSpatialCost, .nan), (\.headingPenaltyWeight, .nan), (\.progressPenaltyWeight, .infinity),
        ] {
            var policy = Self.tight
            policy[keyPath: field] = value
            Self.rejected(.invalidPolicy, Self.six, Self.six, policy: policy)
        }
    }

    @Test func test_resource_limits() throws {
        var policy = Self.tight
        policy.maximumBandCells = 54
        Self.rejected(.resourceLimit, Self.five, Self.five, policy: policy)
        policy.maximumBandCells = 55
        let early = try Self.accepted(Self.five, Self.five, policy: policy)
        #expect(early.bandRadius == 5)
        #expect(early.bandCellCount == 25)
        #expect(early.cells == Self.diagonal(4))
        policy.maximumBandCells = 0
        Self.rejected(.resourceLimit, Self.five, Self.five, policy: policy)

        let (primary, comparison, expanded) = Self.expandedFixture()
        policy = expanded
        policy.maximumBandCells = 210
        Self.rejected(.resourceLimit, primary, comparison, policy: policy, primaryMeters: 400, comparisonMeters: 400, interval: 100)
        policy.maximumBandCells = 211
        let exact = try Self.accepted(primary, comparison, policy: policy, primaryMeters: 400, comparisonMeters: 400, interval: 100)
        #expect(exact.bandRadius == 4)
        #expect(exact.bandCellCount == 211)
        #expect(exact.cells.count == 96)
        #expect(exact.cells.last?.primaryIndex == 19)
        #expect(exact.cells.last?.comparisonIndex == 95)

        // Finite policy that overflows when converted to a radius. The
        // saturated width still fails the preallocation estimate safely.
        policy = Self.tight
        policy.maximumBandCells = .max
        policy.bandWidthFraction = .greatestFiniteMagnitude
        Self.rejected(.resourceLimit, Self.five, Self.five, policy: policy)
        policy.bandWidthFraction = -.greatestFiniteMagnitude
        let negativeRadius = try Self.accepted(Self.five, Self.five, policy: policy)
        #expect(negativeRadius.bandRadius == 1)
    }

    @Test func test_warp_limits() throws {
        var policy = Self.tight
        policy.maximumConsecutiveWarpSteps = 0
        #expect(try Self.accepted(Self.six, Self.six, policy: policy).cells == Self.diagonal(5))
        let zero = try Self.accepted(Self.stretched, Self.six, policy: policy)
        #expect(zero.cells == [
            Self.cell(0, 0), Self.cell(1, 0, .primaryOnly), Self.cell(2, 1),
            Self.cell(3, 2), Self.cell(4, 3), Self.cell(5, 4),
        ])
        expectEqualBits(zero.bestEndCost, 10)

        policy.maximumConsecutiveWarpSteps = 2
        let capped = try Self.accepted(Self.line([0, 5, 5, 5, 5, 5, 5, 60]), Self.line([0, 5, 60]), policy: policy)
        #expect(capped.cells == [
            Self.cell(0, 0), Self.cell(1, 1), Self.cell(2, 1, .primaryOnly), Self.cell(3, 1, .primaryOnly),
            Self.cell(4, 2), Self.cell(5, 2, .primaryOnly), Self.cell(6, 2, .primaryOnly),
        ])

        let narrow = Self.line([0, 0])
        let wide = Self.line((0..<400).map(Double.init))
        policy.maximumConsecutiveWarpSteps = 255
        Self.rejected(.noPath, narrow, wide, policy: policy)
        policy.maximumConsecutiveWarpSteps = 256
        let saturated = try Self.accepted(narrow, wide, policy: policy)
        #expect(saturated.bandRadius == 400)
        #expect(saturated.bandCellCount == 800)
        #expect(saturated.cells.count == 399)
        #expect(saturated.cells.last?.primaryIndex == 1)
        #expect(saturated.cells.last?.comparisonIndex == 398)
        expectEqualBits(saturated.bestEndCost, 79_401)
        #expect(saturated.cells.suffix(396).allSatisfy { $0.step == .comparisonOnly })
        policy.maximumConsecutiveWarpSteps = 1_000_000_000
        #expect(try Self.accepted(narrow, wide, policy: policy).cells == saturated.cells)
    }

    @Test func test_point_cost() throws {
        let zero = Sample()
        let identical = Sample(xMeters: 12.5, zMeters: -7.5, normalizedProgress: 0.5)
        let origin = try Self.accepted([identical], [identical])
        #expect(origin.cells == [Self.cell(0, 0)])
        #expect(origin.bandCellCount == 1)
        expectEqualBits(origin.bestEndCost, 0)
        let offset = Sample(xMeters: 3, zMeters: 4)
        var policy = Self.tight
        policy.spatialDistanceCostScaleMeters = 2
        policy.maximumSpatialCost = 1_000
        expectEqualBits(try Self.accepted([zero], [offset], policy: policy).bestEndCost, 2.5)
        policy.spatialDistanceCostScaleMeters = 0.25
        expectEqualBits(try Self.accepted([zero], [offset], policy: policy).bestEndCost, 5)
        policy = Self.tight
        policy.maximumSpatialCost = 8
        expectEqualBits(try Self.accepted([zero], [Sample(xMeters: 3_000, zMeters: 4_000)], policy: policy).bestEndCost, 8)

        policy = Self.tight
        policy.headingPenaltyWeight = 0.45
        let north = Sample(headingRadians: 0, hasHeading: 1)
        let south = Sample(headingRadians: .pi, hasHeading: 1)
        let heading = Sample(headingRadians: 1.25, hasHeading: 1)
        expectEqualBits(try Self.accepted([north], [zero], policy: policy).bestEndCost, 0)
        expectEqualBits(try Self.accepted([zero], [south], policy: policy).bestEndCost, 0)
        expectEqualBits(try Self.accepted([heading], [heading], policy: policy).bestEndCost, 0)
        expectEqualBits(try Self.accepted([north], [south], policy: policy).bestEndCost, 0.45)
        expectEqualBits(try Self.accepted(
            [Sample(headingRadians: 3, hasHeading: 1)], [Sample(headingRadians: -3, hasHeading: 1)], policy: policy
        ).bestEndCost, ((2 * Double.pi - 6) / Double.pi) * 0.45)

        policy = Self.tight
        policy.progressPenaltyWeight = 1.5
        expectEqualBits(try Self.accepted(
            [Sample(normalizedProgress: 0.25)], [Sample(normalizedProgress: 0.75)], policy: policy
        ).bestEndCost, 0.75)
        policy = Self.tight
        policy.headingPenaltyWeight = -2
        expectEqualBits(try Self.accepted([north], [south], policy: policy).bestEndCost, -2)

        policy.maximumSpatialCost = 1e300
        policy.headingPenaltyWeight = 1e308
        policy.progressPenaltyWeight = 1e308
        expectEqualBits(try Self.accepted(
            [north], [Sample(normalizedProgress: 1, headingRadians: .pi, hasHeading: 1)], policy: policy
        ).bestEndCost, 1e300)
        policy = Self.tight
        policy.maximumSpatialCost = 1e308
        Self.rejected(.noPath, [zero], [Sample(xMeters: 1e308)], policy: policy)
    }

    @Test func test_paths() throws {
        let identical = try Self.accepted(Self.six, Self.six)
        #expect(identical.bandRadius == 6)
        #expect(identical.bandCellCount == 36)
        #expect(identical.cells == Self.diagonal(5))
        expectEqualBits(identical.bestEndCost, 0)
        let flat = Self.line([0, 0, 0, 0])
        #expect(try Self.accepted(flat, flat).cells == Self.diagonal(3))

        let tie = try Self.accepted(Self.line([0, 10, -9, 1_000]), Self.line([0, -10, 11, -1_000]))
        expectEqualBits(tie.bestEndCost, 31)
        #expect(tie.cells == [Self.cell(0, 0), Self.cell(0, 1, .comparisonOnly), Self.cell(1, 2), Self.cell(2, 2, .primaryOnly)])

        let primary = try Self.accepted(Self.stretched, Self.five)
        #expect(primary.bandCellCount == 30)
        expectEqualBits(primary.bestEndCost, 0)
        #expect(primary.cells == Self.primaryWarp)
        let comparison = try Self.accepted(Self.five, Self.stretched)
        #expect(comparison.bandCellCount == 30)
        #expect(comparison.cells == [
            Self.cell(0, 0), Self.cell(1, 1), Self.cell(1, 2, .comparisonOnly), Self.cell(2, 3), Self.cell(3, 4),
        ])

        let prefix = try Self.accepted(
            Self.prefixBase, Self.line([-1_000, -1_001]) + Self.prefixBase,
            policy: Self.open, primaryMeters: 100, comparisonMeters: 100, interval: 25
        )
        #expect(prefix.bandRadius == 8)
        expectEqualBits(prefix.bestEndCost, 2_001)
        #expect(prefix.cells == [Self.cell(0, 0), Self.cell(0, 1, .comparisonOnly), Self.cell(0, 2, .comparisonOnly), Self.cell(1, 3)])
        let suffix = try Self.accepted(
            Self.prefixBase, Self.prefixBase + Self.line([5_000, 5_001]),
            policy: Self.open, primaryMeters: 100, comparisonMeters: 100, interval: 25
        )
        expectEqualBits(suffix.bestEndCost, 0)
        #expect(suffix.cells == Self.diagonal(4))

        let mixedPrimary = (0..<64).map { i in
            let t = Double(i)
            return Sample(xMeters: t * 9, zMeters: sin(t * 0.25) * 30, normalizedProgress: t / 63, headingRadians: cos(t * 0.1), hasHeading: 1)
        }
        let mixedComparison = (0..<70).map { i in
            let t = Double(i)
            return Sample(xMeters: t * 8 + 4, zMeters: sin(t * 0.23) * 28, normalizedProgress: t / 69, headingRadians: cos(t * 0.11), hasHeading: 1)
        }
        var mixedPolicy = Self.product
        mixedPolicy.bandWidthFraction = 0.5
        let first = try Self.accepted(mixedPrimary, mixedComparison, policy: mixedPolicy, primaryMeters: 1_200, comparisonMeters: 1_300)
        let second = try Self.accepted(mixedPrimary, mixedComparison, policy: mixedPolicy, primaryMeters: 1_200, comparisonMeters: 1_300)
        #expect(first.cells == second.cells)
        #expect(first.bandCellCount == second.bandCellCount)
        expectEqualBits(first.bestEndCost, second.bestEndCost)
    }

    private static let primaryWarp = [cell(0, 0), cell(1, 1), cell(2, 1, .primaryOnly), cell(3, 2), cell(4, 3)]

    private static var open: Policy {
        var policy = tight
        policy.maximumUnmatchedPrefixSuffixMeters = 100
        policy.maximumUnmatchedPrefixSuffixFraction = 1
        return policy
    }

    @Test func test_step_penalty() throws {
        var policy = Self.tight
        policy.nonDiagonalStepPenalty = 0.4
        let warp = try Self.accepted(Self.stretched, Self.five, policy: policy)
        #expect(warp.cells == Self.primaryWarp)
        expectEqualBits(warp.bestEndCost, 0.4)
        policy = Self.open
        policy.nonDiagonalStepPenalty = 0.4
        let row = try Self.accepted(
            Self.prefixBase, Self.line([-1_000, -1_001]) + Self.prefixBase,
            policy: policy, primaryMeters: 100, comparisonMeters: 100, interval: 25
        )
        #expect(row.cells.count == 4)
        #expect(abs(row.bestEndCost - 2_001.2) <= 1e-9)
        policy = Self.tight
        policy.nonDiagonalStepPenalty = 0.4
        policy.maximumConsecutiveWarpSteps = 0
        let column = try Self.accepted(Self.stretched, Self.six, policy: policy)
        #expect(column.cells.count == 6)
        #expect(abs(column.bestEndCost - 10.1) <= 1e-9)
    }

    private static func expandedFixture() -> ([Sample], [Sample], Policy) {
        var policy = tight
        policy.bandWidthFraction = 0.01
        policy.maximumUnmatchedPrefixSuffixMeters = 400
        policy.maximumUnmatchedPrefixSuffixFraction = 1
        return (samples(20, spacing: 5), samples(100, spacing: 1), policy)
    }

    private static func band(_ n: Int, _ m: Int, radius: Int, open: Int) -> [ClosedRange<Int>] {
        (0..<n).map { i in
            let center = Int(Double(i) / Double(max(n - 1, 1)) * Double(max(m - 1, 1)))
            let start = i < open ? 0 : max(0, center - radius)
            let end = i >= n - open ? m - 1 : min(m - 1, center + radius)
            return start...end
        }
    }

    @Test func test_band_geometry() throws {
        var policy = Self.tight
        policy.bandWidthFraction = 0.02
        let narrow = try Self.accepted(Self.samples(100, spacing: 10), Self.samples(100, spacing: 5), policy: policy)
        let narrowRows = Self.band(100, 100, radius: 2, open: 1)
        #expect(narrow.bandRadius == 2)
        #expect(narrow.bandCellCount == 494)
        #expect(narrow.cells.allSatisfy { narrowRows[$0.primaryIndex].contains($0.comparisonIndex) })
        #expect(narrow.cells.contains { narrowRows[$0.primaryIndex].upperBound == $0.comparisonIndex })
        policy.bandWidthFraction = 0.15
        let seven = Self.line([0, 10, 20, 30, 40, 50, 60])
        let fractional = try Self.accepted(seven, seven, policy: policy)
        #expect(fractional.bandRadius == 2)
        #expect(fractional.bandCellCount == 29)

        let (primary, comparison, expanded) = Self.expandedFixture()
        let widened = try Self.accepted(primary, comparison, policy: expanded, primaryMeters: 400, comparisonMeters: 400, interval: 100)
        let rows = Self.band(20, 100, radius: 4, open: 4)
        #expect(rows[1] == 0...9)
        #expect(rows[16] == 79...99)
        #expect(rows[10] == 48...56)
        #expect(widened.bandRadius == 4)
        #expect(widened.bandCellCount == 211)
        #expect(widened.cells.allSatisfy { rows[$0.primaryIndex].contains($0.comparisonIndex) })

        let shorter = Self.samples(30, spacing: 15)
        let longer = Self.samples(45, spacing: 10)
        policy.bandWidthFraction = 0.1
        let wide = try Self.accepted(shorter, longer, policy: policy)
        let tall = try Self.accepted(longer, shorter, policy: policy)
        #expect(wide.bandRadius == 5)
        #expect(wide.bandCellCount == 309)
        #expect(tall.bandRadius == 5)
        #expect(tall.bandCellCount == 450)
        let wideRows = Self.band(30, 45, radius: 5, open: 1)
        let tallRows = Self.band(45, 30, radius: 5, open: 1)
        #expect(wide.cells.allSatisfy { wideRows[$0.primaryIndex].contains($0.comparisonIndex) })
        #expect(tall.cells.allSatisfy { tallRows[$0.primaryIndex].contains($0.comparisonIndex) })
    }

    @Test func test_large_shapes() throws {
        let samples = Self.samples(2_000, spacing: 20)
        let standard = try Self.accepted(samples, samples, policy: Self.product, primaryMeters: 40_000, comparisonMeters: 40_000)
        #expect(standard.bandRadius == 300)
        #expect(standard.bandCellCount == 1_111_690)
        #expect(standard.cells == Self.diagonal(1_975))
        expectEqualBits(standard.bestEndCost, 0)

        var policy = Self.tight
        policy.spatialDistanceCostScaleMeters = 50
        policy.maximumSpatialCost = 8
        policy.maximumBandCells = 8_002_000
        let full = try Self.accepted(samples, samples, policy: policy, primaryMeters: 40_000, comparisonMeters: 40_000)
        #expect(full.bandRadius == 2_000)
        #expect(full.bandCellCount == 4_000_000)
        #expect(full.cells.count == 1_999)
        #expect(full.cells.last?.primaryIndex == 1_998)
    }
}
