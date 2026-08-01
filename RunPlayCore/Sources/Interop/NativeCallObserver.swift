import Foundation

/// The native engine boundaries whose call cardinality is asserted by tests.
///
/// This is a plain type with no storage, so naming it costs nothing in release
/// builds; only the DEBUG-gated tally below holds state.
enum NativeCallBoundary: Sendable {
    case routeQuality
    case elevationProfile
    case segmentDetection
    case routeAlignmentDtw
    case personalHeatmapCoverage
    case routeMetricScaleBucket
}

/// Test-only observation of native C++ engine invocations.
///
/// `RunPlayEngineCpp` must be entered exactly once per production operation
/// (see `docs/cpp-engine-boundary-inventory.md`). Proving that requires counting
/// real calls, but the count must not become part of production behaviour.
///
/// Two properties matter here:
///
/// 1. **Release builds carry nothing.** The tally, the lock, and the task-local
///    are all `#if DEBUG`. In release `record(_:)` has an empty body and
///    optimizes away, so a normal native call does no locking and touches no
///    shared mutable state.
/// 2. **Observation is scoped, not process-wide.** The tally is bound to a
///    task-local for the duration of `observing(_:)`, so a measuring test sees
///    only the calls made inside its own scope. A process-wide counter that
///    tests reset before asserting has a real race: another test can invoke the
///    same bridge between the reset and the assertion. A scoped binding cannot
///    observe work it did not enclose.
///
/// Scoping is inherited the way task-locals are: synchronous work and child
/// tasks see the binding, but raw GCD worker threads (`DispatchQueue
/// .concurrentPerform`, `async` onto a queue) do not. Every measured path is
/// synchronous today. If one is later parallelized with GCD, its calls would go
/// uncounted and the affected assertion would fail rather than silently pass —
/// a visible failure, but the fix is to propagate the tally explicitly, not to
/// relax the assertion.
enum NativeCallObserver {
    /// Record one native invocation. A no-op unless a scope is active.
    @inline(__always)
    static func record(_ boundary: NativeCallBoundary) {
        #if DEBUG
        tally?.record(boundary)
        #endif
    }

    #if DEBUG
    /// Per-boundary native invocation counts observed in one scope.
    struct Counts: Sendable, Equatable {
        var routeQuality = 0
        var elevationProfile = 0
        var segmentDetection = 0
        var routeAlignmentDtw = 0
        var personalHeatmapCoverage = 0
        var routeMetricScaleBucket = 0

        subscript(boundary: NativeCallBoundary) -> Int {
            switch boundary {
            case .routeQuality: return routeQuality
            case .elevationProfile: return elevationProfile
            case .segmentDetection: return segmentDetection
            case .routeAlignmentDtw: return routeAlignmentDtw
            case .personalHeatmapCoverage: return personalHeatmapCoverage
            case .routeMetricScaleBucket: return routeMetricScaleBucket
            }
        }
    }

    /// Mutable tally shared with any child task spawned inside a scope.
    ///
    /// Locked because a single observed operation may fan out across threads;
    /// the lock exists only in DEBUG and only inside an active scope.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = Counts()

        func record(_ boundary: NativeCallBoundary) {
            lock.lock()
            defer { lock.unlock() }
            switch boundary {
            case .routeQuality: counts.routeQuality += 1
            case .elevationProfile: counts.elevationProfile += 1
            case .segmentDetection: counts.segmentDetection += 1
            case .routeAlignmentDtw: counts.routeAlignmentDtw += 1
            case .personalHeatmapCoverage: counts.personalHeatmapCoverage += 1
            case .routeMetricScaleBucket: counts.routeMetricScaleBucket += 1
            }
        }

        var snapshot: Counts {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }
    }

    @TaskLocal private static var tally: Tally?

    /// Run `body` with a fresh tally and return both its result and the native
    /// calls made inside it.
    static func observing<T>(_ body: () throws -> T) rethrows -> (result: T, counts: Counts) {
        let tally = Tally()
        let result = try NativeCallObserver.$tally.withValue(tally) {
            try body()
        }
        return (result, tally.snapshot)
    }
    #endif
}
