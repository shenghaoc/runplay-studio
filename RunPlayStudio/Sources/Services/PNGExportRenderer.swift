import AppKit
import ImageIO
import RunPlayCore
import SwiftUI
import UniformTypeIdentifiers

/// Renders SwiftUI views as deterministic PNG data at fixed pixel dimensions.
///
/// Never reads `NSScreen.main` or ambient window appearance for size/scale.
struct PNGExportRenderer {
    /// Explicit pixel size for the summary card.
    static let summaryPixelSize = CGSize(
        width: PNGSummaryExportDimensions.width,
        height: PNGSummaryExportDimensions.height
    )

    /// Rasterization scale is always 1 so output is exactly width×height pixels.
    static let rasterizationScale: CGFloat = CGFloat(PNGSummaryExportDimensions.rasterizationScale)

    /// Render a SwiftUI view without requiring a hosted window hierarchy.
    ///
    /// - Parameters:
    ///   - view: Content already laid out at the intended point size.
    ///   - pixelSize: Expected output size in pixels (must match view frame when scale is 1).
    ///   - scale: Explicit rasterization scale; default 1.0 for deterministic export.
    ///   - appearance: Resolved Light/Dark applied to the render environment.
    @MainActor
    static func renderPNG<Content: View>(
        from view: Content,
        pixelSize: CGSize = summaryPixelSize,
        scale: CGFloat = rasterizationScale,
        appearance: PNGSummaryExportAppearance = .light
    ) throws -> Data {
        guard scale > 0, pixelSize.width > 0, pixelSize.height > 0 else {
            throw ExportError.renderingFailed("Invalid render size or scale")
        }

        // Appearance is resolved through explicit export palettes on the view
        // plus colorScheme environment — never ambient window/system appearance.
        let wrapped = view
            .frame(width: pixelSize.width / scale, height: pixelSize.height / scale)
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            .preferredColorScheme(appearance == .dark ? .dark : .light)

        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(
            width: pixelSize.width / scale,
            height: pixelSize.height / scale
        )
        renderer.isOpaque = true
        renderer.colorMode = .nonLinear

        guard let cgImage = renderer.cgImage else {
            throw ExportError.renderingFailed("ImageRenderer failed to produce an image")
        }

        let width = cgImage.width
        let height = cgImage.height
        let expectedW = Int(pixelSize.width.rounded())
        let expectedH = Int(pixelSize.height.rounded())
        guard width == expectedW, height == expectedH else {
            throw ExportError.renderingFailed(
                "Rendered size \(width)×\(height) does not match expected \(expectedW)×\(expectedH)"
            )
        }

        return try encodePNG(cgImage: cgImage)
    }

    /// Encode a CGImage as PNG without GPS/EXIF location metadata.
    static func encodePNG(cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.renderingFailed("Could not create PNG destination")
        }

        // Intentionally omit GPS / location metadata keys.
        let properties: [CFString: Any] = [
            kCGImagePropertyHasAlpha: true
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.renderingFailed("Could not encode as PNG")
        }
        let pngData = data as Data
        guard !pngData.isEmpty else {
            throw ExportError.renderingFailed("PNG data is empty")
        }
        // Validate PNG signature.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(pngData.prefix(8)) == signature else {
            throw ExportError.renderingFailed("Encoded data is not a valid PNG")
        }
        return pngData
    }

    /// Decode pixel dimensions from PNG data (for tests and verification).
    static func pngPixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}
