import Foundation
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// UI-facing state for the personal heatmap workspace.
enum PersonalHeatmapLoadState: Equatable {
    case idle
    case loading
    case ready
    case empty(PersonalHeatmapEmptyReason)
    case failed(String)
}

enum PersonalHeatmapEmptyReason: Equatable {
    /// Library has no GPS workouts at all.
    case noGPSWorkouts
    /// Filters excluded every workout (date range, etc.).
    case filterExcludedAll
    /// Aggregation produced no cells (e.g. all invalid geometry).
    case noCells
}

/// User-facing date preset for the heatmap filter bar.
enum PersonalHeatmapDatePreset: String, CaseIterable, Identifiable, Hashable {
    case allTime
    case last30Days
    case last90Days
    case currentYear
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: return "All Time"
        case .last30Days: return "Last 30 Days"
        case .last90Days: return "Last 90 Days"
        case .currentYear: return "This Year"
        case .custom: return "Custom"
        }
    }
}

/// Strongly typed cache / request key so library content changes invalidate.
struct PersonalHeatmapRequestKey: Hashable, Sendable {
    struct WorkoutRevision: Hashable, Sendable {
        let id: UUID
        let normalizationVersion: Int
        let pointCount: Int
        let firstPointID: UUID?
        let lastPointID: UUID?
        let startDate: Date?
    }

    let workouts: [WorkoutRevision]
    let datePreset: PersonalHeatmapDatePreset
    let customStart: Date?
    let customEnd: Date?
    let resolution: PersonalHeatmapResolution
    let minimumWorkoutCount: Int
    /// Resolved "now" used for relative date filters (injected for testability).
    /// Floored to the hour so relative-filter cache keys stay stable within a session hour.
    let now: Date

    init(
        workouts: [RunWorkout],
        datePreset: PersonalHeatmapDatePreset,
        customStart: Date?,
        customEnd: Date?,
        resolution: PersonalHeatmapResolution,
        minimumWorkoutCount: Int,
        now: Date
    ) {
        self.workouts = workouts.map {
            WorkoutRevision(
                id: $0.id,
                normalizationVersion: $0.normalizationVersion,
                pointCount: $0.routePoints.count,
                firstPointID: $0.routePoints.first?.id,
                lastPointID: $0.routePoints.last?.id,
                startDate: $0.metadata.startDate
            )
        }
        self.datePreset = datePreset
        self.customStart = customStart
        self.customEnd = customEnd
        self.resolution = resolution
        self.minimumWorkoutCount = minimumWorkoutCount
        self.now = now
    }
}

/// Protocol for injectable heatmap building (production + tests).
protocol PersonalHeatmapBuilding: Sendable {
    func build(
        workouts: [RunWorkout],
        configuration: PersonalHeatmapConfiguration,
        isCancelled: @Sendable () -> Bool
    ) throws -> PersonalHeatmapSnapshot
}

extension PersonalHeatmapBuilder: PersonalHeatmapBuilding {}

/// Thread-safe cancel flag shared with off-main builder work.
///
/// `Task.detached` is not a child of the requesting `Task`, so parent
/// cancellation alone does not stop detached work. The flag bridges both.
private final class HeatmapCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Dedicated view model for the Personal Heatmap workspace.
///
/// Owns filter selections, background aggregation, stale-request suppression,
/// and an in-memory cache. Does not block global app interaction.
@MainActor
final class PersonalHeatmapViewModel: ObservableObject {
    @Published private(set) var loadState: PersonalHeatmapLoadState = .idle
    @Published private(set) var snapshot: PersonalHeatmapSnapshot?
    @Published private(set) var mapAreas: [RouteMapArea] = []
    @Published private(set) var isComputing = false

    @Published var datePreset: PersonalHeatmapDatePreset = .allTime
    @Published var customStartDate: Date
    @Published var customEndDate: Date
    @Published var resolution: PersonalHeatmapResolution = .standard
    @Published var minimumWorkoutCount: Int = 1

    /// Fit-request counter for the map canvas.
    @Published var fitRequest: Int = 0

    private let builder: any PersonalHeatmapBuilding
    private let calendar: Calendar
    private var computeTask: Task<Void, Never>?
    private var cancelFlag: HeatmapCancelFlag?
    private var cache: [PersonalHeatmapRequestKey: PersonalHeatmapSnapshot] = [:]
    private var lastKey: PersonalHeatmapRequestKey?
    /// Tracks whether the published snapshot has already been fitted for this key.
    private var fittedKey: PersonalHeatmapRequestKey?
    /// Injectable clock for relative date filters.
    var nowProvider: () -> Date = { Date() }

    static let minimumRepeatOptions = [1, 2, 3, 5]

    init(
        builder: any PersonalHeatmapBuilding = PersonalHeatmapBuilder(),
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        self.builder = builder
        self.calendar = calendar
        self.customStartDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        self.customEndDate = now
    }

    /// Apply durable filter selections without rebuilding generated map state.
    /// The visible heatmap workspace owns the subsequent refresh.
    func restoreSessionState(_ session: AppSessionHeatmapState) {
        cancel()
        datePreset = PersonalHeatmapDatePreset(rawValue: session.datePresetRaw) ?? .allTime
        if let customStartDate = session.customStartDate {
            self.customStartDate = customStartDate
        }
        if let customEndDate = session.customEndDate {
            self.customEndDate = customEndDate
        }
        resolution = PersonalHeatmapResolution(rawValue: session.resolutionRaw) ?? .standard
        minimumWorkoutCount = Self.minimumRepeatOptions.contains(session.minimumWorkoutCount)
            ? session.minimumWorkoutCount
            : 1
    }

