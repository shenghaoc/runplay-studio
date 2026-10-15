import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import RunPlayCore

/// Core Graphics renderer for one offline video frame into a BGRA pixel buffer.
///
/// Not main-actor isolated. Does not call MapKit, SwiftUI, or live view state.
public struct WorkoutVideoFrameRenderer: Sendable {
    public init() {}

    /// Draw `frame` into a locked BGRA `pixelBuffer` using `staticMap` as background.
    public func render(
        frame: WorkoutVideoFrameModel,
        staticMap: CGImage,
        into pixelBuffer: CVPixelBuffer,
        mapSize: CGSize
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw WorkoutVideoExportError.frameRenderingFailed("Pixel buffer has zero size")
        }
        let attribution = try VideoMapAttribution.badge(for: frame.appearance)

        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockResult == kCVReturnSuccess else {
            throw WorkoutVideoExportError.frameRenderingFailed("Could not lock pixel buffer")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WorkoutVideoExportError.frameRenderingFailed("Pixel buffer has no base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WorkoutVideoExportError.frameRenderingFailed(
                "Could not create the sRGB color space"
            )
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WorkoutVideoExportError.frameRenderingFailed("Could not create graphics context")
        }

        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let palette = Palette(appearance: frame.appearance)

        // Opaque fill first so incomplete draws never leave transparent frames.
        context.setFillColor(palette.background.cgColor)
        context.fill(bounds)

        // Static map — cover the full frame (aspect-fill top-down canvas).
        drawMap(staticMap, in: context, bounds: bounds)

        // Moving marker in map pixel space scaled to frame.
        if let marker = frame.markerPixel {
            let scaleX = CGFloat(width) / max(mapSize.width, 1)
            let scaleY = CGFloat(height) / max(mapSize.height, 1)
            let scaled = CGPoint(x: marker.x * scaleX, y: marker.y * scaleY)
            drawMarker(at: scaled, in: context, palette: palette)
        }

