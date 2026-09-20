// swift-tools-version:6.4
import PackageDescription

// Remote dependencies, exact-pinned; bumps are manual, reviewable edits.
// The entries are deliberately NOT platform-gated, even though only macOS
// targets consume ZIPFoundation's product: a manifest whose dependencies
// array differs per host resolves differently on macOS and in the Linux
// container, and Package.resolved would churn between the two. Linux
// resolves (and therefore fetches) the package but compiles none of it;
// only the target-level product dependency below sits inside #if os(macOS).
let remoteDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20"),
]

let engineCppSettings: [CXXSetting] = [
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
    // Portable C++23 computational engine foundation. It provides engine
    // identity, route input values, geodesy primitives, and the production
    // route-quality, personal heatmap coverage, constrained-DTW path,
    // segment-detection, elevation-profile, and route-metric scale-bucket
    // kernels.
    // No Apple frameworks, Foundation, Objective-C, or third-party deps.
    // Native C++ tests live under RunPlayEngineCpp/Tests/ and are built by
    // ./scripts/run-cpp-engine-tests.sh (clang++). The SwiftPM test target below
    // invokes that runner because a dependent C++ executable target fails under
    // SwiftPM's explicit-module build on Linux.
    .target(
        name: "RunPlayEngineCpp",
        path: "RunPlayEngineCpp",
        exclude: ["SwiftPMTests", "Tests"],
        sources: ["Sources"],
        publicHeadersPath: "include",
        cxxSettings: engineCppSettings
    ),
    // Cross-platform SwiftPM harness for the independent native C++ executable.
    // The assertions remain in the native test sources; this target makes the
    // real native build/run available through `swift test --filter
    // RunPlayEngineCppTests` on both Linux and macOS.
    .testTarget(
        name: "RunPlayEngineCppTests",
        path: "RunPlayEngineCpp/SwiftPMTests"
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
]

// macOS-only layers are absent from the Linux package graph.
#if os(macOS)
targets.append(contentsOf: [
    // macOS non-UI platform layer: SceneKit, AppKit value types, MapKit,
    // and Combine are allowed; SwiftUI, Charts, and presentation code are not.
    // ZIP access is confined here — never imported by RunPlayCore.
    // C++ interop is enabled only because SPM propagates the engine module map
    // through RunPlayCore; this target must not import RunPlayEngineCpp.
    .target(
        name: "RunPlayPlatform",
        dependencies: [
            "RunPlayCore",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
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
    dependencies: remoteDependencies,
    targets: targets,
    swiftLanguageModes: [.v6],
    // Typed SPM C++23 setting. Emits -std=c++2b on current toolchains; Apple
    // Clang and the Linux Swift toolchain both define __cplusplus as 202302L
    // for this mode (equivalent to ISO C++23).
    cxxLanguageStandard: .cxx2b
)
