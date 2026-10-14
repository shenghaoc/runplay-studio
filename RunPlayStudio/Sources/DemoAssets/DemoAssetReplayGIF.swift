#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import RunPlayPlatform
import UniformTypeIdentifiers

/// A small, continuously looping version of the actual exported route video.
enum DemoAssetReplayGIF {
    static let frameCount = 75
    static let frameDelay = 0.1
    static let playbackSpeed = 2
    static let framesPerSecond = 10

    static func render(video: URL, destination: URL, poster: URL) async throws {
        let imageGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 720, height: 405)
        imageGenerator.requestedTimeToleranceBefore = .zero
        imageGenerator.requestedTimeToleranceAfter = .zero

        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw DemoAssetError.unexpectedOutput("could not create an ImageIO GIF destination")
        }
        CGImageDestinationSetProperties(writer, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ] as CFDictionary

        for index in 0..<frameCount {
            let time = CMTime(value: Int64(index * playbackSpeed), timescale: Int32(framesPerSecond))
            let (image, _) = try await imageGenerator.image(at: time)
            if index == 0 {
                try PNGExportRenderer.encodePNG(cgImage: image).write(to: poster, options: .atomic)
            }
            CGImageDestinationAddImage(writer, image, frameProperties)
        }
        guard CGImageDestinationFinalize(writer) else {
            throw DemoAssetError.unexpectedOutput("could not encode \(destination.lastPathComponent)")
        }
        try (bytes as Data).write(to: destination, options: .atomic)
    }
}
#endif
