import Testing
import RunPlayEngine
import RunPlayEngineTestSupport

@Suite
struct SegmentDetectionTests {
    private typealias Sample = SegmentDetectionSample
    private typealias Config = SegmentDetectionConfiguration
    private typealias Candidate = SegmentDetectionCandidate
    private typealias Kind = SegmentDetectionKind

    private static func point(
        _ distance: Double = 0, _ elapsed: Double = 0, _ active: Double = 0, _ ascent: Double = 0,
        _ descent: Double = 0, _ reliableCount: Double = 0, _ group: Int32 = 0, _ run: Int32 = -1
    ) -> Sample {
        var sample = Sample()
        sample.distance = distance
        sample.elapsed = elapsed
        sample.active = active
        sample.ascent = ascent
        sample.descent = descent
        sample.reliableCount = reliableCount
        sample.continuityGroup = group
        sample.reliableRun = run
        return sample
    }

    private static var config: Config {
        var c = Config()
        c.maximumEvaluations = 1_000
        return c
    }

    private static func solve(_ points: [Sample], _ config: Config = config) throws(SegmentDetectionError) -> SegmentDetectionResult {
        try SegmentDetection.search(points.span, configuration: config)
    }

    private static func values(_ result: SegmentDetectionResult) -> [Candidate] {
        (0..<result.candidateCount).map { result.candidates[$0] }
    }

