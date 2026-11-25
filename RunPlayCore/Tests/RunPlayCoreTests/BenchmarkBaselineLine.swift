import Foundation

/// The stable output line of an engine benchmark case.
///
/// Each engine benchmark is an absolute Swift baseline: it prints one line per
/// case and no ratio, because there is no reference implementation to compare
/// against. The shape is
///
///     <Benchmark> <case> <count>=<value> ... iterations=<n> swift_ms=<median> [swift_max_ms=<maximum>]
///
/// so `grep '^<Benchmark> '` selects one benchmark's lines from a test log.
/// Case names and count keys contain no spaces. Times are in milliseconds
/// with three decimals; `swift_max_ms` appears only for a case that reports
/// its slowest measured iteration.
enum BenchmarkBaselineLine {
    static func make(
        _ benchmark: String,
        _ caseName: String,
        counts: KeyValuePairs<String, Int> = [:],
        iterations: Int,
        medianMilliseconds: Double,
        maximumMilliseconds: Double? = nil
    ) -> String {
        var fields = [benchmark, caseName]
        for (key, value) in counts {
            fields.append("\(key)=\(value)")
        }
        fields.append("iterations=\(iterations)")
        fields.append("swift_ms=\(String(format: "%.3f", medianMilliseconds))")
        if let maximumMilliseconds {
            fields.append("swift_max_ms=\(String(format: "%.3f", maximumMilliseconds))")
        }
        return fields.joined(separator: " ")
    }

    /// The resident-memory line that accompanies a benchmark's timing lines.
    static func memory(_ benchmark: String, _ label: String, bytes: UInt64?) -> String {
        "\(benchmark) \(label) bytes=\(bytes.map { String($0) } ?? "unavailable")"
    }
}
