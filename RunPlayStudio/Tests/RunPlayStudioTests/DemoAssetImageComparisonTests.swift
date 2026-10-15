#if DEBUG
import CoreGraphics
import XCTest
@testable import RunPlayStudio

final class DemoAssetImageComparisonTests: XCTestCase {
    private let size = DemoAssetPixelSize(width: 5, height: 4)
    private let tolerance = DemoAssetPixelTolerance(channelTolerance: 16, maximumDifferingPixels: 1)

    func testIdenticalBuffersHaveNoDifference() {
        let pixels = gradient()
        let difference = DemoAssetImageComparator.compare(
            referencePixels: pixels,
            candidatePixels: pixels,
            size: size,
            tolerance: tolerance
        )
        XCTAssertEqual(difference.differingPixelCount, 0)
        XCTAssertEqual(difference.maximumChannelDelta, 0)
        XCTAssertNil(difference.differingRegion)
        XCTAssertTrue(difference.isWithin(tolerance))
    }

    func testChannelDeltaAtToleranceIsNoiseAndOneMoreCounts() {
        let reference = gradient()
        let atTolerance = changing(reference, x: 2, y: 1, channel: 0, by: 16)
        let beyond = changing(reference, x: 2, y: 1, channel: 0, by: 17)

        let noise = DemoAssetImageComparator.compare(
            referencePixels: reference, candidatePixels: atTolerance, size: size, tolerance: tolerance
        )
        XCTAssertEqual(noise.differingPixelCount, 0)
        XCTAssertEqual(noise.maximumChannelDelta, 16)

        let change = DemoAssetImageComparator.compare(
            referencePixels: reference, candidatePixels: beyond, size: size, tolerance: tolerance
        )
        XCTAssertEqual(change.differingPixelCount, 1)
        XCTAssertEqual(change.maximumChannelDelta, 17)
    }

    func testAlphaChangesCountLikeColourChanges() {
        let reference = gradient()
        let candidate = changing(reference, x: 0, y: 0, channel: 3, by: -40)
        let difference = DemoAssetImageComparator.compare(
            referencePixels: reference, candidatePixels: candidate, size: size, tolerance: tolerance
        )
        XCTAssertEqual(difference.differingPixelCount, 1)
    }

    func testDifferingRegionBoundsChangedPixelsFromTheTopLeft() {
        let reference = gradient()
        var candidate = changing(reference, x: 3, y: 0, channel: 1, by: 90)
        candidate = changing(candidate, x: 1, y: 2, channel: 2, by: -90)
        let difference = DemoAssetImageComparator.compare(
            referencePixels: reference, candidatePixels: candidate, size: size, tolerance: tolerance
        )
        XCTAssertEqual(difference.differingPixelCount, 2)
        XCTAssertEqual(difference.differingRegion, DemoAssetPixelRegion(minX: 1, minY: 0, maxX: 3, maxY: 2))
    }

    func testPixelBudgetIsInclusive() {
        let reference = gradient()
        let one = changing(reference, x: 0, y: 3, channel: 0, by: 90)
        let two = changing(one, x: 4, y: 3, channel: 0, by: 90)

        XCTAssertTrue(
            DemoAssetImageComparator.compare(
                referencePixels: reference, candidatePixels: one, size: size, tolerance: tolerance
            ).isWithin(tolerance)
        )
        XCTAssertFalse(
            DemoAssetImageComparator.compare(
                referencePixels: reference, candidatePixels: two, size: size, tolerance: tolerance
            ).isWithin(tolerance)
        )
    }

    func testImagesOfDifferentSizesNeverMatch() throws {
        let small = try DemoAssetImageComparator.makeImage(rgbaPixels: gradient(), width: 5, height: 4)
        let wide = try DemoAssetImageComparator.makeImage(
            rgbaPixels: [UInt8](repeating: 255, count: 6 * 4 * 4),
            width: 6,
            height: 4
        )
        let difference = try DemoAssetImageComparator.compare(
            reference: small,
            candidate: wide,
            tolerance: DemoAssetPixelTolerance(channelTolerance: 255, maximumDifferingPixels: .max)
        )
        XCTAssertFalse(difference.sizesMatch)
        XCTAssertFalse(difference.isWithin(.summaryCard))
        XCTAssertTrue(difference.report(tolerance: .summaryCard).contains("6×4"))
    }

    func testPixelsRoundTripThroughImagesTopRowFirst() throws {
        let pixels = gradient()
        let image = try DemoAssetImageComparator.makeImage(rgbaPixels: pixels, width: 5, height: 4)
        XCTAssertEqual(try DemoAssetImageComparator.rgbaPixels(of: image), pixels)
    }

    func testDiffImageMarksOnlyChangedPixelsInMagenta() throws {
        let referencePixels = gradient()
        let candidatePixels = changing(referencePixels, x: 4, y: 1, channel: 1, by: 90)
        let diff = try DemoAssetImageComparator.diffImage(
            reference: try DemoAssetImageComparator.makeImage(rgbaPixels: referencePixels, width: 5, height: 4),
            candidate: try DemoAssetImageComparator.makeImage(rgbaPixels: candidatePixels, width: 5, height: 4),
            tolerance: tolerance
        )
        let output = try DemoAssetImageComparator.rgbaPixels(of: diff)
        for y in 0..<4 {
            for x in 0..<5 {
                let offset = (y * 5 + x) * 4
                let isMagenta = Array(output[offset..<offset + 3]) == [255, 0, 255]
                XCTAssertEqual(isMagenta, x == 4 && y == 1, "pixel \(x),\(y)")
            }
        }
    }

    // MARK: - Helpers

    /// Opaque pixels whose channels differ everywhere, so orientation errors show.
    private func gradient() -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<size.height {
            for x in 0..<size.width {
                pixels += [UInt8(40 + x * 30), UInt8(40 + y * 40), UInt8(200 - x * 10 - y * 5), 255]
            }
        }
        return pixels
    }

    private func changing(_ pixels: [UInt8], x: Int, y: Int, channel: Int, by delta: Int) -> [UInt8] {
        var changed = pixels
        let offset = (y * size.width + x) * 4 + channel
        changed[offset] = UInt8(Int(changed[offset]) + delta)
        return changed
    }
}
#endif