    private static func rejects(
        _ error: SegmentDetectionError, _ points: [Sample], _ config: Config = config,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: error, sourceLocation: sourceLocation) { try solve(points, config) }
    }

    @Test func test_compile_time() {
        let check: InlineArray<10, Candidate>.Type = InlineArray<10, Candidate>.self
        #expect(check == InlineArray<10, Candidate>.self)
        #expect(Kind.fastest400m.rawValue == 0)
        #expect(Kind.fastestMarathon.rawValue == 9)
    }

    @Test func test_empty_input() throws {
        let result = try Self.solve([], Config())
        #expect(result.candidateCount == 0)
        #expect(result.paceEvaluationCount == 0)
        #expect(result.elevationEvaluationCount == 0)
    }

    @Test func test_one_sample() throws {
        #expect(try Self.solve([Self.point()]).candidateCount == 0)
    }

    @Test func test_output_unchanged_on_error() throws {
        let prior = try Self.solve([Self.point(), Self.point(1, 10, 10)])
        var result = prior
        do {
            result = try Self.solve([Self.point(), Self.point(1, 10, 10)], Config())
            Issue.record("Expected invalid configuration")
        } catch let error {
            #expect(error == .invalidConfiguration)
        }
        #expect(result.candidateCount == prior.candidateCount)
        #expect(result.paceEvaluationCount == prior.paceEvaluationCount)
    }

    @Test func test_invalid_config_nan_distance() {
        var cfg = Self.config
        cfg.fastest400m.distance = .nan
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
    }

    @Test func test_invalid_config_zero_distance() {
        var cfg = Self.config
        cfg.fastest400m.distance = 0
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
    }

    @Test func test_invalid_config_inverted_pace() {
        var cfg = Self.config
        cfg.minimumPace = 500
        cfg.maximumPace = 200
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
    }

    @Test func test_invalid_elevation_enabled_byte() {
        var cfg = Self.config
        cfg.elevationEnabled = 2
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
    }

    @Test func test_nonfinite_distance() {
        Self.rejects(.invalidInputContract, [Self.point(), Self.point(.nan, 10, 10)])
    }

    @Test func test_decreasing_distance() {
        Self.rejects(.invalidInputContract, [Self.point(100), Self.point(50, 10, 10)])
    }

    @Test func test_decreasing_elapsed() {
        Self.rejects(.invalidInputContract, [Self.point(0, 100, 50), Self.point(100, 50, 50)])
    }

    @Test func test_continuity_group_not_zero() {
        Self.rejects(.invalidInputContract, [
            Self.point(0, 0, 0, 0, 0, 0, 1), Self.point(100, 10, 10, 0, 0, 0, 1),
        ])
    }

    @Test func test_first_active_time_cannot_exceed_elapsed_time() {
        Self.rejects(.invalidInputContract, [Self.point(0, 0, 1)])
    }

    @Test func test_first_reliable_run_must_be_zero_based() {
        Self.rejects(.invalidInputContract, [
            Self.point(0, 0, 0, 0, 0, 0, 0, 1), Self.point(100, 30, 30, 1, 0, 1, 0, 1),
        ])
    }

    @Test func test_reliable_run_cannot_cross_continuity_group() {
        Self.rejects(.invalidInputContract, [
            Self.point(0, 0, 0, 0, 0, 0, 0, 0), Self.point(100, 30, 30, 1, 0, 1, 1, 0),
        ])
    }

    @Test func test_constant_pace_route() throws {
        let samples = [Self.point(), Self.point(133.333, 32, 32), Self.point(266.667, 64, 64), Self.point(400, 96, 96)]
        var cfg = Self.config
        cfg.maximumEvaluations = 100
        let out = try #require(Self.values(Self.solve(samples, cfg)).first { $0.kind == .fastest400m })
        expectEqualBits(out.start, 0)
        #expect(abs(out.end - 400) < 1e-3)
    }

    @Test func test_pause_spanning_active_time() throws {
        let samples = [
            Self.point(), Self.point(500, 150, 150), Self.point(500, 1_150, 150, 0, 0, 0, 1),
            Self.point(1_000, 1_300, 300, 0, 0, 0, 1), Self.point(1_500, 1_600, 600, 0, 0, 0, 1),
            Self.point(2_000, 1_900, 900, 0, 0, 0, 1),
        ]
        let out = try #require(Self.values(Self.solve(samples)).first { $0.kind == .fastest1km })
        expectEqualBits(out.start, 0)
        expectEqualBits(out.end, 1_000)
        #expect(abs(out.value - 300) < 1e-6)
    }

    @Test func test_same_segment_distance_plateau_uses_first_arrival() throws {
        let samples = [Self.point(), Self.point(400, 300, 300), Self.point(400, 400, 400), Self.point(800, 500, 500)]
        var cfg = Self.config
        cfg.maximumEvaluations = 100
        let result = try Self.solve(samples, cfg)
        #expect(result.candidateCount == 1)
        #expect(result.candidates[0].kind == .fastest400m)
        expectEqualBits(result.candidates[0].start, 400)
        #expect(abs(result.candidates[0].value - 500) < 1e-9)
    }

    @Test func test_pause_plateau_uses_inner_segment_boundaries() throws {
        let samples = [
            Self.point(), Self.point(500, 150, 150), Self.point(500, 160, 160),
            Self.point(500, 1_160, 160, 0, 0, 0, 1), Self.point(500, 1_170, 170, 0, 0, 0, 1),
            Self.point(1_000, 1_320, 320, 0, 0, 0, 1),
        ]
        var cfg = Self.config
        cfg.fastest400m = .init(500, 500)
        cfg.oneKilometer.distance = 1_500
        cfg.maximumEvaluations = 10
        let result = try Self.solve(samples, cfg)
        #expect(result.candidateCount == 1)
        expectEqualBits(result.candidates[0].start, 0)
        #expect(abs(result.candidates[0].value - 320) < 1e-9)
    }

    @Test func test_each_search_has_its_own_evaluation_budget() throws {
        let samples = Self.constant(2_000)
        var cfg = Self.config
        cfg.fastest400m.step = 100
        cfg.oneKilometer.step = 100
        cfg.maximumEvaluations = 20
        let result = try Self.solve(samples, cfg)
        #expect(result.paceEvaluationCount == 36)
        #expect(Self.values(result).contains { $0.kind == .fastestOneMile })
    }

    @Test func test_finite_evaluation_quotient_beyond_uint64_is_resource_limited() {
        var cfg = Self.config
        cfg.fastest400m.step = 1
        Self.rejects(.resourceLimit, [Self.point(), Self.point(1e20, 1e12, 1e12)], cfg)
    }

    @Test func test_pace_uses_rounded_window_boundary_distance() throws {
        let start = 8_388_475.4963460555
        let end = start + 1_000
        var cfg = Self.config
        cfg.fastest400m.distance = 2_000
        cfg.maximumEvaluations = 10
        let result = try Self.solve([Self.point(start), Self.point(end, 300, 300)], cfg)
        #expect(result.candidateCount == 2)
        let expected = (300 / (end - start)) * 1_000
        expectEqualBits(result.candidates[0].value, expected)
        expectEqualBits(result.candidates[1].value, expected)
    }

    private static func constant(_ distance: Double, interval: Double = 100) -> [Sample] {
        (0...Int(distance / interval)).map { index in
            let d = Double(index) * interval
            let clock = d * 0.3
            return point(d, clock, clock)
        }
    }

    private static var recordsConfig: Config {
        var cfg = config
        cfg.maximumEvaluations = 100_000
        return cfg
    }

    @Test func test_personal_record_window_lengths() throws {
        let result = try Self.solve(Self.constant(12_000), Self.recordsConfig)
        let candidates = Self.values(result)
        #expect(candidates.map(\.kind) == [.fastest400m, .fastest1km, .slowest1km, .fastestOneMile, .fastest5km, .fastest10km])
        for value in candidates {
            switch value.kind {
            case .fastestOneMile: expectEqualBits(value.end - value.start, 1_609.344)
            case .fastest5km: expectEqualBits(value.end - value.start, 5_000)
            case .fastest10km: expectEqualBits(value.end - value.start, 10_000)
            default: break
            }
            if value.kind != .fastestOneMile { expectEqualBits(value.start, 0) }
            #expect(abs(value.value - 300) < 1e-9)
        }
    }

    @Test func test_window_longer_than_route_is_not_attempted() throws {
        let result = try Self.solve(Self.constant(4_000), Self.recordsConfig)
        let candidates = Self.values(result)
        #expect(candidates.map(\.kind) == [.fastest400m, .fastest1km, .slowest1km, .fastestOneMile])
        #expect(candidates.allSatisfy { $0.value > 0 })
    }

    @Test func test_exact_length_route_yields_whole_run_window() throws {
        let samples = Self.constant(42_195, interval: 42_195.0 / 2)
        let out = try #require(Self.values(Self.solve(samples, Self.recordsConfig)).first { $0.kind == .fastestMarathon })
        expectEqualBits(out.start, 0)
        expectEqualBits(out.end, 42_195)
        #expect(abs(out.value - 300) < 1e-9)
    }

    @Test func test_marathon_window_spanning_pause_uses_active_time() throws {
        let samples = [
            Self.point(), Self.point(21_097.5, 5_274.375, 5_274.375),
            Self.point(21_097.5, 5_774.375, 5_274.375, 0, 0, 0, 1),
            Self.point(42_195, 11_023.125, 10_548.75, 0, 0, 0, 1),
        ]
        let out = try #require(Self.values(Self.solve(samples, Self.recordsConfig)).first { $0.kind == .fastestMarathon })
        expectEqualBits(out.start, 0)
        expectEqualBits(out.end, 42_195)
        #expect(abs(out.value - 250) < 1e-6)
    }

    @Test func test_invalid_config_personal_record_windows() {
        var cfg = Self.config
        cfg.oneMile.distance = .nan
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
        cfg = Self.config
        cfg.fiveKilometers.step = 0
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
        cfg = Self.config
        cfg.marathon.distance = -42_195
        Self.rejects(.invalidConfiguration, [Self.point()], cfg)
    }

    @Test func test_biggest_climb() throws {
        let points = [
            Self.point(0, 0, 0, 0, 0, 0, 0, 0), Self.point(250, 60, 60, 10, 0, 1, 0, 0),
            Self.point(500, 120, 120, 20, 0, 2, 0, 0), Self.point(750, 180, 180, 30, 0, 3, 0, 0),
            Self.point(1_000, 240, 240, 50, 0, 4, 0, 0),
        ]
        var cfg = Self.config
        cfg.elevation = .init(500, 250)
        cfg.elevationEnabled = 1
        let out = try #require(Self.values(Self.solve(points, cfg)).first { $0.kind == .biggestClimb })
        #expect(out.value > 0)
    }

    @Test func test_flat_route_no_elevation() throws {
        let points = (0...4).map { Self.point(Double($0) * 250, Double($0) * 60, Double($0) * 60) }
        #expect(try Self.solve(points).elevationEvaluationCount == 0)
    }
}
