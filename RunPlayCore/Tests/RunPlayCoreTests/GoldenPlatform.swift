#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The platform that this test process runs on, read at run time from
/// `uname(2)`.
///
/// Each golden digest is selected by a compile-time platform condition. A
/// misspelled condition compiles and never matches: `arch(aarch64)` is one,
/// because Swift spells 64-bit ARM `arch(arm64)` on every platform, Linux
/// included. The selection then falls through to `nil`, and the golden test
/// is disabled without a failure. The guard tests compare each golden with
/// this run-time value, so they do not share the condition that they check.
enum GoldenPlatform: Equatable, CustomStringConvertible {
    case macOSArm64
    case linuxX86_64
    case linuxArm64
    case other(system: String, machine: String)

    static let current: GoldenPlatform = {
        var name = utsname()
        guard uname(&name) == 0 else { return .other(system: "unknown", machine: "unknown") }
        let system = field(&name.sysname)
        let machine = field(&name.machine)
        switch (system, machine) {
        case ("Darwin", "arm64"): return .macOSArm64
        case ("Linux", "x86_64"): return .linuxX86_64
        case ("Linux", "aarch64"), ("Linux", "arm64"): return .linuxArm64
        default: return .other(system: system, machine: machine)
        }
    }()

    /// True on the platforms for which every kernel `*GoldenTests.swift`
    /// pins a digest: the macOS arm64 and Linux x86_64 CI platforms.
    var pinsKernelGoldens: Bool {
        self == .macOSArm64 || self == .linuxX86_64
    }

    var description: String {
        switch self {
        case .macOSArm64: "macOS arm64"
        case .linuxX86_64: "Linux x86_64"
        case .linuxArm64: "Linux arm64"
        case let .other(system, machine): "\(system) \(machine)"
        }
    }

    /// The failure text for a digest that is `nil` on a platform that pins it.
    static func unpinnedMessage(_ golden: String) -> String {
        "\(golden) is nil on \(current), which pins it: its platform condition does not match this platform"
    }

    private static func field<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
