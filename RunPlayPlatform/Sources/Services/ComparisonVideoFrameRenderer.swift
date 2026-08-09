import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import RunPlayCore

/// Formatting-ready model for one comparison video frame.
public struct ComparisonVideoFrameModel: Sendable {
    public let sample: ComparisonVideoFrameSample
    public let primaryTitle: String
    public let comparisonTitle: String
    public let primaryMarkerPixel: CGPoint?
    public let comparisonMarkerPixel: CGPoint?
    public let appearance: PNGSummaryExportAppearance
    public let routesAreWidelySeparated: Bool

    public init(
        sample: ComparisonVideoFrameSample,
        primaryTitle: String,
        comparisonTitle: String,
        primaryMarkerPixel: CGPoint?,
        comparisonMarkerPixel: CGPoint?,
        appearance: PNGSummaryExportAppearance,
        routesAreWidelySeparated: Bool = false
    ) {
        self.sample = sample
        self.primaryTitle = primaryTitle
        self.comparisonTitle = comparisonTitle
        self.primaryMarkerPixel = primaryMarkerPixel
        self.comparisonMarkerPixel = comparisonMarkerPixel
        self.appearance = appearance
        self.routesAreWidelySeparated = routesAreWidelySeparated
    }

    public var progressPercentLabel: String {
        "\(Int((sample.progress * 100).rounded(.down)))%"
    }

    public var domainProgressLabel: String {
        let currentKm = sample.domainPositionMeters / 1000
        let totalKm = sample.domainLengthMeters / 1000
        switch sample.alignmentMode {
        case .distance:
            return String(format: "Common Distance %.2f / %.2f km", currentKm, totalKm)
        case .routeAware:
            return String(format: "Matched Route %.2f / %.2f km", currentKm, totalKm)
        }
    }

    public var elapsedLabel: String {
        sample.alignmentMode == .routeAware ? "Matched Elapsed" : "Elapsed"
    }

    public var activeLabel: String {
        sample.alignmentMode == .routeAware ? "Matched Active" : "Active"
    }

    public var paceLabel: String {
        sample.alignmentMode == .routeAware ? "Matched Pace" : "Active Pace"
    }

    public var blockLabel: String? {
        guard let index = sample.alignmentBlockIndex,
              let count = sample.alignmentBlockCount,
              count > 1 else { return nil }
        return "Block \(index + 1) of \(count)"
    }
}

/// Core Graphics renderer for one offline comparison video frame.
public struct ComparisonVideoFrameRenderer: Sendable {
    public init() {}

    public func render(
        frame: ComparisonVideoFrameModel,
        staticMap: CGImage,
        into pixelBuffer: CVPixelBuffer,
        mapSize: CGSize
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw WorkoutVideoExportError.frameRenderingFailed("Pixel buffer has zero size")
        }

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

        context.setFillColor(palette.background.cgColor)
        context.fill(bounds)

        drawMap(staticMap, in: context, bounds: bounds)

        let scaleX = CGFloat(width) / max(mapSize.width, 1)
        let scaleY = CGFloat(height) / max(mapSize.height, 1)
        if let primary = frame.primaryMarkerPixel {
            let scaled = CGPoint(x: primary.x * scaleX, y: primary.y * scaleY)
            drawMarker(
                at: scaled,
                glyph: "P",
                fill: palette.primaryMarkerFill,
                border: palette.markerBorder,
                text: palette.markerGlyph,
                in: context
            )
        }
        if let comparison = frame.comparisonMarkerPixel {
            let scaled = CGPoint(x: comparison.x * scaleX, y: comparison.y * scaleY)
            drawMarker(
                at: scaled,
                glyph: "C",
                fill: palette.comparisonMarkerFill,
                border: palette.markerBorder,
                text: palette.markerGlyph,
                in: context
            )
        }

