import Foundation

/// Monotonic nanosecond accounting shared by opt-in Core profiling paths.
///
/// Uses `ContinuousClock` so `RunPlayCore` stays on the Swift standard library
/// and remains valid on Linux. Production entry points never call this unless
/// a test-only `collectProfile` / profiled path is active.
enum HotspotProfileClock {
    @inline(__always)
    static func nanoseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> UInt64 {
        let components = start.duration(to: end).components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return nanoseconds > 0 ? UInt64(nanoseconds) : 0
    }

    @inline(__always)
    static func measureNanoseconds(_ body: () throws -> Void) rethrows -> UInt64 {
        let start = ContinuousClock.now
        try body()
        return nanoseconds(from: start, to: ContinuousClock.now)
    }

    @inline(__always)
    static func measureNanoseconds<T>(_ body: () throws -> T) rethrows -> (T, UInt64) {
        let start = ContinuousClock.now
        let value = try body()
        return (value, nanoseconds(from: start, to: ContinuousClock.now))
    }
}
