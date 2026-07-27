// swift-tools-version:6.3
import PackageDescription

/// Strict but maintainable warning set for the portable C++ engine.
/// Typed SPM settings do not yet express these group flags, so they are
/// applied as target-scoped cxxSettings only (never to Swift targets).
let engineCppWarningFlags: [String] = [
    "-Wall",
    "-Wextra",
    "-Wpedantic",
    "-Wconversion",
    "-Wsign-conversion",
    "-Wshadow",
]

let engineCppSettings: [CXXSetting] = [
    .unsafeFlags(engineCppWarningFlags),
    .treatAllWarnings(as: .error),
]

/// SwiftPM propagates C++ target module maps to every transitive dependent.
/// Any Swift target that links `RunPlayCore` (and therefore `RunPlayEngineCpp`)
/// must enable C++ interoperability so the clang importer can parse C++
/// standard headers. Platform/Studio still must not `import RunPlayEngineCpp`;
/// only the internal Core Interop adapter does.
let cxxInteropSettings: [SwiftSetting] = [
    .interoperabilityMode(.Cxx)
]

var targets: [Target] = [
    // Portable C++23 computational engine foundation (smoke API only).
    // No Apple frameworks, Foundation, Objective-C, or third-party deps.
    .target(
        name: "RunPlayEngineCpp",
        path: "RunPlayEngineCpp",
        exclude: ["Tests"],
        sources: ["Sources"],
        publicHeadersPath: "include",
        cxxSettings: engineCppSettings
    ),
    // Native C++ test executable (no GoogleTest/Catch2). Exit status is the result.
    .executableTarget(
        name: "RunPlayEngineCppTests",
        dependencies: ["RunPlayEngineCpp"],
        path: "RunPlayEngineCpp/Tests",
        cxxSettings: engineCppSettings
    ),
    // Cross-platform core: Foundation (and conditional FoundationXML) only.
    // This target and its tests are the complete Swift-facing package graph on Linux.
    // C++ interop is enabled so the internal Interop adapter can import
    // RunPlayEngineCpp; C++ types never appear in public RunPlayCore APIs.
    .target(
        name: "RunPlayCore",
        dependencies: ["RunPlayEngineCpp"],
        path: "RunPlayCore/Sources",
        swiftSettings: cxxInteropSettings
    ),
    // Core-only tests (platform-neutral — builds on Linux).
    // Interop is required because SPM attaches the engine module map transitively;
    // tests call only the pure-Swift adapter and must not import the C++ module.
    .testTarget(
        name: "RunPlayCoreTests",
        dependencies: ["RunPlayCore"],
        path: "RunPlayCore/Tests/RunPlayCoreTests",
        resources: [
            .process("Fixtures")
        ],
        swiftSettings: cxxInteropSettings
    ),
]

var products: [Product] = [
    .library(name: "RunPlayCore", targets: ["RunPlayCore"]),
    // Native C++ test host (not a library product).
    .executable(name: "RunPlayEngineCppTests", targets: ["RunPlayEngineCppTests"]),
]

// macOS-only layers are absent from the Linux package graph.
#if os(macOS)
targets.append(contentsOf: [
    // Vendored ZIPFoundation 0.9.20 (MIT). Kept as a first-party target so
    // `swift test -Xswiftc -warnings-as-errors` does not conflict with SPM's
    // automatic `-suppress-warnings` for external package products.
    // Sources are unmodified; see THIRD_PARTY_NOTICES.md.
    // No C++ dependency and no C++ interop.
    .target(
        name: "ZIPFoundation",
        path: "ThirdParty/ZIPFoundation",
        exclude: ["LICENSE"],
        resources: [
            .process("Resources")
        ],
        swiftSettings: [
            .swiftLanguageMode(.v5)
        ]
    ),
    // macOS non-UI platform layer: SceneKit, AppKit value types, MapKit,
    // and Combine are allowed; SwiftUI, Charts, and presentation code are not.
    // ZIP access is confined here — never imported by RunPlayCore.
    // C++ interop is enabled only because SPM propagates the engine module map
    // through RunPlayCore; this target must not import RunPlayEngineCpp.
    .target(
        name: "RunPlayPlatform",
        dependencies: [
            "RunPlayCore",
            "ZIPFoundation",
        ],
        path: "RunPlayPlatform/Sources",
        swiftSettings: cxxInteropSettings
    ),
    .testTarget(
        name: "RunPlayPlatformTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayPlatform/Tests/RunPlayPlatformTests",
        swiftSettings: cxxInteropSettings
    ),
    // macOS UI layer: owns the app lifecycle and all SwiftUI/Charts code.
    // C++ interop is enabled only for SPM transitive module-map reasons;
    // this target must not import RunPlayEngineCpp.
    .executableTarget(
        name: "RunPlayStudio",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayStudio/Sources",
        resources: [
            .process("../Resources")
        ],
        swiftSettings: cxxInteropSettings
    ),
    .testTarget(
        name: "RunPlayStudioTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform", "RunPlayStudio"],
        path: "RunPlayStudio/Tests/RunPlayStudioTests",
        swiftSettings: cxxInteropSettings
    ),
])
products.append(.library(name: "RunPlayPlatform", targets: ["RunPlayPlatform"]))
products.append(.executable(name: "RunPlayStudio", targets: ["RunPlayStudio"]))
#endif

let package = Package(
    name: "RunPlayStudio",
    platforms: [
        .macOS(.v26),
    ],
    products: products,
    dependencies: [],
    targets: targets,
    swiftLanguageModes: [.v6],
    // Typed SPM C++23 setting. Emits -std=c++2b on current toolchains; Apple
    // Clang and the Linux Swift toolchain both define __cplusplus as 202302L
    // for this mode (equivalent to ISO C++23).
    cxxLanguageStandard: .cxx2b
)
