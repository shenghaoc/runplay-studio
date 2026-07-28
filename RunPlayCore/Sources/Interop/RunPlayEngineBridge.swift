// Keep C++ declarations out of RunPlayCore's public Swift API.
// Current SwiftPM constraints still require transitive Swift targets to
// compile with C++ interoperability enabled.
internal import RunPlayEngineCpp

/// Swift projection of the portable C++ engine identity smoke API.
///
/// C++ types from `RunPlayEngineCpp` must not appear in any public
/// `RunPlayCore` signature. This value is pure Swift and `Sendable`.
struct RunPlayEngineInfo: Equatable, Sendable {
    let abiVersion: UInt32
    let languageStandard: String
}

/// Internal adapter that calls into `RunPlayEngineCpp` and converts results
/// to ordinary Swift values. Production app code must not call this yet;
/// integration is proven through tests only.
enum RunPlayEngineBridge {
    /// Returns deterministic engine identity from the C++ smoke API.
    static func engineInfo() -> RunPlayEngineInfo {
        let info = runplay.engine_info()
        let languageStandard = switch info.language_standard {
        case .cpp23:
            "C++23"
        default:
            "Unknown"
        }
        return RunPlayEngineInfo(
            abiVersion: info.abi_version,
            languageStandard: languageStandard
        )
    }
}
