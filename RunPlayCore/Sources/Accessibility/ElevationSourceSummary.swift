import Foundation

/// What a workout's elevation is analysed from, in the words the elevation
/// chart's descriptor, its source note, and VoiceOver share.
public struct ElevationSourceSummary: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// No point has an analysed altitude.
        case none
        /// Recorded altitude at every analysed point.
        case recorded
        /// DEM elevation at every analysed point.
        case dem
        /// DEM elevation where tiles covered the route, recorded altitude
        /// elsewhere.
        case demAndRecorded
    }

    public let source: Source
    public let recordedAltitudeSensor: RecordedAltitudeSensor
    /// The workout's last DEM correction; `nil` when never corrected.
    public let correction: DEMElevationCorrection?

    public init(
        source: Source,
        recordedAltitudeSensor: RecordedAltitudeSensor,
        correction: DEMElevationCorrection?
    ) {
        self.source = source
        self.recordedAltitudeSensor = recordedAltitudeSensor
        self.correction = correction
    }

    /// Summarises `workout`, whose elevation profile reported `sourceCounts`.
    public init(workout: RunWorkout, sourceCounts: ElevationSourceCounts) {
        let source: Source = switch (sourceCounts.demPointCount > 0, sourceCounts.recordedPointCount > 0) {
        case (false, false): .none
        case (false, true): .recorded
        case (true, false): .dem
        case (true, true): .demAndRecorded
        }
        self.init(
            source: source,
            recordedAltitudeSensor: workout.recordedAltitudeSensor,
            correction: workout.demElevationCorrection
        )
    }

    /// The source in a few words, for the elevation chart's descriptor.
    public var label: String {
        let barometric = recordedAltitudeSensor == .barometric
        switch source {
        case .none:
            return coreLocalized("No elevation data")
        case .recorded:
            return barometric
                ? coreLocalized("Barometric altimeter")
                : coreLocalized("Recorded altitude (sensor unknown)")
        case .dem:
            return coreLocalized("DEM tiles")
        case .demAndRecorded:
            return barometric
                ? coreLocalized("Barometric altimeter and DEM tiles")
                : coreLocalized("DEM tiles and recorded altitude")
        }
    }

    /// Plain sentences on how the elevation was corrected, the most important
    /// first; empty for a workout that was never corrected.
    public var notes: [String] {
        guard let correction else { return [] }
        let coverage = correction.coverage
        switch correction.outcome {
        case .optedOut:
            return [coreLocalized("DEM correction is off for this workout because Use Recorded Elevation is chosen.")]
        case .noCoverage:
            return [coreLocalized("Not corrected: no DEM tile in the folder covers this route.")]
        case .tileBudgetExceeded(let minimumRequiredTileCount, let tileBudget):
            return [
                coreLocalized("""
                    Not corrected: this route needs at least \(minimumRequiredTileCount) DEM tiles, \
                    more than the \(tileBudget) one correction may read. \
                    Tiles at a lower zoom cover more ground each.
                    """)
            ]
        case .applied:
            var notes: [String] = []
            if coverage.replacedRecordedPointCount > 0 {
                let replaced = Self.percent(coverage.replacedRecordedPointCount, of: coverage.pointCount)
                notes.append(coreLocalized("""
                    DEM tiles replaced the recorded altitude at \(replaced) of points. \
                    This file does not say which sensor recorded that altitude; if it was a \
                    barometric altimeter, choose Use Recorded Elevation to keep it.
                    """))
            }
            if coverage.keptBarometricPointCount > 0 {
                notes.append(coreLocalized("The recorded barometric altitude is kept wherever it exists."))
            }
            if coverage.filledMissingPointCount > 0 {
                notes.append(coreLocalized(
                    "DEM tiles filled \(coverage.filledMissingPointCount) points that had no recorded altitude."
                ))
            }
            if let fraction = coverage.tileCoverageFraction, fraction < 1 {
                let covered = Self.percent(fraction)
                if coverage.missingTileCount > 0 {
                    notes.append(coreLocalized("""
                        DEM tiles covered \(covered) of the route; \
                        \(coverage.missingTileCount) tiles are missing from the folder.
                        """))
                } else {
                    notes.append(coreLocalized("DEM tiles covered \(covered) of the route."))
                }
            }
            if coverage.unreadableTileCount > 0 {
                notes.append(coreLocalized("\(coverage.unreadableTileCount) tiles could not be read."))
            }
            return notes
        }
    }

    /// The label and every note, for VoiceOver.
    public var spokenSummary: String {
        ([coreLocalized("Elevation source: \(label).")] + notes).joined(separator: " ")
    }

    // MARK: - Formatting

    /// A whole percentage rounded down, so partial coverage never reads as
    /// 100%, and any share above zero never reads as 0%.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        let whole = Int((min(fraction, 1) * 100).rounded(.down))
        // "1%" is a formatted number, interpolated rather than part of the key.
        let onePercent = "1%"
        return whole == 0 ? coreLocalized("less than \(onePercent)") : "\(whole)%"
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? percent(Double(part) / Double(whole)) : "0%"
    }
}

extension DEMElevationCorrection {
    /// One sentence on what an import's DEM correction did, for the import
    /// summary.
    public func importSummary(recordedAltitudeSensor: RecordedAltitudeSensor) -> String {
        switch outcome {
        case .optedOut:
            return coreLocalized("Recorded elevation kept.")
        case .noCoverage:
            return coreLocalized("Elevation not corrected: no DEM tile covers this route.")
        case .tileBudgetExceeded:
            return coreLocalized("Elevation not corrected: the route needs more DEM tiles than one correction may read.")
        case .applied:
            let covered = coverage.tileCoverageFraction.map(ElevationSourceSummary.percent) ?? "0%"
            if recordedAltitudeSensor == .barometric {
                return coverage.filledMissingPointCount > 0
                    ? coreLocalized(
                        "Barometric elevation kept; DEM tiles filled \(coverage.filledMissingPointCount) points without it."
                    )
                    : coreLocalized("Barometric elevation kept.")
            }
            if coverage.replacedRecordedPointCount > 0 {
                return coreLocalized("""
                    Elevation corrected from DEM tiles covering \(covered) of the route, \
                    replacing recorded altitude from an unstated sensor.
                    """)
            }
            return coreLocalized("Elevation corrected from DEM tiles covering \(covered) of the route.")
        }
    }

    /// One sentence totalling a batch import's DEM corrections, or `nil`
    /// when no workout was corrected. A `nil` record is a correction that
    /// could not finish.
    public static func batchImportSummary(_ records: [DEMElevationCorrection?]) -> String? {
        guard !records.isEmpty else { return nil }
        var corrected = 0
        var uncovered = 0
        var overBudget = 0
        var failed = 0
        for record in records {
            switch record?.outcome {
            case .applied?: corrected += 1
            case .noCoverage?: uncovered += 1
            case .tileBudgetExceeded?: overBudget += 1
            case .optedOut?: break
            case nil: failed += 1
            }
        }
        var parts: [String] = []
        if corrected > 0 { parts.append(coreLocalized("\(corrected) corrected")) }
        if uncovered > 0 { parts.append(coreLocalized("\(uncovered) outside the tiles")) }
        if overBudget > 0 { parts.append(coreLocalized("\(overBudget) needing more tiles than one correction may read")) }
        if failed > 0 { parts.append(coreLocalized("\(failed) not corrected after an error")) }
        guard !parts.isEmpty else { return nil }
        let outcomes = parts.joined(separator: ", ")
        return coreLocalized("DEM elevation for \(records.count) runs: \(outcomes).")
    }
}
