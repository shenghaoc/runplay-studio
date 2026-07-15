import Foundation

// MARK: - Trigger

/// How a source file or device created a recorded lap boundary.
///
/// Unknown FIT codes and unknown TCX trigger text are retained rather than
/// guessed. `unavailable` means the source did not supply a trigger.
public enum RecordedLapTrigger: Hashable, Sendable, Codable {
    case manual
    case distance
    case time
    case position
    case sessionEnd
    case fitnessEquipment
    case unknownFIT(UInt8)
    case unknownTCX(String)
    case unavailable

    public var displayName: String {
        switch self {
        case .manual:
            return NSLocalizedString("Manual", comment: "Recorded lap trigger")
        case .distance:
            return NSLocalizedString("Distance", comment: "Recorded lap trigger")
        case .time:
            return NSLocalizedString("Time", comment: "Recorded lap trigger")
        case .position:
            return NSLocalizedString("Position", comment: "Recorded lap trigger")
        case .sessionEnd:
            return NSLocalizedString("Session end", comment: "Recorded lap trigger")
        case .fitnessEquipment:
            return NSLocalizedString("Fitness equipment", comment: "Recorded lap trigger")
        case .unknownFIT(let code):
            return String(
                format: NSLocalizedString("Unknown (FIT %d)", comment: "Unknown FIT lap trigger"),
                code
            )
        case .unknownTCX(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return NSLocalizedString("Unknown", comment: "Unknown TCX lap trigger")
            }
            return String(
                format: NSLocalizedString("Unknown (%@)", comment: "Unknown TCX lap trigger"),
                trimmed
            )
        case .unavailable:
            return NSLocalizedString("Unavailable", comment: "Missing lap trigger")
        }
    }

    /// Stable export token; never a formula-injection risk by itself.
    public var exportToken: String {
        switch self {
        case .manual: return "manual"
        case .distance: return "distance"
        case .time: return "time"
        case .position: return "position"
        case .sessionEnd: return "session_end"
        case .fitnessEquipment: return "fitness_equipment"
        case .unknownFIT(let code): return "unknown_fit_\(code)"
        case .unknownTCX(let text):
            let sanitized = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return sanitized.isEmpty ? "unknown_tcx" : "unknown_tcx_\(sanitized)"
        case .unavailable: return "unavailable"
        }
    }

    /// Map official FIT Profile `lap_trigger` values. Unknown codes are retained.
    ///
    /// Profile values: 0 manual, 1 time, 2 distance, 3–6 position variants,
    /// 7 session_end, 8 fitness_equipment.
    public static func fromFITLapTrigger(_ raw: UInt8?) -> RecordedLapTrigger {
        guard let raw, raw != FITParser.invalidUint8 else { return .unavailable }
        switch raw {
        case 0: return .manual
        case 1: return .time
        case 2: return .distance
        case 3, 4, 5, 6: return .position
        case 7: return .sessionEnd
        case 8: return .fitnessEquipment
        default: return .unknownFIT(raw)
        }
    }

    /// Map TCX `TriggerMethod` values from the official TCX v2 schema.
    public static func fromTCXTriggerMethod(_ raw: String?) -> RecordedLapTrigger {
        guard let raw else { return .unavailable }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }
        switch trimmed.lowercased() {
        case "manual": return .manual
        case "distance": return .distance
        case "location": return .position
        case "time": return .time
        case "heartrate": return .unknownTCX(trimmed) // not guessed into a core case
        default: return .unknownTCX(trimmed)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, fitCode, tcxText
    }

