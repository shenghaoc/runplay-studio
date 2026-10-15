#if DEBUG
import CoreGraphics
import Foundation
import ImageIO

/// How far a rendered demo PNG may differ from its committed reference before
/// the README drift check fails.
struct DemoAssetPixelTolerance: Equatable, Sendable {
    /// Largest per-channel difference, out of 255, that counts as
    /// rasterization noise rather than a change.
    let channelTolerance: Int
    /// Pixels allowed to exceed `channelTolerance` before the images differ.
    let maximumDifferingPixels: Int

    /// The CI gate for the summary cards.
    ///
    /// Two renders on one macOS build are byte-identical, so the bounds only
    /// absorb stray rasterization noise. They sit well below the smallest
    /// real change: one digit of a 14-pt split time moves 36 to 60 pixels
    /// past the channel bound, depending on the digits, and one digit of an
    /// 18-pt metric value about 110. `DemoAssetGeneratorTests` checks both.
    static let summaryCard = DemoAssetPixelTolerance(
        channelTolerance: 16,
        maximumDifferingPixels: 8
    )
}

struct DemoAssetPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// An inclusive pixel rectangle with a top-left origin.
struct DemoAssetPixelRegion: Equatable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
}

/// The measured difference between a reference and a candidate image.
struct DemoAssetPixelDifference: Equatable, Sendable {
    let referenceSize: DemoAssetPixelSize
    let candidateSize: DemoAssetPixelSize
    /// Pixels whose largest channel difference exceeds the channel tolerance
    /// the comparison ran with; zero when the sizes differ.
    let differingPixelCount: Int
    /// The largest channel difference anywhere in the image, out of 255.
    let maximumChannelDelta: Int
    /// Bounding box of the differing pixels; nil when none differ.
    let differingRegion: DemoAssetPixelRegion?

    var sizesMatch: Bool { referenceSize == candidateSize }

    func isWithin(_ tolerance: DemoAssetPixelTolerance) -> Bool {
        sizesMatch && differingPixelCount <= tolerance.maximumDifferingPixels
    }

    func report(tolerance: DemoAssetPixelTolerance) -> String {
        guard sizesMatch else {
            return "size \(candidateSize.width)×\(candidateSize.height) does not match the reference "
                + "\(referenceSize.width)×\(referenceSize.height)"
        }
        var report = "\(differingPixelCount) pixel(s) beyond channel tolerance "
            + "\(tolerance.channelTolerance) (allowed \(tolerance.maximumDifferingPixels)); "
            + "largest channel delta \(maximumChannelDelta)"
        if let region = differingRegion {
            report += "; differing region x \(region.minX)–\(region.maxX), y \(region.minY)–\(region.maxY)"
        }
        return report
    }
}

enum DemoAssetImageComparisonError: Error, LocalizedError, Equatable {
    case unreadableImage(String)
    case renderingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let path):
            return "could not read an image at \(path)"
        case .renderingFailed(let detail):
            return detail
        }
    }
}

/// Pixel comparison for the README demo drift check.
///
/// Both images are drawn into the same 8-bit sRGB RGBA layout, top row first,
/// so a PNG's encoding details never count as a difference.
enum DemoAssetImageComparator {
    static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DemoAssetImageComparisonError.unreadableImage(url.path)
        }
        return image
    }

    static func compare(
        reference: CGImage,
        candidate: CGImage,
        tolerance: DemoAssetPixelTolerance
    ) throws -> DemoAssetPixelDifference {
        let referenceSize = DemoAssetPixelSize(width: reference.width, height: reference.height)
        let candidateSize = DemoAssetPixelSize(width: candidate.width, height: candidate.height)
        guard referenceSize == candidateSize else {
            return DemoAssetPixelDifference(
                referenceSize: referenceSize,
                candidateSize: candidateSize,
                differingPixelCount: 0,
                maximumChannelDelta: 0,
                differingRegion: nil
            )
        }
        return compare(
            referencePixels: try rgbaPixels(of: reference),
            candidatePixels: try rgbaPixels(of: candidate),
            size: referenceSize,
            tolerance: tolerance
        )
    }

    /// Compares two RGBA8 buffers of `size`, top row first.
    static func compare(
        referencePixels: [UInt8],
        candidatePixels: [UInt8],
        size: DemoAssetPixelSize,
        tolerance: DemoAssetPixelTolerance
    ) -> DemoAssetPixelDifference {
        precondition(referencePixels.count == size.width * size.height * 4)
        precondition(candidatePixels.count == referencePixels.count)

        var differing = 0
        var largest = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        referencePixels.withUnsafeBufferPointer { reference in
            candidatePixels.withUnsafeBufferPointer { candidate in
                for y in 0..<size.height {
                    for x in 0..<size.width {
                        let delta = pixelDelta(reference, candidate, at: (y * size.width + x) * 4)
                        largest = max(largest, delta)
                        guard delta > tolerance.channelTolerance else { continue }
                        differing += 1
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
            }
        }
        let size = DemoAssetPixelSize(width: size.width, height: size.height)
        return DemoAssetPixelDifference(
            referenceSize: size,
            candidateSize: size,
            differingPixelCount: differing,
            maximumChannelDelta: largest,
            differingRegion: differing == 0
                ? nil
                : DemoAssetPixelRegion(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        )
    }

    /// The reference faded toward white, with every pixel beyond the channel
    /// tolerance in solid magenta: the evidence CI uploads on drift.
    static func diffImage(
        reference: CGImage,
        candidate: CGImage,
        tolerance: DemoAssetPixelTolerance
    ) throws -> CGImage {
        guard reference.width == candidate.width, reference.height == candidate.height else {
            throw DemoAssetImageComparisonError.renderingFailed(
                "cannot draw a diff of differently sized images"
            )
        }
        let referencePixels = try rgbaPixels(of: reference)
        let candidatePixels = try rgbaPixels(of: candidate)
        var output = [UInt8](repeating: 255, count: referencePixels.count)
        referencePixels.withUnsafeBufferPointer { reference in
            candidatePixels.withUnsafeBufferPointer { candidate in
                for offset in stride(from: 0, to: reference.count, by: 4) {
                    if pixelDelta(reference, candidate, at: offset) > tolerance.channelTolerance {
                        output[offset] = 255
                        output[offset + 1] = 0
                        output[offset + 2] = 255
                    } else {
                        for channel in 0..<3 {
                            output[offset + channel] = 255 - (255 - reference[offset + channel]) / 4
                        }
                    }
                }
            }
        }
        return try makeImage(rgbaPixels: output, width: reference.width, height: reference.height)
    }

    /// The image drawn into 8-bit premultiplied sRGB RGBA, top row first.
    static func rgbaPixels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DemoAssetImageComparisonError.renderingFailed("cannot read an empty image")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw DemoAssetImageComparisonError.renderingFailed("could not create an RGBA context")
        }
        return pixels
    }

    static func makeImage(rgbaPixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard rgbaPixels.count == width * height * 4,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgbaPixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw DemoAssetImageComparisonError.renderingFailed("could not build an RGBA image")
        }
        return image
    }

    /// Largest of the four channel differences at `offset`.
    private static func pixelDelta(
        _ reference: UnsafeBufferPointer<UInt8>,
        _ candidate: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> Int {
        var largest = 0
        for channel in 0..<4 {
            largest = max(
                largest,
                abs(Int(reference[offset + channel]) - Int(candidate[offset + channel]))
            )
        }
        return largest
    }
}
#endif