        drawHeader(frame: frame, in: context, bounds: bounds, palette: palette)
        drawPanels(frame: frame, in: context, bounds: bounds, palette: palette)
        drawProgress(frame: frame, in: context, bounds: bounds, palette: palette)
    }

    public func renderImage(
        frame: ComparisonVideoFrameModel,
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

    private func drawMarker(
        at point: CGPoint,
        glyph: String,
        fill: NSColor,
        border: NSColor,
        text: NSColor,
        in context: CGContext
    ) {
        let radius: CGFloat = 14
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.setFillColor(fill.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(border.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
        let font = NSFont.systemFont(ofSize: 14, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: text,
        ]
        let attributed = NSAttributedString(string: glyph, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(
            x: point.x - CGFloat(lineWidth) / 2,
            y: point.y - font.pointSize / 2 + 1
        )
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawHeader(
        frame: ComparisonVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
    ) {
        let margin: CGFloat = 28
        let panelWidth = min(bounds.width - margin * 2, 1_200)
        let panelHeight: CGFloat = 72
        let panelY = bounds.height - margin - panelHeight
        let panelRect = CGRect(x: margin, y: panelY, width: panelWidth, height: panelHeight)
        fillRoundedPanel(panelRect, in: context, color: palette.panelBackground, radius: 12)

        let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
        let metaFont = NSFont.systemFont(ofSize: 14, weight: .medium)
        let nameWidth = (panelRect.width - 80) / 2

        drawText(
            "P  \(frame.primaryTitle)",
            font: titleFont,
            color: palette.primaryMarkerFill,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.maxY - 34),
            maxWidth: nameWidth,
            in: context
        )
        drawText(
            "vs",
            font: metaFont,
            color: palette.secondaryText,
            at: CGPoint(x: panelRect.midX - 10, y: panelRect.maxY - 32),
            maxWidth: 40,
            in: context
        )
        drawText(
            "C  \(frame.comparisonTitle)",
            font: titleFont,
            color: palette.comparisonMarkerFill,
            at: CGPoint(x: panelRect.midX + 24, y: panelRect.maxY - 34),
            maxWidth: nameWidth,
            in: context
        )
        drawText(
            frame.sample.alignmentMode.displayName + " Alignment",
            font: metaFont,
            color: palette.secondaryText,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.minY + 14),
            maxWidth: panelRect.width - 32,
            in: context
        )
    }

    private func drawPanels(
        frame: ComparisonVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
    ) {
        let margin: CGFloat = 28
        let panelWidth: CGFloat = 300
        let sample = frame.sample

        let primaryRows = sideRows(
            distance: sample.primaryDistanceMeters,
            elapsed: sample.primaryElapsedSeconds,
            active: sample.primaryActiveSeconds,
            pace: sample.primaryActivePaceSecondsPerKm,
            labels: frame
        )
        let comparisonRows = sideRows(
            distance: sample.comparisonDistanceMeters,
            elapsed: sample.comparisonElapsedSeconds,
            active: sample.comparisonActiveSeconds,
            pace: sample.comparisonActivePaceSecondsPerKm,
            labels: frame
        )
        var deltaRows: [(String, String)] = [
            ("Elapsed Δ", formatDelta(sample.elapsedDeltaSeconds, kind: .time)),
            ("Active Δ", formatDelta(sample.activeDeltaSeconds, kind: .time)),
            ("Pace Δ", formatDelta(sample.activePaceDeltaSecondsPerKm, kind: .pace)),
        ]
        if sample.alignmentMode == .routeAware {
            if let separation = sample.spatialSeparationMeters {
                deltaRows.append(("Separation", formatSeparation(separation)))
            }
            if let quality = sample.alignmentQuality {
                deltaRows.append(("Quality", quality.displayName))
            }
            if let block = frame.blockLabel {
                deltaRows.append(("Block", block))
            }
        }
        if frame.routesAreWidelySeparated {
            deltaRows.append(("Note", "Routes far apart"))
        }

        let rowHeight: CGFloat = 24
        let primaryHeight = CGFloat(primaryRows.count) * rowHeight + 28
        let comparisonHeight = CGFloat(comparisonRows.count) * rowHeight + 28
        let deltaHeight = CGFloat(deltaRows.count) * rowHeight + 28
        let baseY = margin + 56

        drawMetricPanel(
            title: "P  Primary",
            rows: primaryRows,
            rect: CGRect(x: margin, y: baseY, width: panelWidth, height: primaryHeight),
            accent: palette.primaryMarkerFill,
            in: context,
            palette: palette
        )
        drawMetricPanel(
            title: "C  Comparison",
            rows: comparisonRows,
            rect: CGRect(
                x: margin,
                y: baseY + primaryHeight + 12,
                width: panelWidth,
                height: comparisonHeight
            ),
            accent: palette.comparisonMarkerFill,
            in: context,
            palette: palette
        )
        drawMetricPanel(
            title: "Deltas",
            rows: deltaRows,
            rect: CGRect(
                x: bounds.width - margin - panelWidth,
                y: baseY,
                width: panelWidth,
                height: deltaHeight
            ),
            accent: palette.secondaryText,
            in: context,
            palette: palette
        )
    }

    private func sideRows(
        distance: Double,
        elapsed: Double?,
        active: Double?,
        pace: Double?,
        labels: ComparisonVideoFrameModel
    ) -> [(String, String)] {
        [
            ("Distance", DisplayFormatter.formatDistanceKm(distance)),
            (labels.elapsedLabel, DisplayFormatter.formatElapsed(elapsed)),
            (labels.activeLabel, DisplayFormatter.formatElapsed(active)),
            (labels.paceLabel, DisplayFormatter.formatPace(pace)),
        ]
    }

    private func drawMetricPanel(
        title: String,
        rows: [(String, String)],
        rect: CGRect,
        accent: NSColor,
        in context: CGContext,
        palette: Palette
    ) {
        fillRoundedPanel(rect, in: context, color: palette.panelBackground, radius: 12)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

        drawText(
            title,
            font: titleFont,
            color: accent,
            at: CGPoint(x: rect.minX + 14, y: rect.maxY - 22),
            maxWidth: rect.width - 28,
            in: context
        )

        var y = rect.maxY - 44
        for (label, value) in rows {
            drawText(
                label,
                font: labelFont,
                color: palette.secondaryText,
                at: CGPoint(x: rect.minX + 14, y: y - 2),
                maxWidth: 120,
                in: context
            )
            drawText(
                value,
                font: valueFont,
                color: palette.primaryText,
                at: CGPoint(x: rect.minX + 130, y: y - 2),
                maxWidth: rect.width - 144,
                in: context
            )
            y -= 24
        }
    }

    private func drawProgress(
        frame: ComparisonVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
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

        let progress = CGFloat(min(1, max(0, frame.sample.progress)))
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

        let caption = "\(frame.domainProgressLabel)  ·  Output \(frame.progressPercentLabel)"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        drawText(
            caption,
            font: font,
            color: palette.primaryText,
            at: CGPoint(x: margin, y: margin),
            maxWidth: barWidth,
            in: context
        )
    }

    enum DeltaKind { case time, pace }

    func formatDelta(_ value: Double?, kind: DeltaKind) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        if abs(value) < (kind == .pace ? 0.5 : 0.05) {
            return "Tie"
        }
        let formatted: String
        switch kind {
        case .time:
            formatted = DisplayFormatter.formatSignedDurationDelta(
                value,
                positiveLabel: "",
                negativeLabel: ""
            )
            // delta = primary - comparison; positive means P took more time.
            if value > 0 {
                return "C ahead by \(stripSign(formatted))"
            }
            return "P ahead by \(stripSign(formatted))"
        case .pace:
            // Positive pace delta = primary slower (higher sec/km).
            // The faster/slower identity is carried by the P/C prefix below, so
            // the formatter's own trailing label must stay empty.
            let text = DisplayFormatter.formatSignedDurationDelta(
                value,
                suffix: "/km",
                positiveLabel: "",
                negativeLabel: ""
            )
            if value > 0 {
                return "C faster by \(stripSign(text))"
            }
            return "P faster by \(stripSign(text))"
        }
    }

    private func stripSign(_ text: String) -> String {
        var result = text
        if result.hasPrefix("+") || result.hasPrefix("−") || result.hasPrefix("-") {
            result = String(result.dropFirst())
        }
        return result
            .replacingOccurrences(of: " longer", with: "")
            .replacingOccurrences(of: " shorter", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func formatSeparation(_ meters: Double) -> String {
        guard meters.isFinite else { return "Unavailable" }
        if meters < 1 { return "<1 m" }
        return String(format: "%.0f m", meters)
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

    private func drawText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        at origin: CGPoint,
        maxWidth: CGFloat,
        in context: CGContext
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        context.saveGState()
        context.textPosition = origin
        context.clip(to: CGRect(
            x: origin.x,
            y: origin.y - 4,
            width: maxWidth,
            height: font.pointSize + 12
        ))
        CTLineDraw(line, context)
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
        let primaryMarkerFill: NSColor
        let comparisonMarkerFill: NSColor
        let markerBorder: NSColor
        let markerGlyph: NSColor
        let progressTrack: NSColor
        let progressFill: NSColor

        init(appearance: PNGSummaryExportAppearance) {
            primaryMarkerFill = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
            comparisonMarkerFill = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)
            switch appearance {
            case .light:
                background = NSColor(calibratedWhite: 0.92, alpha: 1)
                panelBackground = NSColor(calibratedWhite: 1.0, alpha: 0.88)
                primaryText = NSColor(calibratedWhite: 0.08, alpha: 1)
                secondaryText = NSColor(calibratedWhite: 0.28, alpha: 1)
                markerBorder = NSColor.black
                markerGlyph = NSColor.white
                progressTrack = NSColor(calibratedWhite: 0.75, alpha: 0.9)
                progressFill = NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
            case .dark:
                background = NSColor(calibratedWhite: 0.08, alpha: 1)
                panelBackground = NSColor(calibratedWhite: 0.12, alpha: 0.88)
                primaryText = NSColor(calibratedWhite: 0.96, alpha: 1)
                secondaryText = NSColor(calibratedWhite: 0.72, alpha: 1)
                markerBorder = NSColor.white
                markerGlyph = NSColor.black
                progressTrack = NSColor(calibratedWhite: 0.35, alpha: 0.9)
                progressFill = NSColor(calibratedRed: 0.4, green: 0.72, blue: 1.0, alpha: 1)
            }
        }
    }
}
