import Foundation

/// One standing or historical record effort within a scope.
public struct PersonalRecordEffort: Hashable, Sendable, Identifiable {
    public var id: UUID { workoutID }
    public let workoutID: UUID
    public let workoutName: String
    public let date: Date
    /// Seconds per kilometre for pace-window categories; metres for
    /// longest run and biggest ascent.
    public let value: Double
    public let averageHeartRateBPM: Double?
    /// The winning window for pace categories; `nil` for whole-run
    /// categories.
    public let window: PersonalRecordWindow?

    public init(
        workoutID: UUID,
        workoutName: String,
        date: Date,
        value: Double,
        averageHeartRateBPM: Double?,
        window: PersonalRecordWindow?
    ) {
        self.workoutID = workoutID
        self.workoutName = workoutName
        self.date = date
        self.value = value
        self.averageHeartRateBPM = averageHeartRateBPM
        self.window = window
    }
}

/// One category's derived record row: the current standing best plus the
/// progression of efforts that set or beat it.
public struct PersonalRecordRow: Hashable, Sendable, Identifiable {
    public var id: PersonalRecordCategory { category }
    public let category: PersonalRecordCategory
    /// Current standing best effort in scope; `nil` when the category was
    /// never attempted (for example, no run reaches the window distance).
    public let best: PersonalRecordEffort?
    /// Chronological progression of efforts that set a new standing best,
    /// oldest → newest, capped at the most recent `historyLimit` events.
    /// Equal-valued efforts never replace the earlier holder.
    public let history: [PersonalRecordEffort]

    public init(
        category: PersonalRecordCategory,
        best: PersonalRecordEffort?,
        history: [PersonalRecordEffort]
    ) {
        self.category = category
        self.best = best
        self.history = history
    }
}

/// Derived, library-level personal-records table. Never persisted: it
/// aggregates stored per-workout windows and summary values the same way the
/// Trends workspace derives its rows.
public struct PersonalRecordsSnapshot: Hashable, Sendable {
    public let rows: [PersonalRecordRow]
    public let includedWorkoutCount: Int
    /// Workouts in scope whose snapshot predates record computation — the
    /// remaining one-off backfill work.
    public let pendingBackfillWorkoutCount: Int

    public init(
        rows: [PersonalRecordRow],
        includedWorkoutCount: Int,
        pendingBackfillWorkoutCount: Int
    ) {
        self.rows = rows
        self.includedWorkoutCount = includedWorkoutCount
        self.pendingBackfillWorkoutCount = pendingBackfillWorkoutCount
    }

    /// Current standing best per category, whole-library semantics for
    /// workout Overview badges: a run whose record was later beaten holds
    /// nothing — its history lives in the row's progression.
    public var currentHolders: [PersonalRecordCategory: PersonalRecordEffort] {
        var holders: [PersonalRecordCategory: PersonalRecordEffort] = [:]
        for row in rows {
            if let best = row.best {
                holders[row.category] = best
            }
        }
        return holders
    }

    public func row(for category: PersonalRecordCategory) -> PersonalRecordRow? {
        rows.first { $0.category == category }
    }
}

/// Aggregates stored per-workout record windows and summary values into the
/// scoped personal-records table.
///
/// Inputs are pure stored snapshot data — never route points — so aggregation
/// is linear in workout count. Scoping happens in the caller: the workspace
/// view model resolves the current All Runs filter or smart collection to a
/// workout set (through `WorkoutTrendsScopeResolver`) and passes the filtered
/// workouts here.
public enum PersonalRecordsAggregator {

    public static let defaultHistoryLimit = 10

