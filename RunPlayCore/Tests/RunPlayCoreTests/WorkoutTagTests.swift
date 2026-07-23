import XCTest
@testable import RunPlayCore

final class WorkoutTagTests: XCTestCase {
    private let policy = WorkoutTagPolicy.default

    func testNormalizeValidUnicodeName() throws {
        let name = try policy.normalizeName("  Race 🏃‍♂️  ")
        XCTAssertEqual(name.display, "Race 🏃‍♂️")
        XCTAssertFalse(name.folded.isEmpty)
    }

    func testEmptyNameRejected() {
        XCTAssertThrowsError(try policy.normalizeName("   ")) { error in
            XCTAssertEqual(error as? WorkoutTagPolicy.ValidationError, .emptyName)
        }
    }

    func testLineBreakRejected() {
        XCTAssertThrowsError(try policy.normalizeName("Race\nDay")) { error in
            XCTAssertEqual(error as? WorkoutTagPolicy.ValidationError, .containsLineBreak)
        }
    }

    func testNULRejected() {
        XCTAssertThrowsError(try policy.normalizeName("Race\0Day")) { error in
            XCTAssertEqual(error as? WorkoutTagPolicy.ValidationError, .containsNUL)
        }
    }

    func testNameTooLongRejected() {
        let long = String(repeating: "a", count: policy.maxNameScalars + 1)
        XCTAssertThrowsError(try policy.normalizeName(long)) { error in
            XCTAssertEqual(
                error as? WorkoutTagPolicy.ValidationError,
                .nameTooLong(limit: policy.maxNameScalars)
            )
        }
    }

    func testCaseInsensitiveDuplicate() throws {
        let existing = [WorkoutTag(name: "Race", color: .blue)]
        let normalized = try policy.normalizeName("race")
        XCTAssertThrowsError(
            try policy.validateUniqueName(normalized, existing: existing)
        ) { error in
            XCTAssertEqual(error as? WorkoutTagPolicy.ValidationError, .duplicateName("Race"))
        }
    }

    func testDiacriticInsensitiveDuplicate() throws {
        let existing = [WorkoutTag(name: "café", color: .green)]
        let normalized = try policy.normalizeName("CAFE")
        XCTAssertThrowsError(try policy.validateUniqueName(normalized, existing: existing))
    }

    func testWidthInsensitiveDuplicate() throws {
        // Fullwidth LATIN CAPITAL LETTER A vs ASCII A
        let existing = [WorkoutTag(name: "A", color: .gray)]
        let fullwidthA = "\u{FF21}"
        let normalized = try policy.normalizeName(fullwidthA)
        XCTAssertThrowsError(try policy.validateUniqueName(normalized, existing: existing))
    }

    func testTagLimit() {
        XCTAssertThrowsError(try policy.validateCanCreate(existingCount: policy.maxTags)) { error in
            XCTAssertEqual(
                error as? WorkoutTagPolicy.ValidationError,
                .tagLimitReached(limit: policy.maxTags)
            )
        }
    }

    func testTagsPerWorkoutLimit() {
        XCTAssertThrowsError(try policy.validateAssignmentCount(policy.maxTagsPerWorkout + 1))
    }

    func testStableIDThroughRename() {
        let id = UUID()
        var tag = WorkoutTag(id: id, name: "Race", color: .blue)
        tag.name = "Race Day"
        tag.color = .red
        XCTAssertEqual(tag.id, id)
    }

    func testAssignmentNormalizesAndSortsTagIDs() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let assignment = WorkoutTagAssignment(workoutID: UUID(), tagIDs: [a, b, a])
        XCTAssertEqual(assignment.tagIDs, [b, a])
    }

    func testColorUnknownTokenFallsBackToGray() throws {
        let json = Data(#""not-a-real-color""#.utf8)
        let color = try JSONDecoder().decode(WorkoutTagColor.self, from: json)
        XCTAssertEqual(color, .gray)
    }

    func testSmartCollectionNamePolicy() throws {
        let policy = WorkoutSmartCollectionPolicy.default
        let name = try policy.normalizeName("  2026 Long Runs  ")
        XCTAssertEqual(name.display, "2026 Long Runs")
        XCTAssertThrowsError(try policy.normalizeName(""))
        XCTAssertThrowsError(try policy.normalizeName("a\nb"))
    }

    func testSavedQueryHasNoClock() {
        let query = WorkoutLibrarySavedQuery(
            searchText: "race",
            filter: WorkoutLibraryFilter(tags: .untaggedOnly),
            sort: .distanceLongest
        )
        let runtime = query.makeRuntimeQuery(now: Date(timeIntervalSince1970: 1_700_000_000), calendar: .current)
        XCTAssertEqual(runtime.searchText, "race")
        XCTAssertEqual(runtime.sort, .distanceLongest)
        if case .untaggedOnly = runtime.filter.tags {
            // ok
        } else {
            XCTFail("Expected untaggedOnly")
        }
    }
}
