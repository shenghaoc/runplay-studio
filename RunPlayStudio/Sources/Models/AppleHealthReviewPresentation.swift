import Foundation
import RunPlayCore
import RunPlayPlatform

/// Everything the Apple Health review sheet shows about one candidate.
///
/// The sheet lays out these values; it does not derive them. Wording and the
/// selection rules live here so they can be tested without a window, and so the
/// view cannot become a second place where a distance is formatted or a flag is
/// interpreted.
///
/// Nothing here re-derives what `RunPlayCore` decided: route presence is
/// `hasRoute`, distance provenance is `distanceProvenance`, and a duplicate's
/// wording is its `statusDetail`.
enum AppleHealthReviewPresentation {

    // MARK: - Identity

    /// A readable name for a `HKWorkoutActivityType…` value.
    ///
    /// The export stores the HealthKit constant verbatim, which is not something
    /// to put in front of a reader. An unrecognized shape is returned unchanged
    /// rather than guessed at.
    static func activityName(_ rawActivityType: String) -> String {
        let prefix = "HKWorkoutActivityType"
        var remainder = rawActivityType
        if remainder.hasPrefix(prefix) { remainder.removeFirst(prefix.count) }
        return remainder.isEmpty ? "Workout" : spaced(remainder)
    }

    /// Split lowerCamelCase into words, keeping acronym runs together.
    private static func spaced(_ identifier: String) -> String {
        var words: [String] = []
        var current = ""
        let characters = Array(identifier)
        for (index, character) in characters.enumerated() {
            if character.isUppercase, !current.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // A word starts at a lowercase→uppercase boundary ("PoolSwim") or
                // at the last capital of an acronym run ("HRTraining").
                if previous.isLowercase || previous.isNumber || (next?.isLowercase ?? false) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    // MARK: - Duration and distance

    /// The workout's span, from its window.
    ///
    /// The window is the only duration a candidate has: a route-less one has no
    /// timestamps to measure, and deriving one from a statistic would state a
    /// number the export never gave for this row.
    static func durationText(_ window: AppleHealthWorkoutWindow) -> String {
        let seconds = max(0, window.endSeconds - window.startSeconds)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % 60)s"
    }

    /// The distance the export reports for this candidate, or a dash.
    ///
    /// A dash is not a zero: a routed candidate often carries no distance
    /// statistic because its route is where the distance comes from, and a
    /// route-less one with none has no distance to state. `distanceHelp` says
    /// which of those the dash means.
    static func distanceText(_ candidate: AppleHealthWorkoutCandidate) -> String {
        guard let meters = candidate.sourceDistanceMeters,
              meters.isFinite, meters > 0 else { return "—" }
        let kilometers = meters / 1_000
        let format = kilometers >= 100 ? "%.0f km" : kilometers >= 10 ? "%.1f km" : "%.2f km"
        return String(format: format, kilometers)
    }

    /// Where the distance column's number comes from.
    ///
    /// Stated rather than implied: a review that showed a figure without saying
    /// whether the export reported it or the route will measure it would invite
    /// comparing two columns that are not the same quantity.
    static func distanceHelp(_ candidate: AppleHealthWorkoutCandidate) -> String {
        candidate.distanceProvenance == .gpsDerived
            ? "Measured from this workout's route when it is imported"
            : "Reported by the export itself"
    }

    // MARK: - Route and heart rate

    static func hasRoute(_ candidate: AppleHealthWorkoutCandidate) -> Bool {
        candidate.hasRoute
    }

    static func hasHeartRate(_ candidate: AppleHealthWorkoutCandidate) -> Bool {
        !candidate.heartRate.isEmpty
    }

    static func routeAccessibilityLabel(_ candidate: AppleHealthWorkoutCandidate) -> String {
        candidate.hasRoute ? "Has a route" : "No route"
    }

    static func heartRateAccessibilityLabel(_ candidate: AppleHealthWorkoutCandidate) -> String {
        candidate.heartRate.isEmpty ? "No heart rate" : "Has heart rate"
    }

    // MARK: - Flags and selection

    /// Why a flagged candidate will not be imported unless the user says so.
    ///
    /// Composed from what Core decided rather than reworded: the summary says
    /// what the flag is and the detail says what it matched.
    static func flagText(_ candidate: AppleHealthWorkoutCandidate) -> String? {
        guard candidate.status != .ready else { return nil }
        guard let detail = candidate.statusDetail else {
            return candidate.status.userFacingSummary
        }
        return "\(candidate.status.userFacingSummary) — \(detail)"
    }

    /// Includes the full reason represented visually by the warning icon.
    static func rowAccessibilityLabel(_ candidate: AppleHealthWorkoutCandidate) -> String {
        [
            "Import \(activityName(candidate.window.activityType))",
            dateText(candidate.window),
            "Duration \(durationText(candidate.window))",
            "Distance \(distanceText(candidate)), \(distanceHelp(candidate))",
            routeAccessibilityLabel(candidate),
            heartRateAccessibilityLabel(candidate),
            flagText(candidate) ?? "Ready, no duplicates found",
        ].joined(separator: "; ")
    }

    /// Focus is independent of which rows are checked for import.
    static func flagDetailText(
        selectedCandidate: AppleHealthWorkoutCandidate?, flaggedCount: Int
    ) -> String? {
        if let selectedCandidate, let reason = flagText(selectedCandidate) { return reason }
        guard flaggedCount > 0 else { return nil }
        return "\(flaggedCount) \(flaggedCount == 1 ? "row" : "rows") flagged as duplicates or possible duplicates."
    }

    /// The candidates that start checked: only the unflagged ones.
    static func defaultSelection(_ candidates: [AppleHealthWorkoutCandidate]) -> Set<String> {
        Set(candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    static func readyCount(_ candidates: [AppleHealthWorkoutCandidate]) -> Int {
        candidates.count { $0.status == .ready }
    }

    static func flaggedCount(_ candidates: [AppleHealthWorkoutCandidate]) -> Int {
        candidates.count { $0.status != .ready }
    }

    // MARK: - Filtering

    /// The candidates a review should show, in export order.
    ///
    /// Search matches the fields the table shows, so a reader can find a row by
    /// whatever is in front of them. Flagged rows are hidden only by the
    /// explicit switch, never by the search box: a hidden duplicate is the one a
    /// user would most regret not seeing.
    static func filtered(
        _ candidates: [AppleHealthWorkoutCandidate],
        query: String,
        flaggedOnly: Bool
    ) -> [AppleHealthWorkoutCandidate] {
        var list = flaggedOnly ? candidates.filter { $0.status != .ready } : candidates
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            list = list.filter { candidate in
                [
                    activityName(candidate.window.activityType),
                    candidate.window.activityType,
                    candidate.status.userFacingSummary,
                    flagText(candidate) ?? "",
                    candidate.routeArchivePath ?? "",
                    dateText(candidate.window),
                ].joined(separator: "\n").lowercased().contains(needle)
            }
        }
        return list.sorted { $0.sourceIndex < $1.sourceIndex }
    }

    /// The date a row shows, as text, so search can match what is displayed.
    static func dateText(_ window: AppleHealthWorkoutWindow) -> String {
        dateText(
            startSeconds: window.startSeconds,
            utcOffsetSeconds: window.utcOffsetSeconds
        )
    }

    static func dateText(startSeconds: Int64, utcOffsetSeconds: Int = 0) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(startSeconds))
        return date.formatted(date: .abbreviated, time: .shortened)
            + offsetText(utcOffsetSeconds)
    }