    public static func aggregate(
        workouts: [RunWorkout],
        historyLimit: Int = defaultHistoryLimit
    ) -> PersonalRecordsSnapshot {
        // Chronological, deterministic effort order shared by every category.
        let orderedWorkouts = workouts
            .filter { WorkoutLibraryEntry.canonicalStartDate(for: $0) != nil }
            .sorted { lhs, rhs in
                let lhsDate = WorkoutLibraryEntry.canonicalStartDate(for: lhs) ?? .distantPast
                let rhsDate = WorkoutLibraryEntry.canonicalStartDate(for: rhs) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var rows: [PersonalRecordRow] = []
        rows.reserveCapacity(PersonalRecordCategory.allCases.count)
        for category in PersonalRecordCategory.allCases {
            let efforts = efforts(for: category, in: orderedWorkouts)
            rows.append(row(for: category, efforts: efforts, historyLimit: historyLimit))
        }

        return PersonalRecordsSnapshot(
            rows: rows,
            includedWorkoutCount: workouts.count,
            pendingBackfillWorkoutCount: workouts.lazy
                .filter { $0.personalRecords == nil }
                .count
        )
    }

    /// The per-workout record efforts for one category in chronological
    /// order. Undated workouts cannot be ordered and are excluded, matching
    /// the Trends row-derivation rule.
    private static func efforts(
        for category: PersonalRecordCategory,
        in workouts: [RunWorkout]
    ) -> [PersonalRecordEffort] {
        var efforts: [PersonalRecordEffort] = []
        efforts.reserveCapacity(workouts.count)

        for workout in workouts {
            let date = WorkoutLibraryEntry.canonicalStartDate(for: workout)
                ?? .distantPast
            guard let effort = effort(for: category, workout: workout, date: date) else {
                continue
            }
            efforts.append(effort)
        }
        return efforts
    }

    private static func effort(
        for category: PersonalRecordCategory,
        workout: RunWorkout,
        date: Date
    ) -> PersonalRecordEffort? {
        if category.isPaceWindow {
            guard let window = workout.personalRecords?.window(for: category) else {
                return nil
            }
            return PersonalRecordEffort(
                workoutID: workout.id,
                workoutName: workout.displayName,
                date: date,
                value: window.paceSecondsPerKilometer,
                averageHeartRateBPM: window.averageHeartRateBPM,
                window: window
            )
        }

        let summary = workout.summary
        switch category {
        case .longestRun:
            let distance = summary.totalDistanceMeters
            guard distance.isFinite, distance > 0 else { return nil }
            return PersonalRecordEffort(
                workoutID: workout.id,
                workoutName: workout.displayName,
                date: date,
                value: distance,
                averageHeartRateBPM: nil,
                window: nil
            )
        case .biggestAscent:
            // Corrected ascent when the analysis produced a meaningful
            // profile or DEM elevation, else the persisted raw adjacent-delta
            // ascent; the same rule the Trends workspace uses.
            let ascent: Double?
            if workout.hasCorrectedElevationTotals {
                ascent = summary.elevationGainMeters
            } else {
                ascent = summary.rawElevationGainMeters
            }
            guard let ascent, ascent.isFinite, ascent > 0 else { return nil }
            return PersonalRecordEffort(
                workoutID: workout.id,
                workoutName: workout.displayName,
                date: date,
                value: ascent,
                averageHeartRateBPM: nil,
                window: nil
            )
        default:
            return nil
        }
    }

    /// Walks the chronological efforts once, recording every strict
    /// improvement as a progression event. The first effort sets the initial
    /// record; later equal-valued efforts never replace the standing holder.
    private static func row(
        for category: PersonalRecordCategory,
        efforts: [PersonalRecordEffort],
        historyLimit: Int
    ) -> PersonalRecordRow {
        var standingValue: Double? = nil
        var history: [PersonalRecordEffort] = []

        for effort in efforts {
            let isPace = category.isPaceWindow
            let improves: Bool
            if let standing = standingValue {
                improves = isPace ? effort.value < standing : effort.value > standing
            } else {
                improves = true
            }
            if improves {
                standingValue = effort.value
                history.append(effort)
            }
        }

        let limited = historyLimit > 0
            ? Array(history.suffix(historyLimit))
            : history
        return PersonalRecordRow(
            category: category,
            best: limited.last,
            history: limited
        )
    }
}
