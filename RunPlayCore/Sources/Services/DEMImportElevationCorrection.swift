import Foundation

/// Corrects a newly imported workout's elevation before it is saved: the
/// "Correct new imports" setting, once a tile folder is chosen.
///
/// A correction never fails an import. When it cannot finish, the workout is
/// saved exactly as imported and without a correction record, so a later
/// library pass picks it up.
public struct DEMImportElevationCorrection: Sendable {
    public let source: any DEMTileSource
    public let corrector: DEMElevationCorrector

    public init(source: any DEMTileSource, corrector: DEMElevationCorrector = DEMElevationCorrector()) {
        self.source = source
        self.corrector = corrector
    }

    /// Corrects `workout` in place and returns the record written, or `nil`
    /// when the correction failed. Throws only `CancellationError`, because a
    /// cancelled import stops as a whole.
    @discardableResult
    public func apply(
        to workout: inout RunWorkout,
        isCancelled: @escaping @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws -> DEMElevationCorrection? {
        do {
            return try corrector.correct(&workout, using: source, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
