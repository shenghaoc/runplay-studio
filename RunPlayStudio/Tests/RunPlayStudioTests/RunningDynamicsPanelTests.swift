import XCTest
@testable import RunPlayStudio
@testable import RunPlayCore

/// Running-dynamics panel presentation: pure row derivation, provenance
/// wording, and the power chart/table data path.
///
/// `@MainActor` because the helpers under test are statics on a SwiftUI
/// `View`, which is main-actor isolated. Swift 6.4 infers the isolation for
/// these calls and compiles without it; Swift 6.3.1 — the version CI pins and
/// verifies — does not, and rejects them as actor-isolated calls from a
/// nonisolated context. Matching the 28 other main-actor suites here keeps it
/// correct on both.
@MainActor
final class RunningDynamicsPanelTests: XCTestCase {

    private func powerWorkout() -> RunWorkout {
        var workout = RunWorkout(
            metadata: WorkoutMetadata(name: "Power Run"),
            source: .fit,
            routePoints: [
                RoutePoint(
                    timestamp: Date(timeIntervalSinceReferenceDate: 0),
                    latitude: 1,
                    longitude: 1,
                    powerWatts: 250,
                    groundContactTimeMilliseconds: 250,
                    verticalOscillationMillimeters: 9
                )
            ]
        )
        workout.summary.averagePowerWatts = 250
        workout.summary.maxPowerWatts = 310
        workout.summary.best20MinutePowerWatts = 295
        workout.summary.averageGroundContactTimeMilliseconds = 252
        workout.summary.averageVerticalOscillationMillimeters = 9.2
        workout.summary.averageStepLengthMeters = 1.05
        return workout
    }

    func testRowsDeriveUnitLabelledValuesInOrder() {
        let rows = RunningDynamicsPanel.rows(for: powerWorkout())

        XCTAssertEqual(rows.map(\.label), [
            "Average Power",
            "Max Power",
            "Best 20 min Power",
            "Average Ground Contact Time",
            "Average Vertical Oscillation",
            "Average Step Length"
        ])
        XCTAssertEqual(rows[0].value, "250 W")
        XCTAssertEqual(rows[3].value, "252 ms")
        XCTAssertEqual(rows[4].value, "9.2 mm")
        XCTAssertEqual(rows[5].value, "1.05 m")
    }

    func testRowsEmptyWithoutPowerOrDynamics() {
        let plain = RunWorkout(
            metadata: WorkoutMetadata(name: "Plain Run"),
            source: .gpx,
            routePoints: [
                RoutePoint(timestamp: Date(timeIntervalSinceReferenceDate: 0), latitude: 1, longitude: 1)
            ]
        )

        XCTAssertTrue(RunningDynamicsPanel.rows(for: plain).isEmpty)
        XCTAssertEqual(RunningDynamicsPanel.title(for: plain), "Power & Running Dynamics")
        XCTAssertNil(RunningDynamicsPanel.provenanceText(for: plain))
    }

    func testProvenanceNamesDeveloperApplication() {
        var workout = powerWorkout()
        workout.developerFieldSummary = WorkoutDeveloperFieldSummary(
            sources: [
                WorkoutDeveloperFieldSummary.Source(
                    developerDataIndex: 0,
                    developerIDHex: nil,
                    applicationIDHex: "112233445566778899aabbccddee0102",
                    manufacturerID: 255,
                    applicationVersion: 1
                )
            ],
            fields: [],
            powerSourceDeveloperDataIndex: 0,
            powerSourceIsNativeRecordField: false,
            dynamicsSourceIsNativeRecordField: false,
            notes: []
        )

        let provenance = RunningDynamicsPanel.provenanceText(for: workout)
        XCTAssertEqual(
            provenance,
            "Power from developer data index 0 (application id 112233445566778899aabbccddee0102)."
        )
    }

    func testProvenanceNamesNativeFieldWithoutSummary() {
        let provenance = RunningDynamicsPanel.provenanceText(for: powerWorkout())
        XCTAssertEqual(provenance, "Power from the watch's native power field.")
    }

    /// The most common hardware writes power and dynamics natively; the
    /// panel states both origins, independently.
    func testProvenanceStatesNativePowerAndDynamicsOrigins() {
        var workout = powerWorkout()
        workout.developerFieldSummary = WorkoutDeveloperFieldSummary(
            sources: [],
            fields: [],
            powerSourceDeveloperDataIndex: nil,
            powerSourceIsNativeRecordField: true,
            dynamicsSourceIsNativeRecordField: true,
            notes: []
        )

        XCTAssertEqual(
            RunningDynamicsPanel.provenanceText(for: workout),
            "Power from the watch's native power field. "
                + "Running dynamics from the watch's native record fields."
        )
    }

    /// A file with native power but developer-only dynamics states each
    /// origin separately rather than collapsing to one source.
    func testProvenanceDistinguishesMixedPowerAndDynamicsOrigins() {
        var workout = powerWorkout()
        workout.developerFieldSummary = WorkoutDeveloperFieldSummary(
            sources: [
                WorkoutDeveloperFieldSummary.Source(
                    developerDataIndex: 0,
                    developerIDHex: nil,
                    applicationIDHex: nil,
                    manufacturerID: nil,
                    applicationVersion: nil
                )
            ],
            fields: [
                WorkoutDeveloperFieldSummary.Field(
                    fieldName: "ground time",
                    unit: "ms",
                    baseType: "uint16",
                    scale: 1,
                    offset: 0,
                    developerDataIndex: 0,
                    mappedMetric: "groundContactTimeMilliseconds",
                    status: .mapped,
                    sampleCount: 10,
                    coverage: 1,
                    minimum: 240,
                    maximum: 300,
                    mean: 262
                )
            ],
            powerSourceDeveloperDataIndex: nil,
            powerSourceIsNativeRecordField: true,
            dynamicsSourceIsNativeRecordField: false,
            notes: []
        )

        XCTAssertEqual(
            RunningDynamicsPanel.provenanceText(for: workout),
            "Power from the watch's native power field. "
                + "Running dynamics from developer data."
        )
    }

    func testSmoothPowerPreservesAlignmentAndSegments() {
        let points = [
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 0),
                latitude: 1, longitude: 1,
                powerWatts: 200, routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 10),
                latitude: 1.0001, longitude: 1,
                powerWatts: 400, routeSegmentIndex: 0
            ),
            RoutePoint(
                timestamp: Date(timeIntervalSinceReferenceDate: 20),
                latitude: 5.0001, longitude: 1,
                powerWatts: 1_000_000, routeSegmentIndex: 1
            )
        ]

        let smoothed = MetricSmoother.smoothPower(from: points, windowSize: 5)

        XCTAssertEqual(smoothed.count, 3)
        XCTAssertEqual(smoothed[0], 300)
        XCTAssertEqual(smoothed[1], 300)
        // Invalid power (outside the plausible range) stays nil; smoothing
        // never crosses the segment boundary at index 2.
        XCTAssertNil(smoothed[2])
    }
}
