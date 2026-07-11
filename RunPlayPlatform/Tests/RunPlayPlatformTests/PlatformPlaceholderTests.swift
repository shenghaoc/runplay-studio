import XCTest
import RunPlayCore
import RunPlayPlatform

/// Placeholder test to verify RunPlayPlatform compiles correctly.
final class PlatformPlaceholderTests: XCTestCase {
    func testRouteColorMetricsExists() {
        let metrics = RouteColorMetrics()
        let pace = metrics.computeSegmentPace(points: [])
        XCTAssertTrue(pace.isEmpty)
    }
}
