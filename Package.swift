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
    // A version bump MUST re-check the ZIP64 local-header-offset defect pinned by
    // AppleHealthArchiveServiceTests.testZip64OffsetSentinelArchiveIsRefusedBecauseZIPFoundationListsNoEntries:
    // 0.9.20's Entry.CentralDirectoryStructure.effectiveRelativeOffsetOfLocalHeader
    // (Entry.swift:311) reads the ZIP64 extra field only when the offset is > 0, so
    // an archive whose first entry stores offset 0 there lists zero entries.
    .package(url: "https://github.com/weichsel/ZIPFoundation", exact: "0.9.20"),
]

// User-facing strings live in one String Catalog per Swift module
// (`<Module>/Localization/Localizable.xcstrings`), compiled into that module's
// resource bundle. Each catalog is named as a file, never through a directory
// rule: a directory resource is copied verbatim, and an uncompiled catalog
// resolves nothing. Catalogs compile with Xcode's xcstringstool, which the
// Linux toolchain does not ship, so Core declares its catalog on macOS only:
// on Linux the catalog sits outside the target path, Core's strings resolve to
// their English source text, and no resource bundle is built.
#if os(macOS)
let coreResources: [Resource] = [.process("../Localization/Localizable.xcstrings")]
#else
let coreResources: [Resource] = []
#endif

let engineCppSettings: [CXXSetting] = [
    .treatAllWarnings(as: .error),
]

/// Warnings are errors in the Swift targets we own, as `engineCppSettings` does
/// for C++. This lives in the manifest, not in a command-line
/// `-Xswiftc -warnings-as-errors`: that flag reaches every target, dependencies
/// included, and SwiftPM compiles dependencies with `-suppress-warnings`, which
/// swift-build on Swift 6.3 rejects as a conflicting option. A manifest setting
/// applies to our targets only, and gates every `swift build` and `swift test`
/// on macOS and Linux alike.
let strictWarnings: [SwiftSetting] = [
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
        path: "RunPlayEngineCpp/SwiftPMTests",
        swiftSettings: strictWarnings
    ),
    // Cross-platform core: Foundation (and conditional FoundationXML) only.
    // This target and its tests are the complete Swift-facing package graph on Linux.
    // C++ interop is enabled so the internal Interop adapter can import
    // RunPlayEngineCpp; C++ types never appear in public RunPlayCore APIs.
    .target(
        name: "RunPlayCore",
        dependencies: ["RunPlayEngineCpp"],
        path: "RunPlayCore/Sources",
        resources: coreResources,
        swiftSettings: cxxInteropSettings + strictWarnings
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
        swiftSettings: cxxInteropSettings + strictWarnings
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
        resources: [
            .process("../Localization/Localizable.xcstrings")
        ],
        swiftSettings: cxxInteropSettings + strictWarnings
    ),
    .testTarget(
        name: "RunPlayPlatformTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayPlatform/Tests/RunPlayPlatformTests",
        // `Fixtures` holds one generated archive plus the script that wrote it.
        // Copied rather than processed so the bytes are exactly what the
        // generator produced.
        resources: [
            .copy("Fixtures")
        ],
        swiftSettings: cxxInteropSettings + strictWarnings
    ),
    // macOS UI layer: owns the app lifecycle and all SwiftUI/Charts code.
    // C++ interop is enabled only for SPM transitive module-map reasons;
    // this target must not import RunPlayEngineCpp.
    .executableTarget(
        name: "RunPlayStudio",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayStudio/Sources",
        resources: [
            .process("../Resources"),
            .process("../Localization/Localizable.xcstrings")
        ],
        swiftSettings: cxxInteropSettings + strictWarnings
    ),
    .testTarget(
        name: "RunPlayStudioTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform", "RunPlayStudio"],
        path: "RunPlayStudio/Tests/RunPlayStudioTests",
        swiftSettings: cxxInteropSettings + strictWarnings
    ),
])
products.append(.library(name: "RunPlayPlatform", targets: ["RunPlayPlatform"]))
products.append(.executable(name: "RunPlayStudio", targets: ["RunPlayStudio"]))
#endif

let package = Package(
    name: "RunPlayStudio",
    defaultLocalization: "en",
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
