// Keep imported C++ declarations confined to the internal Interop layer.
internal import RunPlayEngineCpp
internal import RunPlayEngine

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

    /// Swift engine-side safety ceiling, kept in parity with the retained C++ kernels.
    static let maxRouteInputSamples = EngineRouteLimits.maxRouteInputSamples

    /// The ceiling the retained C++ kernels enforce. Production reads the Swift
    /// value above. `testEngineCeilingKeepsDocumentedMarginOverProductLimit`
    /// asserts the two are equal for as long as a C++ kernel can still run, so
    /// lowering either one alone fails the gate. Removed with the C++ engine.
    static let cppMaxRouteInputSamples = Int(runplay.max_route_input_samples)

    /// The DEM tile grid the engine accepts. Swift chooses a grid inside these
    /// bounds; the engine rejects anything outside them as an invalid policy.
    static let demZoomRange = 0...Int(runplay.dem_maximum_zoom)
    static let demTileSizeRange =
        Int(runplay.dem_minimum_tile_size)...Int(runplay.dem_maximum_tile_size)
    /// `runplay::dem_maximum_tile_count`, the engine ceiling on distinct tiles
    /// per DEM pass. Swift budgets far lower, by decoded bytes.
    static let demMaximumTileCount = Int(runplay.dem_maximum_tile_count)
}
