import Foundation
import XCTest
@testable import RunPlayCore

/// Power and running-dynamics analysis: summary aggregates, the segment-safe
/// best-20-minute window, timeline/split/segment means, the `.power`
/// route-metric mode, and JSON/CSV export fields.
final class PowerDynamicsAnalysisTests: XCTestCase {

    private func point(
        index: Int,
        seconds: Double,
        power: Double? = nil,
        groundContact: Double? = nil,
        verticalOscillation: Double? = nil,
        segment: Int = 0
    ) -> RoutePoint {
        RoutePoint(
            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
            latitude: 1.0 + Double(index) * 0.0001,
            longitude: 1.0 + Double(index) * 0.0001,
            altitudeMeters: 10,
            distanceFromStartMeters: Double(index) * 10,
            elapsedSeconds: seconds,
            powerWatts: power,
            groundContactTimeMilliseconds: groundContact,
            verticalOscillationMillimeters: verticalOscillation,
            routeSegmentIndex: segment
        )
    }

    // MARK: - Summary aggregates

    func testPowerAndDynamicsAveragesExcludeInvalidSamples() {
        let points = [
            point(index: 0, seconds: 0, power: 200, groundContact: 240, verticalOscillation: 8),
            point(index: 1, seconds: 10, power: 300, groundContact: 260, verticalOscillation: 10),
            point(index: 2, seconds: 20, power: -5),
            point(index: 3, seconds: 30, power: 9_999),
            point(index: 4, seconds: 40, groundContact: 10_000)
        ]

        let averages = WorkoutAnalyzer.powerAndDynamicsAverages(in: points)

        XCTAssertEqual(averages.averagePowerWatts, 250)
        XCTAssertEqual(averages.maxPowerWatts, 300)
        XCTAssertEqual(averages.averageGroundContactTimeMilliseconds, 250)
        XCTAssertEqual(averages.averageVerticalOscillationMillimeters, 9)
        XCTAssertNil(averages.averageVerticalRatioPercent)
        XCTAssertNil(averages.averageStanceTimeBalancePercent)
        XCTAssertNil(averages.averageStepLengthMeters)
    }

    func testBestTwentyMinutePowerSelectsHighestQualifyingWindow() {
        // 40 minutes at 30-second sampling. Power is 300 W from t=1140 on,
        // so the trailing 1200-second window [t-1200, t] contains only 300 W
        // samples (the sample exactly at the window edge is included).
        var points: [RoutePoint] = []
        for index in 0..<80 {
            let power = index < 38 ? 100.0 : 300.0
            points.append(point(index: index, seconds: Double(index) * 30, power: power))
        }

        let best = WorkoutAnalyzer.bestTimeWindowMeanPower(in: points, windowSeconds: 1_200)

        XCTAssertEqual(best ?? 0, 300, accuracy: 0.0001)
    }

    func testBestTwentyMinutePowerRequiresFullWindow() {
        // 19 minutes of samples: no qualifying window.
        var points: [RoutePoint] = []
        for index in 0..<39 {
            points.append(point(index: index, seconds: Double(index) * 30, power: 250))
        }

        XCTAssertNil(WorkoutAnalyzer.bestTimeWindowMeanPower(in: points, windowSeconds: 1_200))
    }

    func testBestTwentyMinuteWindowNeverSpansSegments() {
        // Two 15-minute segments of constant power; no 20-minute window fits
        // inside either segment, so the best value is nil even though the
        // whole run spans 30 minutes.
        var points: [RoutePoint] = []
        for index in 0..<30 {
            points.append(point(
                index: index,
                seconds: Double(index) * 30,
                power: index < 30 ? 250 : 250,
                segment: 0
            ))
        }
        for index in 30..<60 {
            points.append(point(
                index: index,
                seconds: Double(index) * 30,
                power: 250,
                segment: 1
            ))
        }

        XCTAssertNil(WorkoutAnalyzer.bestTimeWindowMeanPower(in: points, windowSeconds: 1_200))
    }

