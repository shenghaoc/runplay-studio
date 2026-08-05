import XCTest
@testable import RunPlayCore

final class ComparisonVideoFramePlanTests: XCTestCase {
    func testPresetFrameCountsMatchSingleWorkoutContract() throws {
        let policy = WorkoutVideoExportPolicy.production
        for duration in WorkoutVideoDuration.allCases {
            let plan = try ComparisonVideoFramePlan.make(
                duration: duration,
                policy: policy,
                domainLength: 5_000,
                domain: .commonDistance
            )
            XCTAssertEqual(plan.frameCount, try policy.frameCount(for: duration))
            XCTAssertEqual(plan.framesPerSecond, 30)
            XCTAssertEqual(plan.outputDurationSeconds, Double(duration.seconds), accuracy: 1e-12)
        }
    }

    func testFirstMidFinalDomainPositions() throws {
        let plan = try ComparisonVideoFramePlan(
            frameCount: 900,
            framesPerSecond: 30,
            domainLength: 5_000,
            domain: .commonDistance
        )
        XCTAssertEqual(plan.domainPosition(atFrameIndex: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(plan.progress(atFrameIndex: 0), 0, accuracy: 1e-12)

        let mid = plan.domainPosition(atFrameIndex: 450)
        XCTAssertEqual(mid, (450.0 / 899.0) * 5_000, accuracy: 1e-9)

        XCTAssertEqual(plan.domainPosition(atFrameIndex: 899), 5_000, accuracy: 1e-12)
        XCTAssertEqual(plan.progress(atFrameIndex: 899), 1, accuracy: 1e-12)
    }

    func testMonotonicProgressAndDomain() throws {
        let plan = try ComparisonVideoFramePlan(
            frameCount: 450,
            framesPerSecond: 30,
            domainLength: 3_200,
            domain: .alignedProgress
        )
        var previousProgress = -1.0
        var previousDomain = -1.0
        for index in 0..<plan.frameCount {
            let progress = plan.progress(atFrameIndex: index)
            let domain = plan.domainPosition(atFrameIndex: index)
            XCTAssertGreaterThanOrEqual(progress, previousProgress)
            XCTAssertGreaterThanOrEqual(domain, previousDomain)
            XCTAssertTrue(domain.isFinite)
            previousProgress = progress
            previousDomain = domain
        }
    }

    func testRejectsZeroAndNonFiniteDomain() {
        XCTAssertThrowsError(
            try ComparisonVideoFramePlan(
                frameCount: 30,
                framesPerSecond: 30,
                domainLength: 0,
                domain: .commonDistance
            )
        )
        XCTAssertThrowsError(
            try ComparisonVideoFramePlan(
                frameCount: 30,
                framesPerSecond: 30,
                domainLength: .nan,
                domain: .commonDistance
            )
        )
    }

    func testFrameCountOverflowUsesSharedArithmetic() {
        XCTAssertThrowsError(
            try WorkoutVideoFramePlan.frameCount(
                durationSeconds: Int.max,
                framesPerSecond: 30,
                maximumFrameCount: 1_800
            )
        )
    }
}
