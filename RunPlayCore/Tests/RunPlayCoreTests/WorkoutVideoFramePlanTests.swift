import XCTest
@testable import RunPlayCore

final class WorkoutVideoFramePlanTests: XCTestCase {
    func testPresetFrameCounts() throws {
        let policy = WorkoutVideoExportPolicy.production
        XCTAssertEqual(try policy.frameCount(for: .fifteenSeconds), 450)
        XCTAssertEqual(try policy.frameCount(for: .thirtySeconds), 900)
        XCTAssertEqual(try policy.frameCount(for: .sixtySeconds), 1_800)
    }

    func testFirstMidFinalSourceTimes() throws {
        let plan = try WorkoutVideoFramePlan(
            frameCount: 900,
            framesPerSecond: 30,
            sourceTotalElapsedSeconds: 3_600
        )
        XCTAssertEqual(plan.sourceElapsedSeconds(atFrameIndex: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(plan.progress(atFrameIndex: 0), 0, accuracy: 1e-12)

        // 900 frames → indices 0...899; exact 50% is halfway between 449 and 450.
        let midProgress = plan.progress(atFrameIndex: 450)
        XCTAssertEqual(midProgress, 450.0 / 899.0, accuracy: 1e-12)
        let mid = plan.sourceElapsedSeconds(atFrameIndex: 450)
        XCTAssertEqual(mid, (450.0 / 899.0) * 3_600, accuracy: 1e-9)

        XCTAssertEqual(
            plan.sourceElapsedSeconds(atFrameIndex: 899),
            3_600,
            accuracy: 1e-12
        )
        XCTAssertEqual(plan.progress(atFrameIndex: 899), 1, accuracy: 1e-12)
    }

    func testMonotonicProgressAndElapsed() throws {
        let plan = try WorkoutVideoFramePlan(
            frameCount: 450,
            framesPerSecond: 30,
            sourceTotalElapsedSeconds: 1_200
        )
        var previousProgress = -1.0
        var previousElapsed = -1.0
        for index in 0..<plan.frameCount {
            let progress = plan.progress(atFrameIndex: index)
            let elapsed = plan.sourceElapsedSeconds(atFrameIndex: index)
            XCTAssertGreaterThanOrEqual(progress, previousProgress)
            XCTAssertGreaterThanOrEqual(elapsed, previousElapsed)
            XCTAssertTrue(elapsed.isFinite)
            XCTAssertGreaterThanOrEqual(elapsed, 0)
            XCTAssertLessThanOrEqual(elapsed, 1_200)
            previousProgress = progress
            previousElapsed = elapsed
        }
    }

    func testRejectsZeroAndNonFiniteDuration() {
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan(
                frameCount: 30,
                framesPerSecond: 30,
                sourceTotalElapsedSeconds: 0
            )
        )
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan(
                frameCount: 30,
                framesPerSecond: 30,
                sourceTotalElapsedSeconds: .nan
            )
        )
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan(
                frameCount: 30,
                framesPerSecond: 30,
                sourceTotalElapsedSeconds: .infinity
            )
        )
    }

    func testRejectsSingleFrameAndOverflow() {
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan.frameCount(
                durationSeconds: 1,
                framesPerSecond: 1,
                maximumFrameCount: 1_800
            )
        )
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan.frameCount(
                durationSeconds: 120,
                framesPerSecond: 30,
                maximumFrameCount: 1_800
            )
        )
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan.frameCount(
                durationSeconds: Int.max,
                framesPerSecond: 30,
                maximumFrameCount: Int.max
            )
        )
    }

    func testPolicyValidationRequiresEvenDimensions() {
        let odd = WorkoutVideoExportPolicy(width: 1921, height: 1080)
        XCTAssertThrowsError(try odd.validate())
        XCTAssertNoThrow(try WorkoutVideoExportPolicy.production.validate())
    }

    func testPresentationTimeValuesAreExactFrameIndices() throws {
        let plan = try WorkoutVideoFramePlan(
            frameCount: 30,
            framesPerSecond: 10,
            sourceTotalElapsedSeconds: 100
        )
        XCTAssertEqual(plan.presentationTimeValue(atFrameIndex: 0), 0)
        XCTAssertEqual(plan.presentationTimeValue(atFrameIndex: 15), 15)
        XCTAssertEqual(plan.presentationTimeValue(atFrameIndex: 29), 29)
    }
}
