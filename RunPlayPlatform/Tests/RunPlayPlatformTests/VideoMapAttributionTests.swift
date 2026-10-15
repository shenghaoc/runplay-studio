import AppKit
import CoreGraphics
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform

final class VideoMapAttributionTests: XCTestCase {
    private let shippingPolicies: [WorkoutVideoExportPolicy] = [.production, .poster]

    func testCreditMatchesTheSummaryCardWording() {
        XCTAssertTrue(VideoMapAttribution.text.contains("Apple Maps"))
        XCTAssertTrue(
            ExportSummaryCardModel.mapInclusivePrivacyNote.contains(VideoMapAttribution.text),
            "the videos and the map-inclusive PNG card must credit Apple Maps alike"
        )
    }

    /// WCAG AA for normal text (4.5:1), whatever the map shows through the
    /// translucent badge: checked over a black and a white basemap.
    func testCreditIsLegibleInBothAppearancesOverAnyMap() throws {
        for appearance in PNGSummaryExportAppearance.allCases {
            let colors = VideoMapAttribution.Colors(appearance: appearance)
            let text = try sRGBComponents(colors.text)
            let background = try sRGBComponents(colors.background)
            for underlay in [0.0, 1.0] {
                let composited = (0..<3).map { channel in
                    background.alpha * background.rgb[channel] + (1 - background.alpha) * underlay
                }
                let ratio = contrastRatio(text.rgb, composited)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    4.5,
                    "\(appearance) credit over a \(underlay == 0 ? "black" : "white") map: \(ratio):1"
                )
            }
        }
    }

    func testBadgeSitsInTheFooterRowFlushWithTheRightMargin() throws {
        for appearance in PNGSummaryExportAppearance.allCases {
            let badge = try VideoMapAttribution.badge(for: appearance)
            XCTAssertEqual(CGFloat(badge.height), VideoMapAttribution.badgeHeight)
            for policy in shippingPolicies {
                let bounds = CGRect(x: 0, y: 0, width: policy.width, height: policy.height)
                let frame = VideoMapAttribution.frame(for: badge, in: bounds)

                XCTAssertEqual(frame.maxX, bounds.maxX - VideoMapAttribution.margin)
                XCTAssertEqual(frame.size, CGSize(width: badge.width, height: badge.height))
                XCTAssertEqual(frame, frame.integral, "whole pixels, so the badge is copied unscaled")
                XCTAssertGreaterThan(frame.minY, bounds.minY)
                XCTAssertTrue(frame.minY < VideoMapAttribution.baselineY)
                XCTAssertTrue(frame.maxY > VideoMapAttribution.baselineY)
                XCTAssertTrue(bounds.contains(frame))
            }
        }
    }

    func testProgressCaptionEndsBeforeTheBadge() throws {
        let badge = try VideoMapAttribution.badge(for: .light)
        for policy in shippingPolicies {
            let bounds = CGRect(x: 0, y: 0, width: policy.width, height: policy.height)
            let frame = VideoMapAttribution.frame(for: badge, in: bounds)
            let width = VideoMapAttribution.captionMaxWidth(besideBadgeFrame: frame, in: bounds)
            XCTAssertEqual(
                VideoMapAttribution.margin + width + VideoMapAttribution.captionGap,
                frame.minX
            )
            // Room for the longest caption either renderer draws, so the clip
            // never shortens it at a shipping size.
            XCTAssertGreaterThan(width, 400)
        }

        let narrow = CGRect(x: 0, y: 0, width: 160, height: 90)
        XCTAssertEqual(
            VideoMapAttribution.captionMaxWidth(
                besideBadgeFrame: VideoMapAttribution.frame(for: badge, in: narrow),
                in: narrow
            ),
            0
        )
    }

    func testBadgeIsRasterizedOncePerAppearance() throws {
        let light = try VideoMapAttribution.badge(for: .light)
        let dark = try VideoMapAttribution.badge(for: .dark)
        let lightAgain = try VideoMapAttribution.badge(for: .light)
        let darkAgain = try VideoMapAttribution.badge(for: .dark)
        XCTAssertTrue(light === lightAgain)
        XCTAssertTrue(dark === darkAgain)
        XCTAssertFalse(light === dark)
    }

    // MARK: - Helpers

    private func sRGBComponents(_ color: NSColor) throws -> (rgb: [Double], alpha: Double) {
        let converted = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return (
            [converted.redComponent, converted.greenComponent, converted.blueComponent].map(Double.init),
            Double(converted.alphaComponent)
        )
    }

    private func contrastRatio(_ first: [Double], _ second: [Double]) -> Double {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.040_45 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

// MARK: - Rendered-frame inspection

/// BGRA pixels of a rendered video frame, addressed in the renderers'
/// bottom-left-origin drawing coordinates.
struct VideoFramePixels {
    let width: Int
    let height: Int
    private let pixels: [UInt32]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        pixels = try Self.bgraPixels(width: width, height: height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// The pixel covering drawing-space point (`x` + 0.5, `y` + 0.5).
    func pixel(x: Int, y: Int) -> UInt32 {
        pixels[(height - 1 - y) * width + x]
    }

    /// Rows of `rect` (whole pixels, drawing space) from top to bottom.
    func region(_ rect: CGRect) -> [UInt32] {
        var region: [UInt32] = []
        region.reserveCapacity(Int(rect.width * rect.height))
        for y in stride(from: Int(rect.maxY) - 1, through: Int(rect.minY), by: -1) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                region.append(pixel(x: x, y: y))
            }
        }
        return region
    }

    /// Every pixel of `outer` that lies outside `inner`, both clamped to the frame.
    func ring(around inner: CGRect, width ringWidth: CGFloat) -> [UInt32] {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let outer = inner.insetBy(dx: -ringWidth, dy: -ringWidth).intersection(frame)
        var ring: [UInt32] = []
        for y in Int(outer.minY)..<Int(outer.maxY) {
            for x in Int(outer.minX)..<Int(outer.maxX)
            where !inner.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                ring.append(pixel(x: x, y: y))
            }
        }
        return ring
    }

    /// `badge` drawn unscaled over a uniform `background`, as top-to-bottom rows.
    static func composite(_ badge: CGImage, over background: UInt32) throws -> [UInt32] {
        try bgraPixels(width: badge.width, height: badge.height, fill: background) { context in
            context.draw(badge, in: CGRect(x: 0, y: 0, width: badge.width, height: badge.height))
        }
    }

    /// Checks that `badge` sits at its layout frame in `image`, composited
    /// unscaled over the plain map with nothing else drawn under it, and that
    /// no HUD element comes within `clearance` pixels of it. The map must be
    /// uniform around the credit and at the frame's top-right HUD margin,
    /// which supplies the plain map colour.
    static func assertCredit(
        _ badge: CGImage,
        isDrawnClearIn image: CGImage,
        clearance: CGFloat = 8,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pixels = try VideoFramePixels(image)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let frame = VideoMapAttribution.frame(for: badge, in: bounds)
        let marginMidpoint = Int(VideoMapAttribution.margin / 2)
        let plainMap = pixels.pixel(
            x: image.width - marginMidpoint,
            y: image.height - marginMidpoint
        )

        let drawn = pixels.region(frame)
        let expected = try composite(badge, over: plainMap)
        XCTAssertEqual(drawn.count, expected.count, file: file, line: line)
        let mismatched = zip(drawn, expected).filter { $0 != $1 }.count
        XCTAssertEqual(
            mismatched,
            0,
            "\(mismatched) of \(expected.count) credit pixels differ from the badge over the plain map "
                + "(missing, scaled, or overlapped): \(message)",
            file: file,
            line: line
        )
        let ring = pixels.ring(around: frame, width: clearance)
        XCTAssertFalse(ring.isEmpty, file: file, line: line)
        let intruding = ring.filter { $0 != plainMap }.count
        XCTAssertEqual(
            intruding,
            0,
            "\(intruding) pixels of HUD content within \(clearance) px of the credit: \(message)",
            file: file,
            line: line
        )
    }

    private static func bgraPixels(
        width: Int,
        height: Int,
        fill: UInt32 = 0,
        draw: (CGContext) -> Void
    ) throws -> [UInt32] {
        var pixels = [UInt32](repeating: fill, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                          | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else {
                return false
            }
            draw(context)
            return true
        }
        guard drawn else {
            throw NSError(domain: "VideoFramePixels", code: 1)
        }
        return pixels
    }
}
