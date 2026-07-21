import AppKit
import ImageIO
import XCTest
@testable import RunPlayStudio
import RunPlayCore
import SwiftUI

@MainActor
final class PNGExportRendererTests: XCTestCase {
    func testExact1200x1600Dimensions() throws {
        let model = ExportSummaryCardModel(workout: sampleWorkout(), segments: [])
        let presentation = ExportSummaryCardPresentation(
            model: model,
            mapImage: nil,
            routeLegend: nil,
            appearance: .light,
            layout: .metricsOnly
        )
        let data = try PNGExportRenderer.renderPNG(
            from: ExportSummaryCardView(presentation: presentation),
            appearance: .light
        )
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertFalse(data.isEmpty)
    }

    func testDarkAndLightBothExactSizeAndDiffer() throws {
        let model = ExportSummaryCardModel(workout: sampleWorkout(), segments: [])
        let light = try PNGExportRenderer.renderPNG(
            from: ExportSummaryCardView(
                presentation: ExportSummaryCardPresentation(
                    model: model, mapImage: nil, routeLegend: nil,
                    appearance: .light, layout: .metricsOnly
                )
            ),
            appearance: .light
        )
        let dark = try PNGExportRenderer.renderPNG(
            from: ExportSummaryCardView(
                presentation: ExportSummaryCardPresentation(
                    model: model, mapImage: nil, routeLegend: nil,
                    appearance: .dark, layout: .metricsOnly
                )
            ),
            appearance: .dark
        )
        let lightSize = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: light))
        let darkSize = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: dark))
        XCTAssertEqual(lightSize.width, 1_200)
        XCTAssertEqual(lightSize.height, 1_600)
        XCTAssertEqual(darkSize.width, 1_200)
        XCTAssertEqual(darkSize.height, 1_600)
        XCTAssertNotEqual(light, dark)
    }

    func testDoesNotDependOnScreenScaleParameter() throws {
        let view = Rectangle()
            .fill(Color.blue)
            .frame(width: 1_200, height: 1_600)
        let data = try PNGExportRenderer.renderPNG(
            from: view,
            pixelSize: CGSize(width: 1_200, height: 1_600),
            scale: 1,
            appearance: .light
        )
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
    }

    func testInvalidScaleThrowsDescriptiveError() {
        let view = Rectangle().fill(Color.red).frame(width: 100, height: 100)
        XCTAssertThrowsError(
            try PNGExportRenderer.renderPNG(
                from: view,
                pixelSize: CGSize(width: 1_200, height: 1_600),
                scale: 0,
                appearance: .light
            )
        ) { error in
            let message = (error as? ExportError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("Invalid") || message.contains("Rendering"), message)
        }
    }

    func testEncodePNGHasNoGPSMetadataKeys() throws {
        let model = ExportSummaryCardModel(workout: sampleWorkout(), segments: [])
        let data = try PNGExportRenderer.renderPNG(
            from: ExportSummaryCardView(model: model),
            appearance: .light
        )
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("Could not read PNG properties")
        }
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        let keys = props.keys.map { String(describing: $0) }.joined(separator: ",")
        XCTAssertFalse(keys.lowercased().contains("gps"))
    }

    func testSyncMetricsOnlyExportIsExactly1200x1600() throws {
        let result = try PNGExportService.exportSummaryPNG(workout: sampleWorkout(), segments: [])
        let size = try XCTUnwrap(PNGExportRenderer.pngPixelSize(of: result.data))
        XCTAssertEqual(size.width, 1_200)
        XCTAssertEqual(size.height, 1_600)
        XCTAssertEqual(result.format, .png)
    }

    private func sampleWorkout() -> RunWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        points.reserveCapacity(20)
        for i in 0..<20 {
            let index = Double(i)
            points.append(
                RoutePoint(
                    timestamp: start.addingTimeInterval(index * 5),
                    latitude: 37.77 + index * 0.0001,
                    longitude: -122.42 + index * 0.0001,
                    altitudeMeters: 10,
                    distanceFromStartMeters: index * 10,
                    elapsedSeconds: index * 5
                )
            )
        }
        return RunWorkout(
            metadata: WorkoutMetadata(name: "Renderer Test Run", activityType: "run", startDate: start),
            source: .json,
            routePoints: points,
            summary: RunSummary(
                totalDistanceMeters: 190,
                totalElapsedSeconds: 95,
                averagePaceSecondsPerKilometer: 500
            )
        )
    }
}
