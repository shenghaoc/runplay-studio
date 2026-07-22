import AppKit
import CoreGraphics
import MapKit
import XCTest
@testable import RunPlayPlatform
import RunPlayCore

final class WorkoutMapSnapshotterTests: XCTestCase {
    func testSnapshotOptionsPreservePlannerMapRectAfterCameraConfiguration() {
        let request = WorkoutMapSnapshotRequest(
            size: CGSize(width: 1_120, height: 560),
            appearance: .light,
            routes: [],
            markers: []
        )
        let center = MKMapPoint(
            CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        )
        let mapRect = MKMapRect(
            x: center.x - 1_000_000,
            y: center.y - 500_000,
            width: 2_000_000,
            height: 1_000_000
        )

        let options = MapKitWorkoutMapSnapshotter.makeSnapshotOptions(
            request: request,
            mapRect: mapRect
        )

        XCTAssertEqual(options.mapRect.origin.x, mapRect.origin.x, accuracy: 0.001)
        XCTAssertEqual(options.mapRect.origin.y, mapRect.origin.y, accuracy: 0.001)
        XCTAssertEqual(options.mapRect.size.width, mapRect.size.width, accuracy: 0.001)
        XCTAssertEqual(options.mapRect.size.height, mapRect.size.height, accuracy: 0.001)
        XCTAssertEqual(options.camera.pitch, 0, accuracy: 0.001)
        XCTAssertEqual(options.camera.heading, 0, accuracy: 0.001)
    }

    func testRetinaBackedBasemapNormalizesToRequestedPixelSize() throws {
        let backingImage = try makeImage(width: 400, height: 200)
        let image = NSImage(
            cgImage: backingImage,
            size: NSSize(width: 200, height: 100)
        )

        let normalized = try WorkoutMapSnapshotImageNormalizer.normalizedCGImage(
            from: image,
            targetSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(normalized.width, 200)
        XCTAssertEqual(normalized.height, 100)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        return image
    }
}
