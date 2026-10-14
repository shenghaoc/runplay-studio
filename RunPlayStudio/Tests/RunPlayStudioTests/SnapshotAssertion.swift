import AppKit
import CoreGraphics
import Foundation
import XCTest

/// Minimal image snapshot comparison for rendered exports (no third-party
/// dependency).
///
/// References live in `RunPlayStudio/Tests/Snapshots/<group>/<name>.png`,
/// outside the test target so SwiftPM does not treat them as resources. They
/// are stored at half the rendered size: small enough to commit, still sharp
/// enough to show a missing glyph, a truncated label, or a moved column.
///
/// A render matches when fewer than `maximumDifferingPixelFraction` of its
/// pixels differ from the reference by more than `channelTolerance` in any
/// channel, which absorbs antialiasing differences between machines. The
/// bound is tight enough to fail a card whose text is in the other Chinese
/// script: the Simplified and Traditional summary cards differ in 0.19–0.26%
/// of pixels at this tolerance, four to five times the allowance. Glyph
/// shapes alone stay under it — a Traditional card drawn with Simplified
/// glyph shapes passes — so `ExportSummaryCardLocalizationTests` checks font
/// selection directly.
///
/// To (re)record after an intended visual change, run the suite with
/// `RUNPLAY_RECORD_SNAPSHOTS=1`, then inspect the written PNGs before
/// committing them. A new macOS release that updates system fonts can need a
/// re-record too. A missing reference fails rather than recording itself, so
/// CI cannot silently accept a new image.
enum SnapshotAssertion {
    static let referenceScale: CGFloat = 0.5
    static let channelTolerance = 32
    static let maximumDifferingPixelFraction = 0.0005

    static func referencesDirectory(group: String, filePath: StaticString = #filePath) -> URL {
        URL(filePath: "\(filePath)")
            .deletingLastPathComponent() // SnapshotAssertion.swift
            .deletingLastPathComponent() // RunPlayStudioTests
            .appendingPathComponent("Snapshots")
            .appendingPathComponent(group)
    }

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RUNPLAY_RECORD_SNAPSHOTS"] == "1"
    }

    static func assertMatches(
        _ image: CGImage,
        group: String,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let reduced = try downscaled(image, by: referenceScale)
        let directory = referencesDirectory(group: group)
        let referenceURL = directory.appendingPathComponent("\(name).png")

        if isRecording {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData(reduced).write(to: referenceURL, options: .atomic)
            return
        }

        guard let referenceData = try? Data(contentsOf: referenceURL),
              let source = CGImageSourceCreateWithData(referenceData as CFData, nil),
              let reference = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            let actualURL = try writeFailureArtifact(reduced, name: "\(name)-actual")
            XCTFail(
                "Missing snapshot reference \(referenceURL.path). Actual render: \(actualURL.path). "
                    + "Record with RUNPLAY_RECORD_SNAPSHOTS=1 and review it before committing.",
                file: file,
                line: line
            )
            return
        }

        guard reference.width == reduced.width, reference.height == reduced.height else {
            XCTFail(
                "Snapshot \(name) is \(reduced.width)×\(reduced.height); reference is \(reference.width)×\(reference.height)",
                file: file,
                line: line
            )
            return
        }

        let actualPixels = try rgbaPixels(reduced)
        let referencePixels = try rgbaPixels(reference)
        var differing = 0
        var diffPixels = [UInt8](repeating: 0, count: actualPixels.count)
        for index in stride(from: 0, to: actualPixels.count, by: 4) {
            var maximum = 0
            for channel in 0..<3 {
                let delta = abs(Int(actualPixels[index + channel]) - Int(referencePixels[index + channel]))
                maximum = max(maximum, delta)
            }
            if maximum > channelTolerance {
                differing += 1
                diffPixels[index] = 255
            }
            diffPixels[index + 3] = 255
        }
        let pixelCount = reduced.width * reduced.height
        let fraction = Double(differing) / Double(max(pixelCount, 1))
        if fraction > maximumDifferingPixelFraction {
            let actualURL = try writeFailureArtifact(reduced, name: "\(name)-actual")
            let diffURL = try writeFailureArtifact(
                try makeImage(fromRGBA: diffPixels, width: reduced.width, height: reduced.height),
                name: "\(name)-diff"
            )
            XCTFail(
                String(
                    format: "Snapshot %@ differs in %.2f%% of pixels (allowed %.2f%%). Actual: %@ Diff: %@",
                    name,
                    fraction * 100,
                    maximumDifferingPixelFraction * 100,
                    actualURL.path,
                    diffURL.path
                ),
                file: file,
                line: line
            )
        }
    }

    // MARK: - Pixels

    private static func downscaled(_ image: CGImage, by scale: CGFloat) throws -> CGImage {
        let width = Int((CGFloat(image.width) * scale).rounded())
        let height = Int((CGFloat(image.height) * scale).rounded())
        let context = try rgbaContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw SnapshotError.drawingFailed }
        return result
    }

    private static func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try rgbaContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { throw SnapshotError.drawingFailed }
        let count = image.width * image.height * 4
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private static func makeImage(fromRGBA pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        var copy = pixels
        return try copy.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                throw SnapshotError.drawingFailed
            }
            return image
        }
    }

    private static func rgbaContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SnapshotError.drawingFailed
        }
        return context
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        return data
    }

    /// Failure renders go to `RUNPLAY_SNAPSHOT_FAILURES_DIR` when it is set
    /// (CI uploads that directory), otherwise to the temporary directory.
    private static func writeFailureArtifact(_ image: CGImage, name: String) throws -> URL {
        let directory = ProcessInfo.processInfo.environment["RUNPLAY_SNAPSHOT_FAILURES_DIR"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("RunPlaySnapshotFailures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try pngData(image).write(to: url, options: .atomic)
        return url
    }

    enum SnapshotError: Error {
        case drawingFailed
        case encodingFailed
    }
}
