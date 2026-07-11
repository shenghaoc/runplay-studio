import Foundation
import RunPlayCore
import SwiftUI

import AppKit

/// Renders SwiftUI views as PNG data.
///
/// Uses NSHostingView and bitmap representation for reliable macOS rendering.
public struct PNGExportRenderer {

    /// Render any SwiftUI view to PNG data.
    ///
    /// - Parameter view: The SwiftUI view to render.
    /// - Returns: PNG image data.
    /// - Throws: ExportError if rendering fails.
    public static func renderPNG<Content: View>(from view: Content) throws -> Data {
        let hostingView = NSHostingView(rootView: view)

        let fittingSize = hostingView.fittingSize
        let intrinsicSize = hostingView.intrinsicContentSize
        let size = [fittingSize, intrinsicSize, hostingView.frame.size]
            .first { $0.width > 0 && $0.height > 0 } ?? .zero

        guard size.width > 0, size.height > 0 else {
            throw ExportError.renderingFailed("View has zero size")
        }

        let bounds = NSRect(origin: .zero, size: size)
        hostingView.frame = bounds
        hostingView.layoutSubtreeIfNeeded()

        guard let renderSize = hostingView.subviews.first?.frame.size ?? Optional(hostingView.frame.size),
              renderSize.width > 0, renderSize.height > 0 else {
            throw ExportError.renderingFailed("View has zero size")
        }

        let renderBounds = NSRect(origin: .zero, size: renderSize)
        hostingView.frame = renderBounds

        guard renderSize.width > 0, renderSize.height > 0,
              let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: renderBounds) else {
            throw ExportError.renderingFailed("Could not create bitmap representation")
        }

        hostingView.cacheDisplay(in: renderBounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw ExportError.renderingFailed("Could not encode as PNG")
        }

        guard !pngData.isEmpty else {
            throw ExportError.renderingFailed("PNG data is empty")
        }

        return pngData
    }
}
