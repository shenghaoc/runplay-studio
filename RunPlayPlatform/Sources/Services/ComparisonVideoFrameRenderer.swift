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
    /// Language and number format of the frame's text; `nil` follows the app.
    /// Exports pass `nil`; tests pin a locale.
    public let locale: Locale?

    public init(
        sample: ComparisonVideoFrameSample,
        primaryTitle: String,
        comparisonTitle: String,
        primaryMarkerPixel: CGPoint?,
        comparisonMarkerPixel: CGPoint?,
        appearance: PNGSummaryExportAppearance,
        routesAreWidelySeparated: Bool = false,
        locale: Locale? = nil
    ) {
        self.sample = sample
        self.primaryTitle = primaryTitle
        self.comparisonTitle = comparisonTitle
        self.primaryMarkerPixel = primaryMarkerPixel
        self.comparisonMarkerPixel = comparisonMarkerPixel
        self.appearance = appearance
        self.routesAreWidelySeparated = routesAreWidelySeparated
        self.locale = locale
    }

    public var progressPercentLabel: String {
        let wholePercent = (sample.progress * 100).rounded(.down)
        return (wholePercent / 100).formatted(
            .percent.precision(.fractionLength(0)).locale(locale ?? .autoupdatingCurrent)
        )
    }

    public var domainProgressLabel: String {
        // "1.23 / 5.00 km": the position as a bare number, the length with its unit.
        let position = DisplayFormatter.formatDecimal(sample.domainPositionMeters / 1000, fractionDigits: 2, locale: locale)
        let length = DisplayFormatter.formatDistanceKm(sample.domainLengthMeters, locale: locale)
        switch sample.alignmentMode {
        case .distance:
            return platformLocalized("Common Distance \(position) / \(length)", locale: locale)
        case .routeAware:
            return platformLocalized("Matched Route \(position) / \(length)", locale: locale)
        }
    }

    public var elapsedLabel: String {
        sample.alignmentMode == .routeAware
            ? platformLocalized("Matched Elapsed", locale: locale)
            : platformLocalized("Elapsed", locale: locale)
    }

    public var activeLabel: String {
        sample.alignmentMode == .routeAware
            ? platformLocalized("Matched Active", locale: locale)
            : platformLocalized("Active", locale: locale)
    }

    public var paceLabel: String {
        sample.alignmentMode == .routeAware
            ? platformLocalized("Matched Pace", locale: locale)
            : platformLocalized("Active Pace", locale: locale)
    }

    public var blockLabel: String? {
        guard let index = sample.alignmentBlockIndex,
              let count = sample.alignmentBlockCount,
              count > 1 else { return nil }
        let ordinal = index + 1
        return platformLocalized("Block \(ordinal) of \(count)", locale: locale)
    }

    /// The caption under the progress bar.
    public var progressCaption: String {
        let domain = domainProgressLabel
        let percent = progressPercentLabel
        return platformLocalized("\(domain)  ·  Output \(percent)", locale: locale)
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
        let language = VideoHUDText.languageTag(for: frame.locale)
        let versus = platformLocalized("vs", locale: frame.locale)
        let versusWidth = VideoHUDText.width(versus, font: metaFont, language: language)

        // "P" and "C" match the map markers' glyphs, so they stay Latin.
        VideoHUDText.draw(
            "P  \(frame.primaryTitle)",
            font: titleFont,
            color: palette.primaryMarkerFill,
            language: language,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.maxY - 34),
            maxWidth: nameWidth,
            in: context
        )
        VideoHUDText.draw(
            versus,
            font: metaFont,
            color: palette.secondaryText,
            language: language,
            at: CGPoint(x: panelRect.midX + 7 - versusWidth / 2, y: panelRect.maxY - 32),
            maxWidth: 40,
            in: context
        )
        VideoHUDText.draw(
            "C  \(frame.comparisonTitle)",
            font: titleFont,
            color: palette.comparisonMarkerFill,
            language: language,
            at: CGPoint(x: panelRect.midX + 24, y: panelRect.maxY - 34),
            maxWidth: nameWidth,
            in: context
        )
        let modeName = frame.sample.alignmentMode.displayName
        VideoHUDText.draw(
            platformLocalized("\(modeName) Alignment", locale: frame.locale),
            font: metaFont,
            color: palette.secondaryText,
            language: language,
            at: CGPoint(x: panelRect.minX + 16, y: panelRect.minY + 14),
            maxWidth: panelRect.width - 32,
            in: context
        )
    }

    /// The three panels' titles and label/value rows in the frame's language.
    struct PanelRows {
        var primaryTitle: String
        var primary: [(label: String, value: String)]
        var comparisonTitle: String
        var comparison: [(label: String, value: String)]
        var deltasTitle: String
        var deltas: [(label: String, value: String)]
    }

    func panelRows(for frame: ComparisonVideoFrameModel) -> PanelRows {
        let sample = frame.sample
        let locale = frame.locale
        var deltaRows: [(label: String, value: String)] = [
            (platformLocalized("Elapsed Δ", locale: locale), formatDelta(sample.elapsedDeltaSeconds, kind: .time, locale: locale)),
            (platformLocalized("Active Δ", locale: locale), formatDelta(sample.activeDeltaSeconds, kind: .time, locale: locale)),
            (platformLocalized("Pace Δ", locale: locale), formatDelta(sample.activePaceDeltaSecondsPerKm, kind: .pace, locale: locale)),
        ]
        if sample.alignmentMode == .routeAware {
            if let separation = sample.spatialSeparationMeters {
                deltaRows.append((platformLocalized("Separation", locale: locale), formatSeparation(separation, locale: locale)))
            }
            if let quality = sample.alignmentQuality {
                deltaRows.append((platformLocalized("Quality", locale: locale), quality.displayName))
            }
            if let block = frame.blockLabel {
                deltaRows.append((platformLocalized("Block", locale: locale), block))
            }
        }
        if frame.routesAreWidelySeparated {
            deltaRows.append((platformLocalized("Note", locale: locale), platformLocalized("Routes far apart", locale: locale)))
        }
        // "P" and "C" match the map markers' glyphs, so they stay Latin.
        let primaryName = platformLocalized("Primary", locale: locale)
        let comparisonName = platformLocalized("Comparison", locale: locale)
        return PanelRows(
            primaryTitle: "P  \(primaryName)",
            primary: sideRows(
                distance: sample.primaryDistanceMeters,
                elapsed: sample.primaryElapsedSeconds,
                active: sample.primaryActiveSeconds,
                pace: sample.primaryActivePaceSecondsPerKm,
                labels: frame
            ),
            comparisonTitle: "C  \(comparisonName)",
            comparison: sideRows(
                distance: sample.comparisonDistanceMeters,
                elapsed: sample.comparisonElapsedSeconds,
                active: sample.comparisonActiveSeconds,
                pace: sample.comparisonActivePaceSecondsPerKm,
                labels: frame
            ),
            deltasTitle: platformLocalized("Deltas", locale: locale),
            deltas: deltaRows
        )
    }

    /// One shared column layout for all three panels so their values align:
    /// values start after the widest label (never left of the original
    /// 130 pt) and panels widen for long values, within the frame.
    func panelColumns(for rows: PanelRows, language: String, frameWidth: CGFloat) -> VideoHUDText.RowColumns {
        let all = rows.primary + rows.comparison + rows.deltas
        return VideoHUDText.rowColumns(
            labels: all.map(\.label),
            values: all.map(\.value),
            labelFont: Self.panelLabelFont,
            valueFont: Self.panelValueFont,
            language: language,
            inset: 14,
            gap: 12,
            minimumValueOffset: 130,
            minimumPanelWidth: 300,
            maximumPanelWidth: max(300, (frameWidth - 28 * 2 - 24) / 2)
        )
    }

    private static var panelTitleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    private static var panelLabelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }
    private static var panelValueFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) }

    private func drawPanels(
        frame: ComparisonVideoFrameModel,
        in context: CGContext,
        bounds: CGRect,
        palette: Palette
    ) {
        let margin: CGFloat = 28
        let language = VideoHUDText.languageTag(for: frame.locale)
        let rows = panelRows(for: frame)
        let columns = panelColumns(for: rows, language: language, frameWidth: bounds.width)
        let panelWidth = columns.panelWidth

        let rowHeight: CGFloat = 24
        let primaryHeight = CGFloat(rows.primary.count) * rowHeight + 28
        let comparisonHeight = CGFloat(rows.comparison.count) * rowHeight + 28
        let deltaHeight = CGFloat(rows.deltas.count) * rowHeight + 28
        let baseY = margin + 56

        drawMetricPanel(
            title: rows.primaryTitle,
            rows: rows.primary,
            rect: CGRect(x: margin, y: baseY, width: panelWidth, height: primaryHeight),
            columns: columns,
            language: language,
            accent: palette.primaryMarkerFill,
            in: context,
            palette: palette
        )
        drawMetricPanel(
            title: rows.comparisonTitle,
            rows: rows.comparison,
            rect: CGRect(
                x: margin,
                y: baseY + primaryHeight + 12,
                width: panelWidth,
                height: comparisonHeight
            ),
            columns: columns,
            language: language,
            accent: palette.comparisonMarkerFill,
            in: context,
            palette: palette
        )
        drawMetricPanel(
            title: rows.deltasTitle,
            rows: rows.deltas,
            rect: CGRect(
                x: bounds.width - margin - panelWidth,
                y: baseY,
                width: panelWidth,
                height: deltaHeight
            ),
            columns: columns,
            language: language,
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
    ) -> [(label: String, value: String)] {
        [
            (platformLocalized("Distance", locale: labels.locale), DisplayFormatter.formatDistanceKm(distance, locale: labels.locale)),
            (labels.elapsedLabel, DisplayFormatter.formatElapsed(elapsed)),
            (labels.activeLabel, DisplayFormatter.formatElapsed(active)),
            (labels.paceLabel, DisplayFormatter.formatPace(pace, locale: labels.locale)),
        ]
    }

    private func drawMetricPanel(
        title: String,
        rows: [(label: String, value: String)],
        rect: CGRect,
        columns: VideoHUDText.RowColumns,
        language: String,
        accent: NSColor,
        in context: CGContext,
        palette: Palette
    ) {
        fillRoundedPanel(rect, in: context, color: palette.panelBackground, radius: 12)

        VideoHUDText.draw(
            title,
            font: Self.panelTitleFont,
            color: accent,
            language: language,
            at: CGPoint(x: rect.minX + columns.inset, y: rect.maxY - 22),
            maxWidth: rect.width - columns.inset * 2,
            in: context
        )

        var y = rect.maxY - 44
        for (label, value) in rows {
            VideoHUDText.draw(
                label,
                font: Self.panelLabelFont,
                color: palette.secondaryText,
                language: language,
                at: CGPoint(x: rect.minX + columns.inset, y: y - 2),
                maxWidth: columns.valueOffset - columns.inset - 6,
                in: context
            )
            VideoHUDText.draw(
                value,
                font: Self.panelValueFont,
                color: palette.primaryText,
                language: language,
                at: CGPoint(x: rect.minX + columns.valueOffset, y: y - 2),
                maxWidth: columns.valueWidth,
                in: context
            )
            y -= 24
        }
    }

    private func drawProgress(
        frame: ComparisonVideoFrameModel,
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

    enum DeltaKind { case time, pace }

    func formatDelta(_ value: Double?, kind: DeltaKind, locale: Locale? = nil) -> String {
        guard let value, value.isFinite else { return platformLocalized("Unavailable", locale: locale) }
        if abs(value) < (kind == .pace ? 0.5 : 0.05) {
            return platformLocalized("Tie", locale: locale)
        }
        switch kind {
        case .time:
            let amount = stripSign(DisplayFormatter.formatSignedDurationDelta(
                value,
                positiveLabel: "",
                negativeLabel: "",
                locale: locale
            ))
            // delta = primary - comparison; positive means P took more time.
            if value > 0 {
                return platformLocalized("C ahead by \(amount)", locale: locale)
            }
            return platformLocalized("P ahead by \(amount)", locale: locale)
        case .pace:
            // Positive pace delta = primary slower (higher sec/km).
            // The faster/slower identity is carried by the P/C prefix below, so
            // the formatter's own trailing label must stay empty.
            let amount = stripSign(DisplayFormatter.formatSignedDurationDelta(
                value,
                suffix: DisplayFormatter.perKilometerSuffix(locale: locale),
                positiveLabel: "",
                negativeLabel: "",
                locale: locale
            ))
            if value > 0 {
                return platformLocalized("C faster by \(amount)", locale: locale)
            }
            return platformLocalized("P faster by \(amount)", locale: locale)
        }
    }

    /// Drops the leading sign; the empty direction labels leave only
    /// trailing whitespace to trim.
    private func stripSign(_ text: String) -> String {
        var result = text
        if result.hasPrefix("+") || result.hasPrefix("−") || result.hasPrefix("-") {
            result = String(result.dropFirst())
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Whole metres with the locale's unit ("12 m", "12米"); under a metre
    /// reads "<1 m".
    private func formatSeparation(_ meters: Double, locale: Locale?) -> String {
        guard meters.isFinite else { return platformLocalized("Unavailable", locale: locale) }
        if meters < 1 { return "<" + DisplayFormatter.formatElevation(1, locale: locale) }
        return DisplayFormatter.formatElevation(meters, locale: locale)
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
