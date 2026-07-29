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
}