    private enum Kind: String, Codable {
        case manual, distance, time, position, sessionEnd, fitnessEquipment
        case unknownFIT, unknownTCX, unavailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .manual: self = .manual
        case .distance: self = .distance
        case .time: self = .time
        case .position: self = .position
        case .sessionEnd: self = .sessionEnd
        case .fitnessEquipment: self = .fitnessEquipment
        case .unknownFIT:
            self = .unknownFIT(try container.decode(UInt8.self, forKey: .fitCode))
        case .unknownTCX:
            self = .unknownTCX(try container.decode(String.self, forKey: .tcxText))
        case .unavailable: self = .unavailable
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case .distance:
            try container.encode(Kind.distance, forKey: .kind)
        case .time:
            try container.encode(Kind.time, forKey: .kind)
        case .position:
            try container.encode(Kind.position, forKey: .kind)
        case .sessionEnd:
            try container.encode(Kind.sessionEnd, forKey: .kind)
        case .fitnessEquipment:
            try container.encode(Kind.fitnessEquipment, forKey: .kind)
        case .unknownFIT(let code):
            try container.encode(Kind.unknownFIT, forKey: .kind)
            try container.encode(code, forKey: .fitCode)
        case .unknownTCX(let text):
            try container.encode(Kind.unknownTCX, forKey: .kind)
            try container.encode(text, forKey: .tcxText)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }
}

// MARK: - Source-reported metrics

/// Metrics reported by the source file for a recorded lap.
///
/// These are provenance only. Route-derived canonical metrics on `RecordedLap`
/// remain the cross-format authority and are never silently replaced.
public struct RecordedLapReportedMetrics: Codable, Hashable, Sendable {
    public var elapsedSeconds: Double?
    public var timerSeconds: Double?
    public var distanceMeters: Double?
    public var ascentMeters: Double?
    public var descentMeters: Double?
    public var averageHeartRateBPM: Double?
    public var maximumHeartRateBPM: Double?
    public var averageCadence: Double?
    public var averageSpeedMetersPerSecond: Double?
    public var maximumSpeedMetersPerSecond: Double?
    public var calories: Double?
    public var rawTriggerValue: String?

    public init(
        elapsedSeconds: Double? = nil,
        timerSeconds: Double? = nil,
        distanceMeters: Double? = nil,
        ascentMeters: Double? = nil,
        descentMeters: Double? = nil,
        averageHeartRateBPM: Double? = nil,
        maximumHeartRateBPM: Double? = nil,
        averageCadence: Double? = nil,
        averageSpeedMetersPerSecond: Double? = nil,
        maximumSpeedMetersPerSecond: Double? = nil,
        calories: Double? = nil,
        rawTriggerValue: String? = nil
    ) {
        self.elapsedSeconds = Self.finiteOptional(elapsedSeconds)
        self.timerSeconds = Self.finiteOptional(timerSeconds)
        self.distanceMeters = Self.finiteOptional(distanceMeters)
        self.ascentMeters = Self.finiteOptional(ascentMeters)
        self.descentMeters = Self.finiteOptional(descentMeters)
        self.averageHeartRateBPM = Self.finiteOptional(averageHeartRateBPM)
        self.maximumHeartRateBPM = Self.finiteOptional(maximumHeartRateBPM)
        self.averageCadence = Self.finiteOptional(averageCadence)
        self.averageSpeedMetersPerSecond = Self.finiteOptional(averageSpeedMetersPerSecond)
        self.maximumSpeedMetersPerSecond = Self.finiteOptional(maximumSpeedMetersPerSecond)
        self.calories = Self.finiteOptional(calories)
        if let rawTriggerValue {
            let trimmed = rawTriggerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.rawTriggerValue = trimmed.isEmpty ? nil : trimmed
        } else {
            self.rawTriggerValue = nil
        }
    }

