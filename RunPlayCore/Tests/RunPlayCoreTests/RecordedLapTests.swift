import XCTest
@testable import RunPlayCore

final class RecordedLapTests: XCTestCase {

    func testEmptyCollectionOnNewWorkout() {
        let workout = RunWorkout()
        XCTAssertTrue(workout.recordedLaps.isEmpty)
        XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.currentSourceStructureVersion)
    }

    func testOneLapRoundTrip() throws {
        let lap = RecordedLap(
            lapIndex: 1,
            source: .fit,
            trigger: .manual,
            sourceStartDate: Date(timeIntervalSince1970: 1_000),
            sourceEndDate: Date(timeIntervalSince1970: 1_300),
            startElapsedSeconds: 0,
            endElapsedSeconds: 300,
            startDistanceMeters: 0,
            endDistanceMeters: 1_000,
            distanceMeters: 1_000,
            elapsedSeconds: 300,
            activeSeconds: 280,
            movingSeconds: 260,
            stoppedSeconds: 20,
            pausedSeconds: 20,
            activePaceSecondsPerKilometer: 280,
            movingPaceSecondsPerKilometer: 260,
            elapsedPaceSecondsPerKilometer: 300,
            averageHeartRateBPM: 150,
            maximumHeartRateBPM: 165,
            averageCadence: 88,
            elevationGainMeters: 12,
            elevationLossMeters: 5,
            reportedMetrics: RecordedLapReportedMetrics(
                elapsedSeconds: 301,
                timerSeconds: 279,
                distanceMeters: 1_005,
                rawTriggerValue: "0"
            )
        )

        var workout = RunWorkout(source: .fit, recordedLaps: [lap])
        workout.sourceStructureVersion = RunWorkout.currentSourceStructureVersion

        let data = try JSONEncoder().encode(workout)
        let decoded = try JSONDecoder().decode(RunWorkout.self, from: data)

        XCTAssertEqual(decoded.recordedLaps.count, 1)
        let d = decoded.recordedLaps[0]
        XCTAssertEqual(d.lapIndex, 1)
        XCTAssertEqual(d.trigger, .manual)
        XCTAssertEqual(d.distanceMeters, 1_000, accuracy: 0.001)
        XCTAssertEqual(d.elapsedSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(d.activeSeconds, 280, accuracy: 0.001)
        XCTAssertEqual(d.movingSeconds, 260, accuracy: 0.001)
        XCTAssertEqual(d.stoppedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(d.pausedSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(d.reportedMetrics?.distanceMeters ?? -1, 1_005, accuracy: 0.001)
        XCTAssertEqual(d.reportedMetrics?.rawTriggerValue, "0")
    }

    func testUnknownTriggerRoundTrip() throws {
        let fitUnknown = RecordedLapTrigger.unknownFIT(42)
        let tcxUnknown = RecordedLapTrigger.unknownTCX("HeartRate")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let fitData = try encoder.encode(fitUnknown)
        XCTAssertEqual(try decoder.decode(RecordedLapTrigger.self, from: fitData), fitUnknown)

        let tcxData = try encoder.encode(tcxUnknown)
        XCTAssertEqual(try decoder.decode(RecordedLapTrigger.self, from: tcxData), tcxUnknown)
    }

    func testLegacySnapshotWithoutLapsDecodesEmpty() throws {
        // Minimal legacy-shaped payload without recordedLaps / sourceStructureVersion.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "metadata": { "activityType": "running" },
          "source": "fit",
          "routePoints": [],
          "splits": [],
          "summary": {
            "totalDistanceMeters": 0,
            "totalElapsedSeconds": 0,
            "totalActiveSeconds": 0,
            "totalPausedSeconds": 0,
            "averagePaceSecondsPerKilometer": 0,
            "averageSpeedMetersPerSecond": 0,
            "elevationGainMeters": 0,
            "elevationLossMeters": 0
          },
          "segments": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workout = try decoder.decode(RunWorkout.self, from: data)
        XCTAssertTrue(workout.recordedLaps.isEmpty)
        XCTAssertEqual(workout.sourceStructureVersion, RunWorkout.legacySourceStructureVersion)
        XCTAssertTrue(workout.mayRequireReimportForRecordedLaps)
    }

    func testInvariantEnforcement() {
        let lap = RecordedLap(
            lapIndex: 1,
            startDistanceMeters: 100,
            endDistanceMeters: 50, // less than start
            distanceMeters: 500,
            elapsedSeconds: 100,
            activeSeconds: 150, // exceeds elapsed
            movingSeconds: 200, // exceeds active
            stoppedSeconds: 0,
            pausedSeconds: 0
        )
        XCTAssertEqual(lap.activeSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(lap.movingSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(lap.stoppedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(lap.pausedSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(lap.endDistanceMeters, 100, accuracy: 0.001)
    }

    func testExplicitZeroClocksRemainValid() {
        let fullyPaused = RecordedLap(
            lapIndex: 1,
            elapsedSeconds: 30,
            activeSeconds: 0,
            movingSeconds: 0
        )
        XCTAssertEqual(fullyPaused.activeSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(fullyPaused.pausedSeconds, 30, accuracy: 0.001)

        let fullyStopped = RecordedLap(
            lapIndex: 2,
            elapsedSeconds: 30,
            activeSeconds: 30,
            movingSeconds: 0
        )
        XCTAssertEqual(fullyStopped.movingSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(fullyStopped.stoppedSeconds, 30, accuracy: 0.001)
    }

    func testNonFiniteValuesSanitised() {
        let lap = RecordedLap(
            lapIndex: 1,
            startElapsedSeconds: .nan,
            endElapsedSeconds: .infinity,
            distanceMeters: .nan,
            elapsedSeconds: -.infinity,
            averageHeartRateBPM: .nan
        )
        XCTAssertEqual(lap.startElapsedSeconds, 0)
        XCTAssertEqual(lap.distanceMeters, 0)
        XCTAssertEqual(lap.elapsedSeconds, 0)
        XCTAssertNil(lap.averageHeartRateBPM)
    }

    func testStableIDsThroughReanalysis() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var points: [RoutePoint] = []
        for i in 0..<11 {
            points.append(RoutePoint(
                timestamp: start.addingTimeInterval(Double(i) * 60),
                latitude: 37.7 + Double(i) * 0.001,
                longitude: -122.4,
                distanceFromStartMeters: Double(i) * 100,
                elapsedSeconds: Double(i) * 60
            ))
        }

        let id = UUID()
        let provisional = RecordedLap.provisional(
            id: id,
            lapIndex: 1,
            source: .tcx,
            trigger: .manual,
            sourceStartDate: start,
            sourceEndDate: start.addingTimeInterval(300),
            reportedMetrics: nil
        )

        var workout = RunWorkout(source: .tcx, routePoints: points, recordedLaps: [provisional])
        WorkoutAnalyzer().analyze(&workout)

        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertEqual(workout.recordedLaps[0].id, id)
        XCTAssertGreaterThan(workout.recordedLaps[0].distanceMeters, 0)

        let preservedID = workout.recordedLaps[0].id
        WorkoutAnalyzer().reanalyzePreservingRoutePoints(&workout)
        XCTAssertEqual(workout.recordedLaps[0].id, preservedID)
    }

    func testFITTriggerMapping() {
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(0), .manual)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(1), .time)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(2), .distance)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(3), .position)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(7), .sessionEnd)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(8), .fitnessEquipment)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(99), .unknownFIT(99))
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(nil), .unavailable)
        XCTAssertEqual(RecordedLapTrigger.fromFITLapTrigger(0xFF), .unavailable)
    }

    func testTCXTriggerMapping() {
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod("Manual"), .manual)
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod("Distance"), .distance)
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod("Time"), .time)
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod("Location"), .position)
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod("HeartRate"), .unknownTCX("HeartRate"))
        XCTAssertEqual(RecordedLapTrigger.fromTCXTriggerMethod(nil), .unavailable)
    }

    func testSplitsRemainIndependent() {
        let split = RunSplit(
            splitIndex: 1,
            distanceMeters: 1000,
            elapsedSeconds: 300,
            paceSecondsPerKilometer: 300,
            startDistanceMeters: 0,
            endDistanceMeters: 1000
        )
        let lap = RecordedLap(
            lapIndex: 1,
            startDistanceMeters: 0,
            endDistanceMeters: 800,
            distanceMeters: 800,
            elapsedSeconds: 250
        )
        let workout = RunWorkout(splits: [split], recordedLaps: [lap])
        XCTAssertEqual(workout.splits.count, 1)
        XCTAssertEqual(workout.recordedLaps.count, 1)
        XCTAssertNotEqual(workout.splits[0].distanceMeters, workout.recordedLaps[0].distanceMeters)
    }
}
