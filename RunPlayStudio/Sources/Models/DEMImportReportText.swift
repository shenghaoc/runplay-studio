import RunPlayCore

/// Import-report wording for DEM elevation correction, shared by the archive
/// and multi-session FIT reports.
enum DEMImportReportText {
    /// The report's elevation line; `nil` when the import did not correct
    /// elevation, saved nothing, or imported no run.
    static func summary(
        records: [DEMElevationCorrection?],
        correctsElevation: Bool,
        commitFailed: Bool
    ) -> String? {
        guard correctsElevation, !commitFailed else { return nil }
        return DEMElevationCorrection.batchImportSummary(records)
    }

    /// A few words on one imported run's elevation, for the details list.
    static func itemDetail(_ record: DEMElevationCorrection?, correctsElevation: Bool) -> String? {
        guard correctsElevation else { return nil }
        guard let record else { return "Elevation not corrected" }
        switch record.outcome {
        case .applied:
            guard let fraction = record.coverage.tileCoverageFraction else { return "DEM elevation" }
            return "DEM tiles cover \(ElevationSourceSummary.percent(fraction))"
        case .noCoverage:
            return "No DEM tile covers this run"
        case .tileBudgetExceeded:
            return "Needs too many DEM tiles"
        case .optedOut:
            return nil
        }
    }
}
