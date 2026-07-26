import Foundation

/// Pure status precedence for multi-session FIT candidates.
///
/// Kept separate from scan orchestration so the priority order is one scannable
/// unit and can be unit-tested without opening a container.
public enum FITSessionCandidateClassifier: Sendable {

    /// Decide importability for one session, in fixed priority order.
    ///
    /// Precedence (first match wins):
    /// 1. unsupported sport
    /// 2. within-file identity collision
    /// 3. already in library (exact multi-session duplicate)
    /// 4. missing/invalid boundaries
    /// 5. ambiguous time-range overlap
    /// 6. container resource limit
    /// 7. no attributed GPS
    /// 8. otherwise ready (unknown sport may still attach a warning detail)
    public static func classify(
        sport: FITSessionSportClassification,
        sportDisplayName: String,
        isUniqueWithinFile: Bool,
        isExistingInLibrary: Bool,
        boundaryProblem: FITSessionBoundaryProblem?,
        isAmbiguous: Bool,
        overLimit: Bool,
        gpsRecordCount: Int
    ) -> (status: FITSessionCandidateStatus, detail: String?) {
        if sport == .unsupported {
            return (
                .unsupportedSport,
                "\(sportDisplayName) sessions are not supported."
            )
        }
        if !isUniqueWithinFile {
            return (
                .duplicate,
                "Another session in this file produced the same identity."
            )
        }
        if isExistingInLibrary {
            return (
                .duplicate,
                "This session is already in your library."
            )
        }
        if let boundaryProblem {
            return (.invalidBoundaries, boundaryProblem.detail)
        }
        if isAmbiguous {
            return (
                .ambiguousAttribution,
                "This session's time range overlaps another session, so its data cannot be separated reliably."
            )
        }
        if overLimit {
            return (
                .exceedsResourceLimit,
                "This file exceeds the supported record, event, or lap limit."
            )
        }
        if gpsRecordCount == 0 {
            return (
                .noGPSRoute,
                "No GPS records could be attributed to this session."
            )
        }
        if sport == .unknownTreatedAsRunning {
            return (
                .ready,
                "This session has no recognised sport and is being treated as a run."
            )
        }
        return (.ready, nil)
    }
}