    func testLegacySummaryJSONDecodesWithoutPowerFields() throws {
        let legacyJSON = """
        {
          "totalDistanceMeters": 1000,
          "totalElapsedSeconds": 300,
          "averagePaceSecondsPerKilometer": 300,
          "averageSpeedMetersPerSecond": 3.33,
          "elevationGainMeters": 0,
          "elevationLossMeters": 0
        }
        """
        let summary = try JSONDecoder().decode(
            RunSummary.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(summary.averagePowerWatts)
        XCTAssertNil(summary.maxPowerWatts)
        XCTAssertNil(summary.best20MinutePowerWatts)
        XCTAssertNil(summary.averageGroundContactTimeMilliseconds)
    }

    // MARK: - Timeline, splits, segments

    func testEndToEndAnalysisPopulatesSummarySplitsAndSegments() throws {
        // 2.5 km at 10 m / 4 s spacing with alternating power.
        var points: [RoutePoint] = []
        for index in 0..<250 {
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index) * 4),
                latitude: 1.0 + Double(index) * 0.00009,
                longitude: 1.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index) * 4,
                heartRateBPM: 150,
                powerWatts: index.isMultiple(of: 2) ? 220 : 260,
                groundContactTimeMilliseconds: 250,
                verticalOscillationMillimeters: 9,
                routeSegmentIndex: 0
            ))
        }
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Power Run"),
            source: .fit,
            routePoints: points
        )

        try WorkoutAnalyzer().normalizeAndAnalyze(&workout, distancePolicy: .useSuppliedDistancesPerSegment)

        // Summary aggregates over alternating 220/260 → mean 240 (small
        // tolerance: normalization may drop isolated points, shifting parity).
        XCTAssertEqual(workout.summary.averagePowerWatts ?? 0, 240, accuracy: 0.5)
        XCTAssertEqual(workout.summary.maxPowerWatts, 260)
        // The run spans 1000 s (< 1200 s): no qualifying 20-minute window.
        XCTAssertNil(workout.summary.best20MinutePowerWatts)
        XCTAssertEqual(workout.summary.averageGroundContactTimeMilliseconds, 250)
        XCTAssertEqual(workout.summary.averageVerticalOscillationMillimeters, 9)

        // Splits carry per-split means.
        let firstSplit = try XCTUnwrap(workout.splits.first)
        XCTAssertEqual(firstSplit.averagePowerWatts ?? 0, 240, accuracy: 0.5)

        // Segment highlights carry power when any exist.
        if let segment = workout.segments.first {
            XCTAssertEqual(segment.averagePowerWatts ?? 0, 240, accuracy: 1.5)
        }
    }

    func testTimelineAveragePowerOverDistanceRange() throws {
        let timeline = WorkoutTimeline(
            routePoints: [
                point(index: 0, seconds: 0, power: 100),
                point(index: 10, seconds: 40, power: 200),
                point(index: 20, seconds: 80, power: 300),
                point(index: 30, seconds: 120, power: 9_999)
            ],
            elevationProfile: ElevationProfile(routePoints: [])
        )

        let average = try XCTUnwrap(timeline.averagePower(from: 0, to: 200))
        // The invalid 9,999 W sample is excluded, not averaged in.
        XCTAssertEqual(average, 200, accuracy: 0.001)
    }

    // MARK: - Route metric power mode

    func testPowerProfileProducesScaleAndBuckets() throws {
        var points: [RoutePoint] = []
        for index in 0..<60 {
            points.append(RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index) * 5),
                latitude: 1.0 + Double(index) * 0.0001,
                longitude: 1.0,
                altitudeMeters: 10,
                distanceFromStartMeters: Double(index) * 10,
                elapsedSeconds: Double(index) * 5,
                powerWatts: 180 + Double(index % 12) * 8,
                routeSegmentIndex: 0
            ))
        }
        let context = WorkoutAnalysisContext(
            routePoints: points,
            elevationProfile: ElevationProfile(routePoints: points)
        )

        let profile = try RouteMetricProfileBuilder().build(
            routePoints: points,
            context: context,
            mode: .power
        )

        XCTAssertNotNil(profile.scale)
        XCTAssertEqual(profile.scale?.direction, .higherIsMore)
        XCTAssertGreaterThan(profile.validCoverageFraction, 0.99)
        XCTAssertTrue(profile.intervals.allSatisfy { $0.bucket != .noData })
    }

    func testPowerModeUnavailableWithoutPowerData() throws {
        var points: [RoutePoint] = []
        for index in 0..<20 {
            points.append(point(index: index, seconds: Double(index) * 5))
        }
        let context = WorkoutAnalysisContext(
            routePoints: points,
            elevationProfile: ElevationProfile(routePoints: points)
        )

        let availability = try RouteMetricProfileBuilder().availability(
            routePoints: points,
            context: context
        )

        XCTAssertFalse(availability.power)
        XCTAssertNotNil(WorkoutRouteColorMode.power.unavailableReason)
        XCTAssertFalse(availability.isAvailable(.power))
        XCTAssertEqual(
            WorkoutRouteColorMode.power.relativeScaleCaption,
            "Relative power within this workout"
        )
    }

    // MARK: - Exports

    func testExportSummaryCarriesPowerDynamicsAndDeveloperFields() throws {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Power Run"),
            source: .fit,
            routePoints: [point(index: 0, seconds: 0, power: 250, groundContact: 250)]
        )
        workout.summary.averagePowerWatts = 250
        workout.summary.maxPowerWatts = 310
        workout.summary.best20MinutePowerWatts = 295
        workout.summary.averageGroundContactTimeMilliseconds = 252
        workout.summary.averageStepLengthMeters = 1.05
        workout.developerFieldSummary = WorkoutDeveloperFieldSummary(
            sources: [],
            fields: [],
            powerSourceDeveloperDataIndex: 0,
            powerSourceIsNativeRecordField: false,
            notes: []
        )

        let export = WorkoutExportSummary(workout: workout, segments: [])

        XCTAssertEqual(export.averagePowerWatts, 250)
        XCTAssertEqual(export.maxPowerWatts, 310)
        XCTAssertEqual(export.best20MinutePowerWatts, 295)
        let dynamics = try XCTUnwrap(export.runningDynamics)
        XCTAssertEqual(dynamics.averageGroundContactTimeMilliseconds, 252)
        XCTAssertEqual(dynamics.averageStepLengthMeters ?? 0, 1.05, accuracy: 0.0001)
        XCTAssertNotNil(export.developerFields)

        let encoded = try JSONEncoder().encode(export)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"averagePowerWatts\""))
        XCTAssertTrue(json.contains("\"best20MinutePowerWatts\""))
        XCTAssertTrue(json.contains("\"runningDynamics\""))
        XCTAssertTrue(json.contains("\"developerFields\""))
    }

    func testExportSummaryOmitsDynamicsWhenAbsent() throws {
        let workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Plain Run"),
            source: .gpx,
            routePoints: [point(index: 0, seconds: 0)]
        )
        let export = WorkoutExportSummary(workout: workout, segments: [])

        XCTAssertNil(export.averagePowerWatts)
        XCTAssertNil(export.runningDynamics?.averageGroundContactTimeMilliseconds)
        XCTAssertNil(export.developerFields)
    }

    func testCSVExportsCarryPowerColumnsAndDynamicsSection() {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Power Run"),
            source: .fit,
            routePoints: [point(index: 0, seconds: 0, power: 240)]
        )
        workout.summary.averagePowerWatts = 240
        workout.summary.best20MinutePowerWatts = 280
        workout.splits = [
            RunSplit(
                splitIndex: 1,
                elapsedSeconds: 300,
                paceSecondsPerKilometer: 300,
                averagePowerWatts: 240,
                startDistanceMeters: 0,
                endDistanceMeters: 1_000
            )
        ]

        let splitsCSV = ExportService().generateSplitsCSV(workout: workout)
        XCTAssertTrue(splitsCSV.contains("Avg_Power_W"))
        XCTAssertTrue(splitsCSV.contains("240"))

        let combined = ExportService().generateCombinedCSV(workout: workout, segments: [])
        XCTAssertTrue(combined.contains("# Running Dynamics"))
        XCTAssertTrue(combined.contains("Best 20 Minute Power"))
        XCTAssertTrue(combined.contains("W"))

        // Without power the dynamics section is omitted entirely.
        var plain = RunWorkout(
            metadata: WorkoutMetadata(name: "Plain Run"),
            source: .gpx,
            routePoints: [point(index: 0, seconds: 0)]
        )
        plain.splits = []
        let plainCombined = ExportService().generateCombinedCSV(workout: plain, segments: [])
        XCTAssertFalse(plainCombined.contains("# Running Dynamics"))
    }
}
