import XCTest
@testable import RunPlayCore

/// Locks the date-formatting contract of the two Core models that render a
/// workout start date for display: `RunWorkout.displayName` and
/// `ExportSummaryCardModel.dateText`.
///
/// Both follow `Locale.autoupdatingCurrent`, so these tests compare against a
/// reference `DateFormatter` built with the same configuration rather than
/// hard-coded strings. That keeps them deterministic on any CI locale while
/// still failing if either model's date or time style changes.
final class WorkoutDateTextTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_785_000_000)

    private func expected(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: referenceDate)
    }

    private func workout(name: String? = nil, startDate: Date? = nil) -> RunWorkout {
        RunWorkout(metadata: WorkoutMetadata(name: name, startDate: startDate))
    }

    // MARK: - RunWorkout.displayName

    func testDisplayNamePrefersMetadataName() {
        let workout = workout(name: "Morning Park Run", startDate: referenceDate)
        XCTAssertEqual(workout.displayName, "Morning Park Run")
    }

    func testDisplayNameIgnoresEmptyMetadataName() {
        let workout = workout(name: "", startDate: referenceDate)
        XCTAssertEqual(workout.displayName, expected(dateStyle: .medium, timeStyle: .short))
    }

    /// `displayName` must render medium date + short time. `Date.FormatStyle`
    /// has no `.medium` date style, so substituting
    /// `formatted(date: .abbreviated, time: .shortened)` changes this string in
    /// locales such as `de_DE`, `ja_JP`, and `zh_Hans_CN`.
    func testDisplayNameFallsBackToMediumDateShortTime() {
        let workout = workout(startDate: referenceDate)
        XCTAssertEqual(workout.displayName, expected(dateStyle: .medium, timeStyle: .short))
    }

    func testDisplayNameWithoutNameOrDateIsUntitled() {
        XCTAssertEqual(workout().displayName, "Untitled Run")
    }

    func testDisplayNameIsStableAcrossRepeatedAccess() {
        let workout = workout(startDate: referenceDate)
        XCTAssertEqual(workout.displayName, workout.displayName)
    }

    // MARK: - ExportSummaryCardModel.dateText

    func testExportCardDateTextUsesLongDateShortTime() {
        let card = ExportSummaryCardModel(workout: workout(startDate: referenceDate), segments: [])
        XCTAssertEqual(card.dateText, expected(dateStyle: .long, timeStyle: .short))
    }

    func testExportCardDateTextWithoutStartDateIsUnknown() {
        let card = ExportSummaryCardModel(workout: workout(), segments: [])
        XCTAssertEqual(card.dateText, "Unknown date")
    }

    /// The card title reuses `RunWorkout.displayName`, so the two styles must
    /// stay independent: the card date line is long-style, the title is not.
    func testExportCardTitleAndDateTextUseDistinctSources() {
        let card = ExportSummaryCardModel(workout: workout(startDate: referenceDate), segments: [])
        XCTAssertEqual(card.workoutTitle, expected(dateStyle: .medium, timeStyle: .short))
        XCTAssertEqual(card.dateText, expected(dateStyle: .long, timeStyle: .short))
    }
}
