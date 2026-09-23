// Keep imported C++ declarations confined to the internal Interop layer.
internal import RunPlayEngineCpp

/// Pure-Swift projection of the engine's internal batch ceiling.
///
/// Engine constants reach Swift only through this layer, so tests can assert
/// the ceiling keeps its documented margin over
/// `WorkoutImportResourceLimits.maxRoutePointCount` without importing
/// `RunPlayEngineCpp` outside Interop.
///
/// This is not a product limit and must not be used as one. Swift bounds
/// supported workout size; see `WorkoutImportResourceLimits`.
enum RunPlayEngineLimits {

    /// `runplay::max_route_input_samples`, the engine-side safety ceiling.
    static let maxRouteInputSamples = Int(runplay.max_route_input_samples)

    /// The DEM tile grid the engine accepts. Swift chooses a grid inside these
    /// bounds; the engine rejects anything outside them as an invalid policy.
    static let demZoomRange = 0...Int(runplay.dem_maximum_zoom)
    static let demTileSizeRange =
        Int(runplay.dem_minimum_tile_size)...Int(runplay.dem_maximum_tile_size)
    /// `runplay::dem_maximum_tile_count`, the engine ceiling on distinct tiles
    /// per DEM pass. Swift budgets far lower, by decoded bytes.
    static let demMaximumTileCount = Int(runplay.dem_maximum_tile_count)
}
