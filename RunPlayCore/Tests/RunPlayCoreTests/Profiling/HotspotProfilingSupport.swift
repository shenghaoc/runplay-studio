import XCTest
import Foundation
@testable import RunPlayCore

// MARK: - Timing statistics

struct TimingStatistics: Equatable, Sendable {
    let medianMilliseconds: Double
    let p90Milliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double
    let sampleCount: Int

    static let zero = TimingStatistics(
        medianMilliseconds: 0,
        p90Milliseconds: 0,
        minimumMilliseconds: 0,
        maximumMilliseconds: 0,
        sampleCount: 0
    )
}

struct ProfileAccounting: Equatable, Sendable {
    let wallMilliseconds: Double
    let measuredPhaseMilliseconds: Double
    let unaccountedMilliseconds: Double
    let unaccountedFraction: Double

    var isValid: Bool { abs(unaccountedFraction) <= 0.05 }

    static func make(wallMs: Double, measuredMs: Double) -> ProfileAccounting {
        let unaccounted = wallMs - measuredMs
        let fraction = wallMs > 0 ? unaccounted / wallMs : 0
        return ProfileAccounting(
            wallMilliseconds: wallMs,
            measuredPhaseMilliseconds: measuredMs,
            unaccountedMilliseconds: unaccounted,
            unaccountedFraction: fraction
        )
    }
}

enum ProfileFixtureSize: String, Sendable {
    case standard
    case large
    case productLimit

    var warmups: Int {
        switch self {
        case .standard: return 5
        case .large: return 2
        case .productLimit: return 1
        }
    }

    var iterations: Int {
        switch self {
        case .standard: return 20
        case .large: return 5
        case .productLimit: return 3
        }
    }
}

// MARK: - Clock helpers

enum HotspotTestClock {
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
    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        return ms(nanoseconds(from: start, to: ContinuousClock.now))
    }

    @inline(__always)
    static func ms(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    static func statistics(from samplesMs: [Double]) -> TimingStatistics {
        guard !samplesMs.isEmpty else { return .zero }
        let sorted = samplesMs.sorted()
        return TimingStatistics(
            medianMilliseconds: percentile(sorted, 0.50),
            p90Milliseconds: percentile(sorted, 0.90),
            minimumMilliseconds: sorted.first ?? 0,
            maximumMilliseconds: sorted.last ?? 0,
            sampleCount: sorted.count
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}

// MARK: - Measurement

/// Warm-up then measure. Fixture generation must happen outside `operation`.
func measureStatistics(
    size: ProfileFixtureSize,
    operation: () throws -> Void
) rethrows -> TimingStatistics {
    let total = size.warmups + size.iterations
    var samples: [Double] = []
    samples.reserveCapacity(size.iterations)
    for iteration in 0..<total {
        let elapsed = try HotspotTestClock.milliseconds(operation)
        if iteration >= size.warmups {
            samples.append(elapsed)
        }
    }
    return HotspotTestClock.statistics(from: samples)
}

func measureStatisticsWithResult<T>(
    size: ProfileFixtureSize,
    operation: () throws -> T
) rethrows -> (stats: TimingStatistics, last: T) {
    let total = size.warmups + size.iterations
    var samples: [Double] = []
    samples.reserveCapacity(size.iterations)
    var last: T?
    for iteration in 0..<total {
        let start = ContinuousClock.now
        let value = try operation()
        let elapsed = HotspotTestClock.ms(
            HotspotTestClock.nanoseconds(from: start, to: ContinuousClock.now)
        )
        if iteration >= size.warmups {
            samples.append(elapsed)
            last = value
        } else {
            last = value
        }
    }
    return (HotspotTestClock.statistics(from: samples), last!)
}

// MARK: - Memory

struct ProcessMemorySnapshot: Sendable {
    let residentBytes: UInt64
    /// Process high-water resident size when available (Darwin). Process-wide,
    /// not a per-operation peak unless sampled during the operation.
    let highWaterResidentBytes: UInt64
}

#if canImport(Darwin)
import Darwin

func processMemorySnapshot() -> ProcessMemorySnapshot {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) { p in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), p, &count)
        }
    }
    guard kr == KERN_SUCCESS else {
        return ProcessMemorySnapshot(residentBytes: 0, highWaterResidentBytes: 0)
    }
    // `resident_size_max` is process high-water since launch (Mach).
    return ProcessMemorySnapshot(
        residentBytes: info.resident_size,
        highWaterResidentBytes: info.resident_size_max
    )
}
#else
func processMemorySnapshot() -> ProcessMemorySnapshot {
    ProcessMemorySnapshot(residentBytes: 0, highWaterResidentBytes: 0)
}
#endif

// MARK: - Family filter / invocation counters

enum ProfileFamily: String, CaseIterable {
    case analysis
    case alignment
    case metrics
    case importFamily = "import"
    case comparison

    static var selected: Set<ProfileFamily> {
        let raw = ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_FAMILY"] ?? "all"
        if raw == "all" { return Set(allCases) }
        if let one = ProfileFamily(rawValue: raw) { return [one] }
        return Set(allCases)
    }
}

/// Deterministic counters proving each family executes at most once per process.
enum ProfileFamilyInvocationCounter {
    private static let lock = NSLock()
    // Protected by `lock`; XCTest may invoke methods concurrently.
    nonisolated(unsafe) private static var counts: [ProfileFamily: Int] = [:]

    static func record(_ family: ProfileFamily) {
        lock.lock()
        defer { lock.unlock() }
        counts[family, default: 0] += 1
    }

    static func count(for family: ProfileFamily) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[family, default: 0]
    }

    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
    }
}

var profileProductLimitEnabled: Bool {
    ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_PRODUCT_LIMIT"] == "1"
}

var profileMemoryEnabled: Bool {
    ProcessInfo.processInfo.environment["RUNPLAY_PROFILE_MEMORY"] == "1"
}

var profileEnabled: Bool {
    ProcessInfo.processInfo.environment["RUNPLAY_CORE_HOTSPOT_PROFILE"] == "1"
}

// MARK: - Formatting

func formatMs(_ value: Double) -> String {
    String(format: "%.2f", value)
}

func formatPct(_ part: Double, of whole: Double) -> String {
    guard whole > 0 else { return "0.0" }
    return String(format: "%.1f", part / whole * 100)
}

func formatStats(_ stats: TimingStatistics) -> String {
    "med \(formatMs(stats.medianMilliseconds)) / p90 \(formatMs(stats.p90Milliseconds)) / min \(formatMs(stats.minimumMilliseconds)) / max \(formatMs(stats.maximumMilliseconds))"
}
