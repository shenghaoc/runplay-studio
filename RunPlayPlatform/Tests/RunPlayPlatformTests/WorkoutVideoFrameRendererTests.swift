import CoreGraphics
import CoreVideo
import XCTest
@testable import RunPlayCore
@testable import RunPlayPlatform

final class WorkoutVideoFrameRendererTests: XCTestCase {
    func testRenderImageExactDimensionsAndOpaque() throws {
        let map = try blankMap(width: 320, height: 180, color: (0.2, 0.4, 0.3))
        let model = makeModel(
            progress: 0.5,
            marker: CGPoint(x: 160, y: 90),
            heartRate: 150,
            elevation: 42
        )
        let renderer = WorkoutVideoFrameRenderer()
        let image = try renderer.renderImage(
            frame: model,
            staticMap: map,
            width: 320,
            height: 180,
            mapSize: CGSize(width: 320, height: 180)
        )
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
        XCTAssertGreaterThan(image.bitsPerPixel, 0)
    }

    func testProgressExtremesAndMissingMetrics() throws {
        let map = try blankMap(width: 160, height: 90, color: (0.1, 0.1, 0.1))
        let renderer = WorkoutVideoFrameRenderer()
        for progress in [0.0, 0.5, 1.0] {
            let model = makeModel(
                progress: progress,
                marker: progress == 0 ? CGPoint(x: 10, y: 45) : CGPoint(x: 150, y: 45),
                heartRate: nil,
                elevation: nil
            )
            let image = try renderer.renderImage(
                frame: model,
                staticMap: map,
                width: 160,
                height: 90,
                mapSize: CGSize(width: 160, height: 90)
            )
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 90)
        }
    }

    func testMarkerOmittedWhenNilDoesNotCrash() throws {
        let map = try blankMap(width: 160, height: 90, color: (0.3, 0.3, 0.3))
        let model = makeModel(progress: 0.2, marker: nil, heartRate: nil, elevation: nil)
        let longTitle = String(repeating: "Long Workout Title ", count: 8)
        let withTitle = WorkoutVideoFrameModel(
            frameIndex: model.frameIndex,
            frameCount: model.frameCount,
            sourceElapsedSeconds: model.sourceElapsedSeconds,
            sourceTotalElapsedSeconds: model.sourceTotalElapsedSeconds,
            progress: model.progress,
            workoutTitle: longTitle,
            workoutDateText: model.workoutDateText,
            markerPixel: nil,
            elapsedSeconds: model.elapsedSeconds,
            activeSeconds: model.activeSeconds,
            movingSeconds: model.movingSeconds,
            stoppedSeconds: model.stoppedSeconds,
            distanceMeters: model.distanceMeters,
            activePaceSecondsPerKilometer: model.activePaceSecondsPerKilometer,
            heartRateBPM: nil,
            correctedElevationMeters: nil,
            movementState: .stopped,
            isInRecordingGap: true,
            stateLabel: "Recording Gap",
            appearance: .dark,
            routeColorMode: .solid
        )
        let image = try WorkoutVideoFrameRenderer().renderImage(
            frame: withTitle,
            staticMap: map,
            width: 160,
            height: 90,
            mapSize: CGSize(width: 160, height: 90)
        )
        XCTAssertEqual(image.width, 160)
    }

    func testLightAndDarkAppearancesRender() throws {
        let map = try blankMap(width: 128, height: 72, color: (0.5, 0.5, 0.5))
        let renderer = WorkoutVideoFrameRenderer()
        for appearance in PNGSummaryExportAppearance.allCases {
            var model = makeModel(progress: 1, marker: CGPoint(x: 100, y: 36), heartRate: 120, elevation: 10)
            model = WorkoutVideoFrameModel(
                frameIndex: model.frameIndex,
                frameCount: model.frameCount,
                sourceElapsedSeconds: model.sourceElapsedSeconds,
                sourceTotalElapsedSeconds: model.sourceTotalElapsedSeconds,
                progress: 1,
                workoutTitle: model.workoutTitle,
                workoutDateText: model.workoutDateText,
                markerPixel: model.markerPixel,
                elapsedSeconds: model.elapsedSeconds,
                activeSeconds: model.activeSeconds,
                movingSeconds: model.movingSeconds,
                stoppedSeconds: model.stoppedSeconds,
                distanceMeters: model.distanceMeters,
                activePaceSecondsPerKilometer: model.activePaceSecondsPerKilometer,
                heartRateBPM: model.heartRateBPM,
                correctedElevationMeters: model.correctedElevationMeters,
                movementState: .moving,
                isInRecordingGap: false,
                stateLabel: "Running",
                appearance: appearance,
                routeColorMode: .pace
            )
            let image = try renderer.renderImage(
                frame: model,
                staticMap: map,
                width: 128,
                height: 72,
                mapSize: CGSize(width: 128, height: 72)
            )
            XCTAssertEqual(image.width, 128)
        }
    }

    // MARK: - Helpers

    private func makeModel(
        progress: Double,
        marker: CGPoint?,
        heartRate: Double?,
        elevation: Double?
    ) -> WorkoutVideoFrameModel {
        WorkoutVideoFrameModel(
            frameIndex: Int(progress * 9),
            frameCount: 10,
            sourceElapsedSeconds: progress * 100,
            sourceTotalElapsedSeconds: 100,
            progress: progress,
            workoutTitle: "Renderer Test",
            workoutDateText: "January 1, 2024",
            markerPixel: marker,
            elapsedSeconds: progress * 100,
            activeSeconds: progress * 90,
            movingSeconds: progress * 80,
            stoppedSeconds: progress * 10,
            distanceMeters: progress * 1_000,
            activePaceSecondsPerKilometer: 300,
            heartRateBPM: heartRate,
            correctedElevationMeters: elevation,
            movementState: .moving,
            isInRecordingGap: false,
            stateLabel: "Running",
            appearance: .light,
            routeColorMode: .solid
        )
    }

    private func blankMap(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        return image
    }
}
