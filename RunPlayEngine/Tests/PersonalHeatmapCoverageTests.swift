import Testing
import RunPlayEngine
import RunPlayEngineTestSupport

/// Ported case for case from the former C++ `PersonalHeatmapCoverageTests.cpp`,
/// with the same names and literals.
@Suite
struct PersonalHeatmapCoverageTests {
    private typealias Sample = PersonalHeatmapRouteSample

    private static let quietNaN = Double.nan
    private static let infinity = Double.infinity

    private static func compute(
        _ samples: [Sample], _ cell: Double = 10.0, _ interval: Double = 500.0, _ maximumCells: UInt = 10_000
    ) throws(PersonalHeatmapCoverageError) -> PersonalHeatmapCoverageResult {
        try PersonalHeatmapCoverage.compute(
            samples: samples.span, cellSizeMeters: cell, maximumIntervalMeters: interval,
            maximumCellsPerInterval: maximumCells
        )
    }

    @Test func test_empty_and_boundary_errors() throws {
        let empty = try Self.compute([])
        #expect(empty.validProjectedPointCount == 0, "empty valid count")
        #expect(empty.effectiveSegmentCount == 0, "empty segment count")
        #expect(empty.invalidIntervalCount == 0, "empty invalid intervals")
        #expect(empty.cells.isEmpty, "empty required count")

        let sample = Sample(latitude: 37.7749, longitude: -122.4194, routeSegmentIndex: 0)
        #expect(throws: PersonalHeatmapCoverageError.invalidConfiguration, "zero cell size") {
            try Self.compute([sample], 0.0, 500.0)
        }
        #expect(throws: PersonalHeatmapCoverageError.invalidConfiguration, "negative cell size") {
            try Self.compute([sample], -10.0, 500.0)
        }
        #expect(throws: PersonalHeatmapCoverageError.invalidConfiguration, "zero max interval") {
            try Self.compute([sample], 10.0, 0.0)
        }
        #expect(throws: PersonalHeatmapCoverageError.invalidConfiguration, "zero max cells per interval") {
            try Self.compute([sample], 10.0, 500.0, 0)
        }
        // An empty route still validates its configuration.
        #expect(throws: PersonalHeatmapCoverageError.invalidConfiguration, "empty route with zero cell size") {
            try Self.compute([], 0.0, 500.0)
        }

        // One sample needs exactly one cell.
        let result = try Self.compute([sample])
        #expect(result.cells.count == 1, "required cell count is 1")
    }

    @Test func test_projection_and_cell_indexing() throws {
        let samples = [
            Sample(latitude: 0.0, longitude: 0.0, routeSegmentIndex: 0),              // equator & prime meridian
            Sample(latitude: 85.05112878, longitude: 180.0, routeSegmentIndex: 0),    // top right valid boundary
            Sample(latitude: -85.05112878, longitude: -180.0, routeSegmentIndex: 0),  // -180 normalizes to 180
            Sample(latitude: 89.0, longitude: 45.0, routeSegmentIndex: 0),            // lat > 85.05112878 clamped
            Sample(latitude: -89.0, longitude: -45.0, routeSegmentIndex: 0),          // lat < -85.05112878 clamped
            Sample(latitude: 100.0, longitude: 0.0, routeSegmentIndex: 0),            // invalid lat (> 90) -> skipped
            Sample(latitude: 0.0, longitude: 200.0, routeSegmentIndex: 0),            // invalid lon (> 180) -> skipped
            Sample(latitude: Self.quietNaN, longitude: 0.0, routeSegmentIndex: 0),    // NaN lat -> skipped
            Sample(latitude: 0.0, longitude: Self.infinity, routeSegmentIndex: 0),    // Inf lon -> skipped
        ]
        let result = try Self.compute(samples, 10.0, 50000.0)
        #expect(result.validProjectedPointCount == 5, "5 valid projected points")
    }

    @Test func test_segments_and_invalid_gaps() throws {
        let samples = [
            Sample(latitude: 0.0, longitude: 0.0, routeSegmentIndex: 0),
            Sample(latitude: 0.001, longitude: 0.001, routeSegmentIndex: 0),
            Sample(latitude: 100.0, longitude: 100.0, routeSegmentIndex: 0),  // invalid coordinate -> gap
            Sample(latitude: 0.002, longitude: 0.002, routeSegmentIndex: 0),
            Sample(latitude: 0.003, longitude: 0.003, routeSegmentIndex: 1),  // segment change from 0 to 1
            Sample(latitude: 0.004, longitude: 0.004, routeSegmentIndex: -5), // segment change from 1 to -5
        ]
        let result = try Self.compute(samples)
        #expect(result.validProjectedPointCount == 5, "5 valid points")
        #expect(result.effectiveSegmentCount == 4, "4 effective segments")
    }

    @Test func test_coverage_traversal_and_sorting() throws {
        let samples = [
            Sample(latitude: 0.0, longitude: 0.0, routeSegmentIndex: 0),
            Sample(latitude: 0.0, longitude: 0.001, routeSegmentIndex: 0),
            Sample(latitude: 0.001, longitude: 0.001, routeSegmentIndex: 0),
            Sample(latitude: 0.0, longitude: 0.0, routeSegmentIndex: 0),  // loop back to start
        ]
        let result = try Self.compute(samples)
        #expect(!result.cells.isEmpty)
        for index in 1..<result.cells.count {
            let previous = result.cells[index - 1]
            let current = result.cells[index]
            #expect(previous.y < current.y || (previous.y == current.y && previous.x < current.x),
                    "output cells sorted by y then x")
            #expect(!(previous.x == current.x && previous.y == current.y), "output cells are unique")
        }
    }

    @Test func test_oversized_intervals() throws {
        let samples = [
            Sample(latitude: 0.0, longitude: 0.0, routeSegmentIndex: 0),
            Sample(latitude: 1.0, longitude: 1.0, routeSegmentIndex: 0),  // ~150 km jump > 500 m max interval
        ]
        let result = try Self.compute(samples)
        #expect(result.invalidIntervalCount == 1, "1 invalid interval count")
        #expect(result.cells.count == 2, "2 point cells retained")
    }

    @Test func test_large_route() throws {
        let sampleCount = 100_000
        var samples: [Sample] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let offset = Double(index) * 0.00001
            samples.append(Sample(
                latitude: 37.7749 + offset, longitude: -122.4194 + offset,
                routeSegmentIndex: Int64(index / 10_000)
            ))
        }
        let result = try Self.compute(samples)
        #expect(result.validProjectedPointCount == UInt64(sampleCount), "large route valid count")
        #expect(result.effectiveSegmentCount == 10, "10 effective segments")
        #expect(result.cells.count > 0, "written cells > 0")
    }
}
