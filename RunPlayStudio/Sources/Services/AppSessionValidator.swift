import Foundation
import RunPlayCore

struct AppSessionValidationContext: Equatable, Sendable {
    var workoutIDs: Set<UUID>
    var selectedWorkoutID: UUID?
    var smartCollectionIDs: Set<UUID>
    var tagIDs: Set<UUID>
    var routeGroupIDs: Set<UUID>
    var replayDuration: Double?
    var comparisonDistanceLimit: Double?
    var workoutDistanceMetersByID: [UUID: Double]
    var referenceDate: Date

    init(
        workoutIDs: Set<UUID> = [],
        selectedWorkoutID: UUID? = nil,
        smartCollectionIDs: Set<UUID> = [],
        tagIDs: Set<UUID> = [],
        routeGroupIDs: Set<UUID> = [],
        replayDuration: Double? = nil,
        comparisonDistanceLimit: Double? = nil,
        workoutDistanceMetersByID: [UUID: Double] = [:],
        referenceDate: Date = Date()
    ) {
        self.workoutIDs = workoutIDs
        self.selectedWorkoutID = selectedWorkoutID
        self.smartCollectionIDs = smartCollectionIDs
        self.tagIDs = tagIDs
        self.routeGroupIDs = routeGroupIDs
        self.replayDuration = replayDuration
        self.comparisonDistanceLimit = comparisonDistanceLimit
        self.workoutDistanceMetersByID = workoutDistanceMetersByID
        self.referenceDate = referenceDate
    }
}

struct AppSessionValidationResult: Equatable, Sendable {
    let snapshot: AppSessionSnapshot
    let usedFallback: Bool
    let issues: [String]
}

/// Repairs persisted session state against lightweight facts from the loaded
/// application. It never needs route points, map images, or query results.
enum AppSessionValidator {
    static func validate(
        _ snapshot: AppSessionSnapshot,
        context: AppSessionValidationContext
    ) -> AppSessionValidationResult {
        var issues: [String] = []
        var usedFallback = false

        guard snapshot.version == AppSessionSnapshot.currentVersion else {
            return AppSessionValidationResult(
                snapshot: .safeDefault(selectedWorkoutID: context.selectedWorkoutID),
                usedFallback: true,
                issues: ["Unsupported session version."]
            )
        }

        let workout = AppSessionWorkoutState(
            tabRaw: repairedRaw(
                snapshot.workout.tabRaw,
                allowed: AppSessionPolicy.validWorkoutTabs,
                fallback: "Overview",
                issues: &issues,
                usedFallback: &usedFallback
            ),
            mapDisplayModeRaw: repairedRaw(
                snapshot.workout.mapDisplayModeRaw,
                allowed: AppSessionPolicy.validMapDisplayModes,
                fallback: "2D",
                issues: &issues,
                usedFallback: &usedFallback
            )
        )

        var destination = snapshot.destination
        let library = repairedLibrary(
            snapshot.library, context: context, destination: &destination,
            issues: &issues, usedFallback: &usedFallback
        )
        let heatmap = repairedHeatmap(snapshot.heatmap, context: context, issues: &issues, usedFallback: &usedFallback)
        let trends = repairedTrends(snapshot.trends, context: context, issues: &issues, usedFallback: &usedFallback)
        let personalRecords = repairedPersonalRecords(
            snapshot.personalRecords, context: context, issues: &issues, usedFallback: &usedFallback
        )

        var comparison = repairedComparison(
            snapshot.comparison, context: context, destination: &destination,
            issues: &issues, usedFallback: &usedFallback
        )

        if destination == .comparison, comparison == nil {
            destination = .workout
            usedFallback = true
        }
        if destination != .comparison {
            comparison = nil
        }

        let replay = repairedReplay(snapshot.replay, context: context, issues: &issues, usedFallback: &usedFallback)

        let sidebarVisibilityRaw = repairedRaw(
            snapshot.sidebarVisibilityRaw,
            allowed: AppSessionPolicy.validSidebarVisibility,
            fallback: "automatic",
            issues: &issues,
            usedFallback: &usedFallback
        )

        return makeResult(
            snapshot: AppSessionSnapshot(
                destination: destination,
                sidebarVisibilityRaw: sidebarVisibilityRaw,
                workout: workout,
                library: library,
                heatmap: heatmap,
                trends: trends,
                personalRecords: personalRecords,
                comparison: comparison,
                replay: replay
            ),
            usedFallback: usedFallback,
            issues: issues
        )
    }

