import Foundation
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
        guard let record else { return studioLocalized("Elevation not corrected") }
        switch record.outcome {
        case .applied:
            guard let fraction = record.coverage.tileCoverageFraction else {
                return studioLocalized("DEM elevation")
            }
            let coverage = ElevationSourceSummary.percent(fraction)
            return studioLocalized("DEM tiles cover \(coverage)")
        case .noCoverage:
            return studioLocalized("No DEM tile covers this run")
        case .tileBudgetExceeded:
            return studioLocalized("Needs too many DEM tiles")
        case .optedOut:
            return nil
        }
    }
}
