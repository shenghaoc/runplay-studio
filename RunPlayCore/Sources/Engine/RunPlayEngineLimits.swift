internal import RunPlayEngine

/// Pure-Swift projection of the engine's internal batch ceiling.
///
/// Engine constants reach the rest of Core only through this type, so tests
/// can assert the ceiling keeps its documented margin over
/// `WorkoutImportResourceLimits.maxRoutePointCount` without importing
/// `RunPlayEngine` outside the engine adapters.
///
/// This is not a product limit and must not be used as one. Swift bounds
/// supported workout size; see `WorkoutImportResourceLimits`.
enum RunPlayEngineLimits {

    /// Engine-side safety ceiling on route input samples.
    static let maxRouteInputSamples = EngineRouteLimits.maxRouteInputSamples

    /// The DEM tile grid the engine accepts. Swift chooses a grid inside these
    /// bounds; the engine rejects anything outside them as an invalid policy.
    static let demZoomRange = 0...EngineDemLimits.maximumZoom
    static let demTileSizeRange =
        EngineDemLimits.minimumTileSize...EngineDemLimits.maximumTileSize
    /// `EngineDemLimits.maximumTileCount`, the engine ceiling on distinct tiles
    /// per DEM pass. Swift budgets far lower, by decoded bytes.
    static let demMaximumTileCount = EngineDemLimits.maximumTileCount
}