    /// The recorded UTC offset, when the export stated one.
    ///
    /// Shown because it is what the workout's local time means, and because
    /// `WorkoutMetadata.recordedUTCOffsetSeconds` carries it into the library:
    /// two runs that look an hour apart on the clock can be the same instant.
    static func offsetText(_ utcOffsetSeconds: Int) -> String {
        guard utcOffsetSeconds != 0 else { return "" }
        let magnitude = abs(utcOffsetSeconds)
        return String(
            format: " (UTC%@%02d:%02d)",
            utcOffsetSeconds < 0 ? "−" : "+",
            magnitude / 3_600,
            (magnitude % 3_600) / 60
        )
    }

    /// Shared by review and final report, including exports with no runs.
    static func skippedNonRunningText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) non-running \(count == 1 ? "workout was" : "workouts were") skipped. "
            + "Only running workouts are offered for import."
    }

    // MARK: - Report rows

    /// One row of the post-import detail list.
    static func itemTitle(_ item: AppleHealthImportItemResult) -> String {
        "\(activityName(item.activityType)) · \(dateText(startSeconds: item.startSeconds))"
    }

    /// What happened to one candidate, as the report's second column.
    ///
    /// `discarded` is deliberately not "failed": the workout was built and
    /// staged and the library simply never received it. Calling it failed would
    /// blame the file; calling it imported would claim something untrue.
    static func itemOutcomeText(_ item: AppleHealthImportItemResult) -> String {
        switch item.outcome {
        case .imported: return "Imported"
        case .importedWithoutRoute: return "Imported without its route"
        case .alreadyInLibrary: return "Already in your library"
        case .discarded: return "Ready but not saved"
        case .failed: return "Could not be read"
        }
    }
}

