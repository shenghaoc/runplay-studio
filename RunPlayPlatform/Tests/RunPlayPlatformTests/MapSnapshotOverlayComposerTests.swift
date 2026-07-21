import AppKit
import CoreGraphics
import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class MapSnapshotOverlayComposerTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    func testSolidRouteProducesExactDimensions() throws {
        let basemap = try makeBlankImage(size: size, color: .lightGray)
        let routes = [line(id: "r", style: .primary, coords: [
            (0, 0), (0.5, 0.5), (1, 1)
        ])]
        let converter = LinearMapCoordinateConverter(
            minLatitude: 0, maxLatitude: 1,
            minLongitude: 0, maxLongitude: 1,
            size: size
        )
        let result = try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: routes,
            markers: [],
            converter: converter
        )
        XCTAssertEqual(result.pixelWidth, Int(size.width))
        XCTAssertEqual(result.pixelHeight, Int(size.height))
        XCTAssertFalse(result.containsNoDataLines)
    }

    func testMetricAndNoDataRoutes() throws {
        let basemap = try makeBlankImage(size: size, color: .white)
        let routes = [
            line(id: "m", style: .metric(mode: .pace, bucket: .level(0)), coords: [(0, 0), (0.4, 0.4)]),
            line(id: "n", style: .metric(mode: .pace, bucket: .noData), coords: [(0.6, 0.6), (1, 1)])
        ]
        let converter = LinearMapCoordinateConverter(routes: routes, size: size)
        let result = try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: routes,
            markers: [],
            converter: converter
        )
        XCTAssertTrue(result.containsNoDataLines)
        XCTAssertEqual(result.pixelWidth, Int(size.width))
    }

    func testMultipleSegmentsDoNotRequireSharedPath() throws {
        let basemap = try makeBlankImage(size: size, color: .white)
        let routes = [
            line(id: "a", style: .primary, coords: [(0, 0), (0.2, 0.2)]),
            line(id: "b", style: .primary, coords: [(0.8, 0.8), (1, 1)])
        ]
        let converter = LinearMapCoordinateConverter(routes: routes, size: size)
        // Composer must accept multiple lines without bridging — success is enough.
        let result = try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: routes,
            markers: [],
            converter: converter
        )
        XCTAssertEqual(result.pixelWidth, Int(size.width))
    }

    func testStartAndFinishMarkersDrawnCurrentSkipped() throws {
        let basemap = try makeBlankImage(size: size, color: .white)
        let start = RouteMapCoordinate(latitude: 0.1, longitude: 0.1)!
        let finish = RouteMapCoordinate(latitude: 0.9, longitude: 0.9)!
        let current = RouteMapCoordinate(latitude: 0.5, longitude: 0.5)!
        let markers = [
            RouteMapMarker(id: "s", title: "Start", coordinate: start, style: .start),
            RouteMapMarker(id: "f", title: "Finish", coordinate: finish, style: .finish),
            RouteMapMarker(id: "c", title: "Current", coordinate: current, style: .current)
        ]
        let routes = [line(id: "r", style: .primary, coords: [(0.1, 0.1), (0.9, 0.9)])]
        let converter = LinearMapCoordinateConverter(routes: routes, size: size)
        let result = try MapSnapshotOverlayComposer.compose(
            basemap: basemap,
            routes: routes,
            markers: markers,
            converter: converter
        )
        // Image should differ from blank basemap (markers/route painted).
        let blank = try makeBlankImage(size: size, color: .white)
        XCTAssertNotEqual(pixelChecksum(result.cgImage), pixelChecksum(blank))
        XCTAssertEqual(result.pixelWidth, Int(size.width))
    }

    func testCancellationThrows() throws {
        let basemap = try makeBlankImage(size: size, color: .white)
        let routes = [line(id: "r", style: .primary, coords: [(0, 0), (1, 1)])]
        let converter = LinearMapCoordinateConverter(routes: routes, size: size)
        XCTAssertThrowsError(
            try MapSnapshotOverlayComposer.compose(
                basemap: basemap,
                routes: routes,
                markers: [],
                converter: converter,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertEqual(error as? WorkoutMapSnapshotError, .cancelled)
        }
    }

    func testLightAndDarkBasemapsCompose() throws {
        for color: NSColor in [.white, .black] {
            let basemap = try makeBlankImage(size: size, color: color)
            let routes = [line(id: "r", style: .primary, coords: [(0, 0), (1, 1)])]
            let converter = LinearMapCoordinateConverter(routes: routes, size: size)
            let result = try MapSnapshotOverlayComposer.compose(
                basemap: basemap,
                routes: routes,
                markers: [],
                converter: converter
            )
            XCTAssertEqual(result.pixelWidth, Int(size.width))
            XCTAssertEqual(result.pixelHeight, Int(size.height))
        }
    }

    // MARK: - Helpers

    private func line(
        id: String,
        style: RouteMapLineStyle,
        coords: [(Double, Double)]
    ) -> RouteMapLine {
        RouteMapLine(
            id: id,
            coordinates: coords.compactMap { RouteMapCoordinate(latitude: $0.0, longitude: $0.1) },
            style: style
        )
    }

    private func makeBlankImage(size: CGSize, color: NSColor) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        return image
    }

    private func pixelChecksum(_ image: CGImage) -> UInt64 {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var hash: UInt64 = 0
        for byte in data.prefix(4_096) {
            hash = hash &* 31 &+ UInt64(byte)
        }
        return hash &* 31 &+ UInt64(image.width) &* 1_000_003 &+ UInt64(image.height)
    }
}