    deinit {
        cancelFlag?.cancel()
        computeTask?.cancel()
    }

    /// Cancel in-flight work when leaving the heatmap workspace.
    func cancel() {
        cancelFlag?.cancel()
        cancelFlag = nil
        computeTask?.cancel()
        computeTask = nil
        isComputing = false
        // Force a fresh fit when the map surface is recreated on re-entry.
        fittedKey = nil
        if loadState == .loading {
            loadState = snapshot == nil ? .idle : .ready
        }
    }

    /// Recompute when the library or filters change.
    func refresh(workouts: [RunWorkout]) {
        let now = nowProvider()
        let key = PersonalHeatmapRequestKey(
            workouts: workouts,
            datePreset: datePreset,
            customStart: datePreset == .custom ? startOfDay(customStartDate) : nil,
            customEnd: datePreset == .custom ? endOfDay(customEndDate) : nil,
            resolution: resolution,
            minimumWorkoutCount: minimumWorkoutCount,
            now: cacheNow(for: datePreset, now: now)
        )

        // A cached result can supersede an expensive detached build just as a
        // cache miss can. Always stop the old request before publishing the
        // cached snapshot, otherwise its cooperative work continues needlessly.
        lastKey = key
        cancelFlag?.cancel()
        computeTask?.cancel()
        cancelFlag = nil
        computeTask = nil

        if let cached = cache[key] {
            apply(snapshot: cached, key: key, requestFit: fittedKey != key)
            return
        }

        // Retain previous snapshot while recomputing when filters change.

        let flag = HeatmapCancelFlag()
        cancelFlag = flag
        isComputing = true
        loadState = .loading

        let configuration = makeConfiguration(now: now)
        let builder = self.builder
        let library = workouts

        computeTask = Task { [weak self] in
            let result: Result<PersonalHeatmapSnapshot, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let snapshot = try builder.build(
                        workouts: library,
                        configuration: configuration,
                        isCancelled: { flag.isCancelled || Task.isCancelled }
                    )
                    return .success(snapshot)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            // Ignore superseded or cancelled requests — do not publish stale work.
            guard self.lastKey == key, !flag.isCancelled, !Task.isCancelled else { return }

            switch result {
            case .success(let snapshot):
                self.cache[key] = snapshot
                // Bound cache size.
                if self.cache.count > 12 {
                    let keep = snapshot
                    self.cache.removeAll(keepingCapacity: true)
                    self.cache[key] = keep
                }
                self.apply(snapshot: snapshot, key: key, requestFit: true)
            case .failure(let error):
                if error is CancellationError {
                    self.isComputing = false
                    if self.snapshot != nil {
                        self.loadState = .ready
                    } else if self.loadState == .loading {
                        self.loadState = .idle
                    }
                    return
                }
                self.isComputing = false
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    func retry(workouts: [RunWorkout]) {
        if let key = lastKey {
            cache.removeValue(forKey: key)
        }
        refresh(workouts: workouts)
    }

    func requestFit() {
        fitRequest += 1
    }

    func resetFilters(workouts: [RunWorkout]) {
        datePreset = .allTime
        resolution = .standard
        minimumWorkoutCount = 1
        refresh(workouts: workouts)
    }

    // MARK: - Private

    private func apply(snapshot: PersonalHeatmapSnapshot, key: PersonalHeatmapRequestKey, requestFit: Bool) {
        self.snapshot = snapshot
        self.mapAreas = RouteMapContent.areas(from: snapshot)
        self.isComputing = false
        self.lastKey = key

        if snapshot.cells.isEmpty {
            if key.workouts.isEmpty || key.workouts.allSatisfy({ $0.pointCount == 0 }) {
                loadState = .empty(.noGPSWorkouts)
            } else if snapshot.statistics.includedWorkoutCount == 0 {
                loadState = .empty(.filterExcludedAll)
            } else {
                loadState = .empty(.noCells)
            }
            fittedKey = key
        } else {
            loadState = .ready
            if requestFit {
                fitRequest += 1
                fittedKey = key
            }
        }
    }

    private func makeConfiguration(now: Date) -> PersonalHeatmapConfiguration {
        let filter: PersonalHeatmapDateFilter
        switch datePreset {
        case .allTime:
            filter = .allTime
        case .last30Days:
            filter = .lastDays(30, now: now, calendar: calendar)
        case .last90Days:
            filter = .lastDays(90, now: now, calendar: calendar)
        case .currentYear:
            filter = .currentCalendarYear(now: now, calendar: calendar)
        case .custom:
            let start = startOfDay(min(customStartDate, customEndDate))
            let end = endOfDay(max(customStartDate, customEndDate))
            filter = .range(start: start, end: end)
        }

        return PersonalHeatmapConfiguration(
            dateFilter: filter,
            cellSizeMeters: resolution.cellSizeMeters,
            minimumWorkoutCount: max(1, minimumWorkoutCount),
            maximumRenderedCellCount: PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount
        )
    }

    private func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    private func endOfDay(_ date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    /// Cache-key clock: relative presets stabilize within the hour. Absolute
    /// modes do not depend on the clock, so they use one stable sentinel.
    private func cacheNow(for preset: PersonalHeatmapDatePreset, now: Date) -> Date {
        switch preset {
        case .allTime, .custom:
            return .distantPast
        case .last30Days, .last90Days, .currentYear:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
            return calendar.date(from: components) ?? Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        }
    }
}
