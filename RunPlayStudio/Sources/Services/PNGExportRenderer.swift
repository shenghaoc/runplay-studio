import AppKit
import RunPlayCore
import SwiftUI

/// Renders SwiftUI views as PNG data.
struct PNGExportRenderer {
    /// Render a SwiftUI view without requiring a hosted window hierarchy.
    @MainActor
    static func renderPNG<Content: View>(from view: Content) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 1.0

        guard let cgImage = renderer.cgImage else {
            throw ExportError.renderingFailed("ImageRenderer failed to produce an image")
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]),
              !pngData.isEmpty else {
            throw ExportError.renderingFailed("Could not encode as PNG")
        }

        return pngData
    }
}