    public var isEmpty: Bool {
        elapsedSeconds == nil
            && timerSeconds == nil
            && distanceMeters == nil
            && ascentMeters == nil
            && descentMeters == nil
            && averageHeartRateBPM == nil
            && maximumHeartRateBPM == nil
            && averageCadence == nil
            && averageSpeedMetersPerSecond == nil
            && maximumSpeedMetersPerSecond == nil
            && calories == nil
            && rawTriggerValue == nil
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

// MARK: - Diagnostics

/// Aggregated recorded-lap diagnostics retained with a workout.
public struct RecordedLapDiagnostics: Codable, Hashable, Sendable {
    public var sourceLapCount: Int
    public var importedLapCount: Int
    public var malformedLapCount: Int
    public var clampedBoundaryCount: Int
    public var timeMismatchCount: Int
    public var distanceMismatchCount: Int
    public var triggersAvailable: Bool
    /// Legacy FIT/TCX snapshots that discarded source lap messages before
    /// recorded-lap preservation. Reimport is required; do not fabricate laps.
    public var requiresReimportForSourceLaps: Bool

    public static let empty = RecordedLapDiagnostics()

    public init(
        sourceLapCount: Int = 0,
        importedLapCount: Int = 0,
        malformedLapCount: Int = 0,
        clampedBoundaryCount: Int = 0,
        timeMismatchCount: Int = 0,
        distanceMismatchCount: Int = 0,
        triggersAvailable: Bool = false,
        requiresReimportForSourceLaps: Bool = false
    ) {
        self.sourceLapCount = max(0, sourceLapCount)
        self.importedLapCount = max(0, importedLapCount)
        self.malformedLapCount = max(0, malformedLapCount)
        self.clampedBoundaryCount = max(0, clampedBoundaryCount)
        self.timeMismatchCount = max(0, timeMismatchCount)
        self.distanceMismatchCount = max(0, distanceMismatchCount)
        self.triggersAvailable = triggersAvailable
        self.requiresReimportForSourceLaps = requiresReimportForSourceLaps
    }
}

// MARK: - Recorded lap

/// A boundary and optional summary explicitly present in the imported source.
///
/// Distinct from calculated kilometre `RunSplit` values and from route segments.
public struct RecordedLap: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var lapIndex: Int
    public var source: WorkoutSource
    public var trigger: RecordedLapTrigger

    public var sourceStartDate: Date?
    public var sourceEndDate: Date?

    public var startElapsedSeconds: Double
    public var endElapsedSeconds: Double
    public var startDistanceMeters: Double
    public var endDistanceMeters: Double

    public var distanceMeters: Double

    public var elapsedSeconds: Double
    public var activeSeconds: Double
    public var movingSeconds: Double
    public var stoppedSeconds: Double
    public var pausedSeconds: Double

    public var activePaceSecondsPerKilometer: Double
    public var movingPaceSecondsPerKilometer: Double
    public var elapsedPaceSecondsPerKilometer: Double

    public var averageHeartRateBPM: Double?
    public var maximumHeartRateBPM: Double?
    public var averageCadence: Double?

    public var elevationGainMeters: Double?
    public var elevationLossMeters: Double?

    public var reportedMetrics: RecordedLapReportedMetrics?

    public init(
        id: UUID = UUID(),
        lapIndex: Int,
        source: WorkoutSource = .unknown,
        trigger: RecordedLapTrigger = .unavailable,
        sourceStartDate: Date? = nil,
        sourceEndDate: Date? = nil,
        startElapsedSeconds: Double = 0,
        endElapsedSeconds: Double = 0,
        startDistanceMeters: Double = 0,
        endDistanceMeters: Double = 0,
        distanceMeters: Double = 0,
        elapsedSeconds: Double = 0,
        activeSeconds: Double = 0,
        movingSeconds: Double = 0,
        stoppedSeconds: Double = 0,
        pausedSeconds: Double = 0,
        activePaceSecondsPerKilometer: Double = 0,
        movingPaceSecondsPerKilometer: Double = 0,
        elapsedPaceSecondsPerKilometer: Double = 0,
        averageHeartRateBPM: Double? = nil,
        maximumHeartRateBPM: Double? = nil,
        averageCadence: Double? = nil,
        elevationGainMeters: Double? = nil,
        elevationLossMeters: Double? = nil,
        reportedMetrics: RecordedLapReportedMetrics? = nil
    ) {
        self.id = id
        self.lapIndex = max(0, lapIndex)
        self.source = source
        self.trigger = trigger
        self.sourceStartDate = sourceStartDate
        self.sourceEndDate = sourceEndDate

        let safeStartElapsed = Self.nonNegativeFinite(startElapsedSeconds)
        let safeEndElapsed = max(safeStartElapsed, Self.nonNegativeFinite(endElapsedSeconds))
        self.startElapsedSeconds = safeStartElapsed
        self.endElapsedSeconds = safeEndElapsed

        let safeStartDistance = Self.nonNegativeFinite(startDistanceMeters)
        let safeEndDistance = max(safeStartDistance, Self.nonNegativeFinite(endDistanceMeters))
        self.startDistanceMeters = safeStartDistance
        self.endDistanceMeters = safeEndDistance

        let derivedDistance = max(0, safeEndDistance - safeStartDistance)
        let safeDistance = Self.nonNegativeFinite(distanceMeters)
        self.distanceMeters = safeDistance > 0 ? safeDistance : derivedDistance

        let safeElapsed = Self.nonNegativeFinite(elapsedSeconds > 0 ? elapsedSeconds : safeEndElapsed - safeStartElapsed)
        let safeActive = min(Self.nonNegativeFinite(activeSeconds), safeElapsed)
        let safeMoving = min(Self.nonNegativeFinite(movingSeconds), safeActive)
        self.elapsedSeconds = safeElapsed
        self.activeSeconds = safeActive
        self.movingSeconds = safeMoving
        // Derived invariants win over inconsistent input.
        self.stoppedSeconds = max(0, safeActive - safeMoving)
        self.pausedSeconds = max(0, safeElapsed - safeActive)
        _ = stoppedSeconds
        _ = pausedSeconds

        let derivedActivePace = Self.pace(seconds: safeActive, distanceMeters: self.distanceMeters)
        let derivedMovingPace = Self.pace(seconds: safeMoving, distanceMeters: self.distanceMeters)
        let derivedElapsedPace = Self.pace(seconds: safeElapsed, distanceMeters: self.distanceMeters)
        self.activePaceSecondsPerKilometer = Self.nonNegativeFinite(
            activePaceSecondsPerKilometer > 0 ? activePaceSecondsPerKilometer : derivedActivePace
        )
        self.movingPaceSecondsPerKilometer = Self.nonNegativeFinite(
            movingPaceSecondsPerKilometer > 0 ? movingPaceSecondsPerKilometer : derivedMovingPace
        )
        self.elapsedPaceSecondsPerKilometer = Self.nonNegativeFinite(
            elapsedPaceSecondsPerKilometer > 0 ? elapsedPaceSecondsPerKilometer : derivedElapsedPace
        )

        self.averageHeartRateBPM = Self.finiteOptional(averageHeartRateBPM)
        self.maximumHeartRateBPM = Self.finiteOptional(maximumHeartRateBPM)
        self.averageCadence = Self.finiteOptional(averageCadence)
        self.elevationGainMeters = Self.finiteOptional(elevationGainMeters)
        self.elevationLossMeters = Self.finiteOptional(elevationLossMeters)
        self.reportedMetrics = reportedMetrics.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Provisional source-only lap used before route-derived analysis.
    public static func provisional(
        id: UUID = UUID(),
        lapIndex: Int,
        source: WorkoutSource,
        trigger: RecordedLapTrigger,
        sourceStartDate: Date?,
        sourceEndDate: Date?,
        reportedMetrics: RecordedLapReportedMetrics?
    ) -> RecordedLap {
        RecordedLap(
            id: id,
            lapIndex: lapIndex,
            source: source,
            trigger: trigger,
            sourceStartDate: sourceStartDate,
            sourceEndDate: sourceEndDate,
            reportedMetrics: reportedMetrics
        )
    }

    public var formattedElapsed: String {
        DisplayFormatter.formatElapsed(elapsedSeconds)
    }

    public var formattedActive: String {
        DisplayFormatter.formatElapsed(activeSeconds)
    }

    public var formattedMoving: String {
        DisplayFormatter.formatElapsed(movingSeconds)
    }

    public var formattedStopped: String {
        DisplayFormatter.formatElapsed(stoppedSeconds)
    }

    public var formattedActivePace: String {
        DisplayFormatter.formatPaceShort(activePaceSecondsPerKilometer)
    }

    public var formattedMovingPace: String {
        DisplayFormatter.formatPaceShort(movingPaceSecondsPerKilometer)
    }

    public var formattedElapsedPace: String {
        DisplayFormatter.formatPaceShort(elapsedPaceSecondsPerKilometer)
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func pace(seconds: Double, distanceMeters: Double) -> Double {
        guard seconds.isFinite, seconds > 0, distanceMeters.isFinite, distanceMeters > 0 else {
            return 0
        }
        return (seconds / distanceMeters) * 1000
    }
}
