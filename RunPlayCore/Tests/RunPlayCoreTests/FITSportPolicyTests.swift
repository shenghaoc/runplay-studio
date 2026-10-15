import XCTest
@testable import RunPlayCore

/// Sport and sub-sport raw values are the FIT profile `sport` and `sub_sport`
/// enums, as Garmin's C++, C, and Swift SDKs define them (`FIT_SPORT_*`,
/// `Sport`; `FIT_SUB_SPORT_*`, `SubSport`). The comment on each value is its
/// profile name.
final class FITSportPolicyTests: XCTestCase {

    /// The 82 values of SDK 21.218.0's `sport` enum (`FIT_SPORT_COUNT`).
    private static let profileSports = Set<UInt8>(0...49)
        .union([53, 56, 58, 59])
        .union(62...88)
        .union([254])

    /// `FITSport` models exactly the profile's sports. Only `running` and
    /// `wheelchair_push_run` import as runs; every other profile sport is
    /// unsupported. A value outside the profile, `invalid` (0xFF) included,
    /// is an unrecognised sport treated as running.
    func testFITSportModelsExactlyTheProfileSports() {
        XCTAssertEqual(Self.profileSports.count, 82)
        for rawValue in UInt8.min...UInt8.max {
            if Self.profileSports.contains(rawValue) {
                XCTAssertNotNil(FITSport(rawValue: rawValue), "sport \(rawValue)")
                XCTAssertEqual(
                    FITSportPolicy.classify(sport: rawValue),
                    (rawValue == 1 || rawValue == 66) ? .running : .unsupported,
                    "sport \(rawValue)"
                )
            } else {
                XCTAssertNil(FITSport(rawValue: rawValue), "sport \(rawValue)")
                XCTAssertEqual(
                    FITSportPolicy.classify(sport: rawValue), .unknownTreatedAsRunning,
                    "sport \(rawValue)"
                )
                XCTAssertEqual(
                    FITSportPolicy.displayName(sport: rawValue), "Unrecognised",
                    "sport \(rawValue)"
                )
            }
        }
    }

    /// The 26 sports that complete `FITSport` (56, 58, 59, 63, 65–75, 78–88).
    /// Without a case, a profile sport reads as "Unrecognised" and imports as
    /// a run, so each one pins its own name and classification.
    func testSportsAddedFromTheProfileHaveNamesAndClassifications() {
        let expected: [(rawValue: UInt8, name: String, classification: FITSessionSportClassification)] = [
            (56, "Sport shooting", .unsupported),        // shooting
            (58, "Winter sports", .unsupported),         // winter_sport
            (59, "Sail grinding", .unsupported),         // grinding
            (63, "Video gaming", .unsupported),          // video_gaming
            (65, "Wheelchair push walk", .unsupported),  // wheelchair_push_walk
            (66, "Wheelchair push run", .running),       // wheelchair_push_run
            (67, "Meditation", .unsupported),            // meditation
            (68, "Para sports", .unsupported),           // para_sport
            (69, "Disc golf", .unsupported),             // disc_golf
            (70, "Team sports", .unsupported),           // team_sport
            (71, "Cricket", .unsupported),               // cricket
            (72, "Rugby", .unsupported),                 // rugby
            (73, "Hockey", .unsupported),                // hockey
            (74, "Lacrosse", .unsupported),              // lacrosse
            (75, "Volleyball", .unsupported),            // volleyball
            (78, "Water sports", .unsupported),          // water_sport
            (79, "Archery", .unsupported),               // archery
            (80, "Mixed martial arts", .unsupported),    // mixed_martial_arts
            (81, "Motor sports", .unsupported),          // motor_sports
            (82, "Snorkeling", .unsupported),            // snorkeling
            (83, "Dance", .unsupported),                 // dance
            (84, "Jump rope", .unsupported),             // jump_rope
            (85, "Pool apnea", .unsupported),            // pool_apnea
            (86, "Mobility", .unsupported),              // mobility
            (87, "Geocaching", .unsupported),            // geocaching
            (88, "Canoeing", .unsupported),              // canoeing
        ]
        XCTAssertEqual(expected.count, 26)
        for (rawValue, name, classification) in expected {
            XCTAssertEqual(
                FITSportPolicy.classify(sport: rawValue), classification, "sport \(rawValue)"
            )
            XCTAssertEqual(FITSportPolicy.displayName(sport: rawValue), name, "sport \(rawValue)")
        }
    }

    /// A push run imports as a run, so its workout's activity type is
    /// `running`, the same value an unrecognised sport gets.
    func testWheelchairPushRunIsStoredAsARun() {
        XCTAssertEqual(FITSportPolicy.activityType(sport: 66), "running")  // wheelchair_push_run
    }

    func testRunningSubSportsUseTheirProfileNames() {
        let expected: [(rawValue: UInt8, name: String)] = [
            (1, "Treadmill"),        // treadmill
            (2, "Street"),           // street
            (3, "Trail"),            // trail
            (4, "Track"),            // track
            (45, "Indoor"),          // indoor_running
            (58, "Virtual"),         // virtual_activity
            (59, "Obstacle race"),   // obstacle
            (67, "Ultra"),           // ultra
            (82, "Adventure race"),  // adventure_race
            (87, "Indoor"),          // indoor_wheelchair_run
        ]
        for (rawValue, name) in expected {
            XCTAssertEqual(
                FITSportPolicy.subSportDescription(subSport: rawValue),
                name,
                "sub_sport \(rawValue)"
            )
        }
    }

    /// Values the profile assigns to sports that do not import as runs stay
    /// hidden. 86 has no sport comment, but its name pairs it with
    /// `wheelchair_push_walk` (65), which is unsupported, as walking is.
    func testSubSportsOfOtherSportsStayHidden() {
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 6))   // indoor_cycling
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 17))  // lap_swimming
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 86))  // indoor_wheelchair_walk
    }

    func testMissingGenericInvalidAndUnknownSubSportsStayHidden() {
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: nil))
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 0))     // generic
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 0xFF))  // invalid
        XCTAssertNil(FITSportPolicy.subSportDescription(subSport: 200))   // not in the profile
    }
}
