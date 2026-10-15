import XCTest
@testable import RunPlayCore

/// Sub-sport raw values are the FIT profile `sub_sport` enum, as Garmin's C++,
/// C, and Swift SDKs define it (`FIT_SUB_SPORT_*`, `SubSport`). The comment on
/// each value is its profile name.
final class FITSportPolicyTests: XCTestCase {

    func testRunningSubSportsUseTheirProfileNames() {
        let expected: [(rawValue: UInt8, name: String)] = [
            (1, "Treadmill"),  // treadmill
            (2, "Street"),     // street
            (3, "Trail"),      // trail
            (4, "Track"),      // track
            (45, "Indoor"),    // indoor_running
            (58, "Virtual"),   // virtual_activity
        ]
        for (rawValue, name) in expected {
            XCTAssertEqual(
                FITSportPolicy.subSportDescription(subSport: rawValue),
                name,
                "sub_sport \(rawValue)"
            )
        }
    }

    /// Values the profile assigns to other sports are not runs.
    func testSubSportsOfOtherSportsStayHidden() {
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 6))   // indoor_cycling
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 17))  // lap_swimming
    }

    func testMissingGenericInvalidAndUnknownSubSportsStayHidden() {
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: nil))
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 0))     // generic
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 0xFF))  // invalid
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 200))   // not in the profile
    }
}