/// The post-import report, in words a person would use.
///
/// Built entirely from an `AppleHealthImportReport`, because the two counts that
/// make an import come up short — a workout the export described that could not
/// be read, and a route a workout named that the archive does not hold — are
/// invisible in a list of imported runs. A report that showed only what was
/// imported would look complete while the export was not.
struct AppleHealthImportSummary: Equatable {

    enum Outcome: Equatable {
        /// Runs reached the library.
        case added
        /// Nothing was new, and nothing went wrong.
        case nothingNew
        case cancelled
        case failed
    }

    let outcome: Outcome
    let headline: String
    /// Plain-language sentences, most important first. Empty when there is
    /// nothing beyond the headline worth saying.
    let lines: [String]
    /// The two archive-level counts, so a report can show them as figures as
    /// well as in prose.
    let droppedWorkoutCount: Int
    let unmatchedRouteReferenceCount: Int

    init(report: AppleHealthImportReport) {
        self.droppedWorkoutCount = report.droppedWorkoutCount
        self.unmatchedRouteReferenceCount = report.unmatchedRouteReferenceCount

        let added = report.addedWorkoutCount
        if report.commitFailed {
            self.outcome = .failed
            self.headline = "The import could not be saved"
        } else if report.wasCancelled {
            self.outcome = .cancelled
            self.headline = "Import cancelled"
        } else if added > 0 {
            self.outcome = .added
            self.headline = "Imported \(added) \(added == 1 ? "run" : "runs")"
        } else {
            self.outcome = .nothingNew
            self.headline = "Nothing new to add"
        }

        var lines: [String] = []
        if let skipped = AppleHealthReviewPresentation.skippedNonRunningText(report.excludedWorkoutCount) {
            lines.append(skipped)
        }
        lines += Self.sentence(
            report.routeWindowMismatchCount, "run imported", "runs imported",
            "without a map because their route file didn't match the run's time."
        )
        lines += Self.sentence(
            report.trimmedRouteCount, "run had", "runs had",
            "their route trimmed to match the run's recorded time."
        )
        lines += Self.sentence(
            report.importedWithoutRouteCount - report.routeWindowMismatchCount, "run has", "runs have",
            "no route, because its route file could not be read."
        )
        lines += Self.sentence(
            report.alreadyInLibraryCount, "run was", "runs were",
            "already in your library."
        )
        lines += Self.sentence(
            report.failedCount, "workout could", "workouts could",
            "not be read from the export."
        )
        lines += Self.sentence(
            report.discardedCount, "workout was", "workouts were",
            "ready to import but not saved, because the pass did not finish. "
                + "Your library was left unchanged."
        )
        lines += Self.sentence(
            report.droppedWorkoutCount, "workout", "workouts",
            "this import cannot read, because their recorded dates are missing or "
                + "unreadable. They are not offered here.",
            prefix: "The export describes "
        )
        lines += Self.sentence(
            report.unmatchedRouteReferenceCount, "workout names", "workouts name",
            "a route file the archive does not contain."
        )
        self.lines = lines
    }

    /// One sentence for a nonzero count, or nothing at all for a zero.
    ///
    /// A count of zero is not a sentence: "0 workouts could not be read" reads
    /// as a finding, and there is none.
    private static func sentence(
        _ value: Int,
        _ singular: String,
        _ plural: String,
        _ tail: String,
        prefix: String = ""
    ) -> [String] {
        guard value > 0 else { return [] }
        return ["\(prefix)\(value) \(value == 1 ? singular : plural) \(tail)"]
    }
}