    /// The manual and smart-collection library queries, and the destination
    /// that selects a smart collection: a missing collection or a missing
    /// modified query falls back, and only a smart-collection destination
    /// keeps an active collection.
    private static func repairedLibrary(
        _ library: AppSessionLibraryState,
        context: AppSessionValidationContext,
        destination: inout AppSessionDestination,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionLibraryState {
        let manualQuery = sanitizeQuery(
            library.manualQuery,
            validTagIDs: context.tagIDs,
            referenceDate: context.referenceDate,
            issues: &issues,
            usedFallback: &usedFallback
        )
        var activeCollectionID = library.activeSmartCollectionID
        var isModified = library.activeSmartCollectionModified
        var workingQuery = library.modifiedWorkingQuery.map {
            sanitizeQuery(
                $0,
                validTagIDs: context.tagIDs,
                referenceDate: context.referenceDate,
                issues: &issues,
                usedFallback: &usedFallback
            )
        }

        if let existingCollectionID = activeCollectionID,
           !context.smartCollectionIDs.contains(existingCollectionID) {
            activeCollectionID = nil
            isModified = false
            workingQuery = nil
            issues.append("Missing smart collection.")
            usedFallback = true
        }
        if !isModified {
            workingQuery = nil
        } else if workingQuery == nil {
            isModified = false
            issues.append("Missing modified smart-collection query.")
            usedFallback = true
        }

        if case .smartCollection(let destinationID) = destination {
            if !context.smartCollectionIDs.contains(destinationID) {
                destination = .allRuns
                activeCollectionID = nil
                isModified = false
                workingQuery = nil
                issues.append("Missing session destination collection.")
                usedFallback = true
            } else {
                activeCollectionID = destinationID
            }
        } else if case .allRuns = destination {
            // Manual All Runs has no active collection context.
            activeCollectionID = nil
            isModified = false
            workingQuery = nil
        } else {
            activeCollectionID = nil
            isModified = false
            workingQuery = nil
        }

        return AppSessionLibraryState(
            manualQuery: manualQuery,
            activeSmartCollectionID: activeCollectionID,
            activeSmartCollectionModified: isModified,
            modifiedWorkingQuery: workingQuery
        )
    }

    /// The heatmap date range, resolution, minimum count and route filter;
    /// an empty custom range becomes all time.
    private static func repairedHeatmap(
        _ persisted: AppSessionHeatmapState,
        context: AppSessionValidationContext,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionHeatmapState {
        var heatmapDatePreset = repairedRaw(
            persisted.datePresetRaw,
            allowed: AppSessionPolicy.validHeatmapDatePresets,
            fallback: "allTime",
            issues: &issues,
            usedFallback: &usedFallback
        )
        let heatmapDates = sanitizedDateRange(
            start: persisted.customStartDate,
            end: persisted.customEndDate,
            referenceDate: context.referenceDate,
            label: "heatmap",
            issues: &issues,
            usedFallback: &usedFallback
        )
        if heatmapDatePreset == "custom",
           heatmapDates.start == nil,
           heatmapDates.end == nil {
            heatmapDatePreset = "allTime"
            issues.append("Custom heatmap range was empty.")
            usedFallback = true
        }
        var heatmapRouteGroupID = persisted.routeGroupID
        if let existingRouteGroupID = heatmapRouteGroupID,
           !context.routeGroupIDs.contains(existingRouteGroupID) {
            heatmapRouteGroupID = nil
            issues.append("Missing heatmap route filter.")
            usedFallback = true
        }
        return AppSessionHeatmapState(
            datePresetRaw: heatmapDatePreset,
            customStartDate: heatmapDates.start,
            customEndDate: heatmapDates.end,
            resolutionRaw: repairedRaw(
                persisted.resolutionRaw,
                allowed: Set(PersonalHeatmapResolution.allCases.map(\.rawValue)),
                fallback: PersonalHeatmapResolution.standard.rawValue,
                issues: &issues,
                usedFallback: &usedFallback
            ),
            minimumWorkoutCount: sanitizedMinimumWorkoutCount(
                persisted.minimumWorkoutCount,
                issues: &issues,
                usedFallback: &usedFallback
            ),
            routeGroupID: heatmapRouteGroupID
        )
    }

    /// The Trends period, range and scope; a smart-collection scope needs a
    /// collection that still exists.
    private static func repairedTrends(
        _ persisted: AppSessionTrendsState,
        context: AppSessionValidationContext,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionTrendsState {
        var trendsScopeCollectionID = persisted.scopeSmartCollectionID
        if let existingCollectionID = trendsScopeCollectionID,
           !context.smartCollectionIDs.contains(existingCollectionID) {
            trendsScopeCollectionID = nil
            issues.append("Missing Trends scope collection.")
            usedFallback = true
        }
        var trendsScopeKindRaw = repairedRaw(
            persisted.scopeKindRaw,
            allowed: AppSessionPolicy.validTrendsScopeKinds,
            fallback: "entireLibrary",
            issues: &issues,
            usedFallback: &usedFallback
        )
        if trendsScopeKindRaw == "smartCollection", trendsScopeCollectionID == nil {
            trendsScopeKindRaw = "entireLibrary"
            issues.append("Trends smart-collection scope without a collection.")
            usedFallback = true
        }
        return AppSessionTrendsState(
            periodRaw: repairedRaw(
                persisted.periodRaw,
                allowed: AppSessionPolicy.validTrendsPeriods,
                fallback: WorkoutTrendsPeriod.month.rawValue,
                issues: &issues,
                usedFallback: &usedFallback
            ),
            rangeRaw: repairedRaw(
                persisted.rangeRaw,
                allowed: AppSessionPolicy.validTrendsRanges,
                fallback: WorkoutTrendsRange.last12Months.rawValue,
                issues: &issues,
                usedFallback: &usedFallback
            ),
            scopeKindRaw: trendsScopeKindRaw,
            scopeSmartCollectionID: trendsScopeCollectionID
        )
    }

    /// Records scope repair mirrors the Trends scope: the raw kinds are the
    /// same shared scope enum, so the same allowed set applies.
    private static func repairedPersonalRecords(
        _ persisted: AppSessionPersonalRecordsState,
        context: AppSessionValidationContext,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionPersonalRecordsState {
        var recordsScopeCollectionID = persisted.scopeSmartCollectionID
        if let existingCollectionID = recordsScopeCollectionID,
           !context.smartCollectionIDs.contains(existingCollectionID) {
            recordsScopeCollectionID = nil
            issues.append("Missing Records scope collection.")
            usedFallback = true
        }
        var recordsScopeKindRaw = repairedRaw(
            persisted.scopeKindRaw,
            allowed: AppSessionPolicy.validTrendsScopeKinds,
            fallback: "entireLibrary",
            issues: &issues,
            usedFallback: &usedFallback
        )
        if recordsScopeKindRaw == "smartCollection", recordsScopeCollectionID == nil {
            recordsScopeKindRaw = "entireLibrary"
            issues.append("Records smart-collection scope without a collection.")
            usedFallback = true
        }
        return AppSessionPersonalRecordsState(
            scopeKindRaw: recordsScopeKindRaw,
            scopeSmartCollectionID: recordsScopeCollectionID
        )
    }
    /// The persisted comparison when its peer is still a different available
    /// workout; otherwise none, and a comparison destination becomes the
    /// workout.
    private static func repairedComparison(
        _ persisted: AppSessionComparisonState?,
        context: AppSessionValidationContext,
        destination: inout AppSessionDestination,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionComparisonState? {
        guard let persistedComparison = persisted else { return nil }
        let validPrimary = context.selectedWorkoutID
        let validPeer = context.workoutIDs.contains(persistedComparison.peerWorkoutID)
            && persistedComparison.peerWorkoutID != validPrimary
        if validPrimary == nil || !validPeer {
            issues.append("Invalid comparison peer.")
            usedFallback = true
            if destination == .comparison { destination = .workout }
            return nil
        }
        return repairedComparisonState(
            persistedComparison, context: context, issues: &issues, usedFallback: &usedFallback
        )
    }

    /// A valid comparison's distance (clamped to the shorter route or the
    /// given limit), alignment mode and aligned progress.
    private static func repairedComparisonState(
        _ persistedComparison: AppSessionComparisonState,
        context: AppSessionValidationContext,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionComparisonState {
        let rawDistance = persistedComparison.distanceMeters
        let repairedDistance: Double
        if rawDistance.isFinite, rawDistance >= 0 {
            repairedDistance = rawDistance
        } else {
            issues.append("Invalid comparison distance.")
            usedFallback = true
            repairedDistance = 0
        }
        let derivedLimit = derivedDistanceLimit(context: context, peerWorkoutID: persistedComparison.peerWorkoutID)
        let limit = (context.comparisonDistanceLimit ?? derivedLimit)
            .flatMap { $0.isFinite ? max(0, $0) : nil }
        let modeRaw = ComparisonAlignmentMode(rawValue: persistedComparison.alignmentModeRaw)?.rawValue
            ?? ComparisonAlignmentMode.distance.rawValue
        if modeRaw != persistedComparison.alignmentModeRaw {
            issues.append("Invalid comparison alignment mode.")
            usedFallback = true
        }
        let rawAligned = persistedComparison.alignedProgressMeters
        let repairedAligned: Double
        if rawAligned.isFinite, rawAligned >= 0 {
            repairedAligned = rawAligned
        } else {
            issues.append("Invalid comparison aligned progress.")
            usedFallback = true
            repairedAligned = 0
        }
        return AppSessionComparisonState(
            peerWorkoutID: persistedComparison.peerWorkoutID,
            distanceMeters: limit.map { min(repairedDistance, $0) } ?? repairedDistance,
            alignmentModeRaw: modeRaw,
            alignedProgressMeters: repairedAligned
        )
    }

    /// The shorter of the selected and peer workout distances, when both
    /// are known and finite.
    private static func derivedDistanceLimit(
        context: AppSessionValidationContext, peerWorkoutID: UUID
    ) -> Double? {
        guard let selectedID = context.selectedWorkoutID,
              let selectedDistance = context.workoutDistanceMetersByID[selectedID],
              let peerDistance = context.workoutDistanceMetersByID[peerWorkoutID],
              selectedDistance.isFinite, peerDistance.isFinite else {
            return nil
        }
        return min(max(0, selectedDistance), max(0, peerDistance))
    }

    /// The persisted replay of the selected available workout, with its time
    /// clamped to the replay and a supported speed; otherwise a fresh replay
    /// of the selected workout, if any.
    private static func repairedReplay(
        _ persisted: AppSessionReplayState?,
        context: AppSessionValidationContext,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> AppSessionReplayState? {
    if let persistedReplay = persisted {
        let validWorkout = context.workoutIDs.contains(persistedReplay.workoutID)
            && persistedReplay.workoutID == context.selectedWorkoutID
        if !validWorkout {
            issues.append("Replay workout is not the selected available workout.")
            usedFallback = true
            return context.selectedWorkoutID.map {
                AppSessionReplayState(workoutID: $0)
            }
        } else {
            let duration = context.replayDuration.map { max(0, $0) }
            let elapsed = persistedReplay.elapsedSeconds.isFinite
                ? max(0, persistedReplay.elapsedSeconds)
                : 0
            if !persistedReplay.elapsedSeconds.isFinite || persistedReplay.elapsedSeconds < 0 {
                issues.append("Invalid replay time.")
                usedFallback = true
            }
            let clampedElapsed = duration.map { min(elapsed, $0) } ?? elapsed
            if duration.map({ elapsed > $0 }) == true {
                issues.append("Replay time was clamped.")
                usedFallback = true
            }
            let speed = AppSessionPolicy.replaySpeedOptions.contains(persistedReplay.playbackSpeed)
                ? persistedReplay.playbackSpeed
                : 1
            if speed != persistedReplay.playbackSpeed {
                issues.append("Invalid replay speed.")
                usedFallback = true
            }
            return AppSessionReplayState(
                workoutID: persistedReplay.workoutID,
                elapsedSeconds: clampedElapsed,
                playbackSpeed: speed
            )
        }
    } else if let selectedWorkoutID = context.selectedWorkoutID {
        return AppSessionReplayState(workoutID: selectedWorkoutID)
    }
    return nil
    }

    private static func makeResult(
        snapshot: AppSessionSnapshot,
        usedFallback: Bool,
        issues: [String]
    ) -> AppSessionValidationResult {
        AppSessionValidationResult(
            snapshot: snapshot,
            usedFallback: usedFallback,
            issues: issues
        )
    }

    private static func repairedRaw(
        _ raw: String,
        allowed: Set<String>,
        fallback: String,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> String {
        guard allowed.contains(raw) else {
            issues.append("Invalid session enum value.")
            usedFallback = true
            return fallback
        }
        return raw
    }

    private static func sanitizedDateRange(
        start: Date?,
        end: Date?,
        referenceDate: Date,
        label: String,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> (start: Date?, end: Date?) {
        let sanitizedStart = sanitizedDate(start, referenceDate: referenceDate)
        let sanitizedEnd = sanitizedDate(end, referenceDate: referenceDate)
        if start != nil, sanitizedStart == nil {
            issues.append("Invalid \(label) start date.")
            usedFallback = true
        }
        if end != nil, sanitizedEnd == nil {
            issues.append("Invalid \(label) end date.")
            usedFallback = true
        }
        if let sanitizedStart, let sanitizedEnd, sanitizedStart > sanitizedEnd {
            issues.append("Invalid \(label) date range.")
            usedFallback = true
            return (nil, nil)
        }
        return (sanitizedStart, sanitizedEnd)
    }

    private static func sanitizedDate(_ date: Date?, referenceDate: Date) -> Date? {
        guard let date,
              date.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              abs(date.timeIntervalSince(referenceDate)) <= AppSessionPolicy.maxCustomDateAge else {
            return nil
        }
        return date
    }

    private static func sanitizeQuery(
        _ query: WorkoutLibrarySavedQuery,
        validTagIDs: Set<UUID>,
        referenceDate: Date,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> WorkoutLibrarySavedQuery {
        let boundedQuery = AppSessionPolicy.boundedQuery(query)
        if boundedQuery.searchText != query.searchText {
            issues.append("Query search text exceeded the session limit.")
            usedFallback = true
        }

        let date: WorkoutLibraryDateFilter
        switch query.filter.date {
        case .allTime, .last30Days, .last90Days, .currentCalendarYear:
            date = query.filter.date
        case .custom(let start, let end):
            let dates = sanitizedDateRange(
                start: start,
                end: end,
                referenceDate: referenceDate,
                label: "query",
                issues: &issues,
                usedFallback: &usedFallback
            )
            if dates.start == nil, dates.end == nil {
                date = .allTime
            } else {
                date = .custom(start: dates.start, end: dates.end)
            }
        }

        let tags: WorkoutLibraryTagFilter
        switch query.filter.tags {
        case .anyTags, .untaggedOnly:
            tags = query.filter.tags
        case .selected(let tagIDs, let match):
            let valid = tagIDs.intersection(validTagIDs)
            if valid.isEmpty {
                if !tagIDs.isEmpty {
                    issues.append("Dangling query tag references were removed.")
                    usedFallback = true
                }
                tags = .anyTags
            } else {
                tags = .selected(tagIDs: valid, match: match)
            }
        }

        return WorkoutLibrarySavedQuery(
            searchText: boundedQuery.searchText,
            filter: WorkoutLibraryFilter(
                favorite: query.filter.favorite,
                date: date,
                source: query.filter.source,
                data: query.filter.data,
                tags: tags
            ),
            sort: query.sort
        )
    }

    private static func sanitizedMinimumWorkoutCount(
        _ value: Int,
        issues: inout [String],
        usedFallback: inout Bool
    ) -> Int {
        guard AppSessionPolicy.validHeatmapMinimumWorkoutCounts.contains(value) else {
            issues.append("Invalid heatmap minimum workout count.")
            usedFallback = true
            return 1
        }
        return value
    }
}