        drawHeader(frame: frame, in: context, bounds: bounds, palette: palette)
        drawMetricsPanel(frame: frame, in: context, bounds: bounds, palette: palette)
        let attributionFrame = VideoMapAttribution.frame(for: attribution, in: bounds)
        drawProgress(
            frame: frame,
            in: context,
            bounds: bounds,
            palette: palette,
            captionMaxWidth: VideoMapAttribution.captionMaxWidth(
                besideBadgeFrame: attributionFrame,
                in: bounds
            )
        )
        // Last, so nothing covers the Apple Maps credit.
        context.draw(attribution, in: attributionFrame)
    }

    /// Render into a newly allocated CGImage (poster / unit tests).
    public func renderImage(
        frame: WorkoutVideoFrameModel,
        staticMap: CGImage,
        width: Int,
        height: Int,
        mapSize: CGSize
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw WorkoutVideoExportError.frameRenderingFailed("Invalid image size")
        }
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw WorkoutVideoExportError.pixelBufferAllocationFailed
        }
        try render(frame: frame, staticMap: staticMap, into: buffer, mapSize: mapSize)
        return try makeCGImage(from: buffer)
    }

    // MARK: - Drawing

    private func drawMap(_ map: CGImage, in context: CGContext, bounds: CGRect) {
        context.saveGState()
        context.draw(map, in: bounds)
        context.restoreGState()
    }

    private func drawMarker(at point: CGPoint, in context: CGContext, palette: Palette) {
        let radius: CGFloat = 12
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.setFillColor(palette.markerFill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(palette.markerBorder.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    private func drawHeader(
        frame: WorkoutVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
    ) {
        let margin: CGFloat = 28
        let panelWidth = min(bounds.width * 0.55, 720)
        let panelHeight: CGFloat = 78
        // Top of frame in bottom-left coordinates.
        let panelY = bounds.height - margin - panelHeight
        let panelRect = CGRect(x: margin, y: panelY, width: panelWidth, height: panelHeight)
        fillRoundedPanel(panelRect, in: context, color: palette.panelBackground, radius: 12)

        let titleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let dateFont = NSFont.systemFont(ofSize: 15, weight: .regular)
        let language = VideoHUDText.languageTag(for: frame.locale)
        VideoHUDText.draw(
            frame.workoutTitle,
            font: titleFont,
            color: palette.primaryText,
            language: language,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.maxY - 36),
            maxWidth: panelRect.width - 32,
            in: context
        )
        VideoHUDText.draw(
            frame.workoutDateText,
            font: dateFont,
            color: palette.secondaryText,
            language: language,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.minY + 16),
            maxWidth: panelRect.width - 32,
            in: context
        )
    }

    /// The metrics panel's label/value rows in the frame's language.
    static func metricRows(for frame: WorkoutVideoFrameModel) -> [(label: String, value: String)] {
        let locale = frame.locale
        var rows: [(label: String, value: String)] = [
            (platformLocalized("Elapsed", locale: locale), frame.formattedElapsed),
            (platformLocalized("Active", locale: locale), frame.formattedActive),
            (platformLocalized("Distance", locale: locale), frame.formattedDistance),
            (platformLocalized("Active Pace", locale: locale), frame.formattedPace),
            (platformLocalized("Heart Rate", locale: locale), frame.formattedHeartRate),
            (platformLocalized("Elevation", locale: locale), frame.formattedElevation),
        ]
        if let state = frame.stateLabel {
            rows.append((platformLocalized("State", locale: locale), state))
        }
        rows.append((platformLocalized("Route Color", locale: locale), frame.routeColorMode.localizedName(locale: locale)))
        return rows
    }

    /// Column layout of the metrics panel: values start after the widest
    /// label (never left of the original 140 pt) and the panel widens for a
    /// long value, within the frame.
    static func metricColumns(
        for rows: [(label: String, value: String)],
        language: String,
        frameWidth: CGFloat
    ) -> VideoHUDText.RowColumns {
        VideoHUDText.rowColumns(
            labels: rows.map(\.label),
            values: rows.map(\.value),
            labelFont: metricLabelFont,
            valueFont: metricValueFont,
            language: language,
            inset: 14,
            gap: 16,
            minimumValueOffset: 140,
            minimumPanelWidth: 320,
            maximumPanelWidth: max(320, frameWidth * 0.45)
        )
    }

    private static var metricLabelFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    private static var metricValueFont: NSFont { .monospacedDigitSystemFont(ofSize: 14, weight: .semibold) }

    private func drawMetricsPanel(
        frame: WorkoutVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
    ) {
        let margin: CGFloat = 28
        let language = VideoHUDText.languageTag(for: frame.locale)
        let rows = Self.metricRows(for: frame)
        let columns = Self.metricColumns(for: rows, language: language, frameWidth: bounds.width)

        let rowHeight: CGFloat = 26
        let panelHeight = CGFloat(rows.count) * rowHeight + 28
        let panelRect = CGRect(
            x: margin,
            y: margin + 52,
            width: columns.panelWidth,
            height: panelHeight
        )
        fillRoundedPanel(panelRect, in: context, color: palette.panelBackground, radius: 12)

        var y = panelRect.maxY - 22
        for (label, value) in rows {
            VideoHUDText.draw(
                label,
                font: Self.metricLabelFont,
                color: palette.secondaryText,
                language: language,
                at: CGPoint(x: panelRect.minX + columns.inset, y: y - 4),
                maxWidth: columns.valueOffset - columns.inset - 8,
                in: context
            )
            VideoHUDText.draw(
                value,
                font: Self.metricValueFont,
                color: palette.primaryText,
                language: language,
                at: CGPoint(x: panelRect.minX + columns.valueOffset, y: y - 4),
                maxWidth: columns.valueWidth,
                in: context
            )
            y -= rowHeight
        }
    }

    private func drawProgress(
        frame: WorkoutVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette,
        captionMaxWidth: CGFloat
    ) {
        let margin: CGFloat = 28
        let barHeight: CGFloat = 10
        let labelHeight: CGFloat = 22
        let barY = margin + labelHeight + 6
        let barWidth = bounds.width - margin * 2
        let trackRect = CGRect(x: margin, y: barY, width: barWidth, height: barHeight)

        context.saveGState()
        let trackPath = CGPath(
            roundedRect: trackRect,
            cornerWidth: 5,
            cornerHeight: 5,
            transform: nil
        )
        context.addPath(trackPath)
        context.setFillColor(palette.progressTrack.cgColor)
        context.fillPath()

        let progress = CGFloat(min(1, max(0, frame.progress)))
        if progress > 0 {
            let fillWidth = max(barHeight, barWidth * progress)
            let fillRect = CGRect(x: margin, y: barY, width: fillWidth, height: barHeight)
            let fillPath = CGPath(
                roundedRect: fillRect,
                cornerWidth: 5,
                cornerHeight: 5,
                transform: nil
            )
            context.addPath(fillPath)
            context.setFillColor(palette.progressFill.cgColor)
            context.fillPath()
        }
        context.restoreGState()

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        VideoHUDText.draw(
            frame.progressCaption,
            font: font,
            color: palette.primaryText,
            language: VideoHUDText.languageTag(for: frame.locale),
            at: CGPoint(x: margin, y: margin),
            maxWidth: captionMaxWidth,
            in: context
        )
    }

    private func fillRoundedPanel(
        _ rect: CGRect,
        in context: CGContext,
        color: NSColor,
        radius: CGFloat
    ) {
        context.saveGState()
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let lock = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lock == kCVReturnSuccess else {
            throw WorkoutVideoExportError.frameRenderingFailed("Could not lock buffer for image")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WorkoutVideoExportError.frameRenderingFailed("Missing base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WorkoutVideoExportError.frameRenderingFailed(
                "Could not create the sRGB color space"
            )
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let image = context.makeImage() else {
            throw WorkoutVideoExportError.frameRenderingFailed("Could not create CGImage from buffer")
        }
        return image
    }

    // MARK: - Palette

    private struct Palette {
        let background: NSColor
        let panelBackground: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
        let markerFill: NSColor
        let markerBorder: NSColor
        let progressTrack: NSColor
        let progressFill: NSColor

        init(appearance: PNGSummaryExportAppearance) {
            switch appearance {
            case .light:
                background = NSColor(calibratedWhite: 0.92, alpha: 1)
                panelBackground = NSColor(calibratedWhite: 1.0, alpha: 0.88)
                primaryText = NSColor(calibratedWhite: 0.08, alpha: 1)
                secondaryText = NSColor(calibratedWhite: 0.28, alpha: 1)
                markerFill = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
                markerBorder = NSColor.black
                progressTrack = NSColor(calibratedWhite: 0.75, alpha: 0.9)
                progressFill = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
            case .dark:
                background = NSColor(calibratedWhite: 0.08, alpha: 1)
                panelBackground = NSColor(calibratedWhite: 0.12, alpha: 0.88)
                primaryText = NSColor(calibratedWhite: 0.96, alpha: 1)
                secondaryText = NSColor(calibratedWhite: 0.72, alpha: 1)
                markerFill = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
                markerBorder = NSColor.white
                progressTrack = NSColor(calibratedWhite: 0.35, alpha: 0.9)
                progressFill = NSColor(calibratedRed: 0.4, green: 0.72, blue: 1.0, alpha: 1)
            }
        }
    }
}
