// swift-tools-version:6.3
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

/// Warnings are errors in the Swift targets we own. This lives in the manifest, not in a command-line
/// `-Xswiftc -warnings-as-errors`: that flag reaches every target, dependencies
/// included, and SwiftPM compiles dependencies with `-suppress-warnings`, which
/// swift-build on Swift 6.3 rejects as a conflicting option. A manifest setting
/// applies to our targets only, and gates every `swift build` and `swift test`
/// on macOS and Linux alike.
let strictWarnings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
]

var targets: [Target] = [
    // Pure Swift computational engine. Core calls each kernel through its
    // adapter in RunPlayCore/Sources/Engine, one engine call per production
    // operation. Swift standard library and the platform C math module only:
    // no Foundation, I/O, or third-party dependencies.
    .target(
        name: "RunPlayEngine",
        path: "RunPlayEngine/Sources",
        swiftSettings: [.strictMemorySafety()] + strictWarnings
    ),
    // Test-only parity primitives shared by the engine and Core suites.
    .target(
        name: "RunPlayEngineTestSupport",
        path: "RunPlayEngine/TestSupport",
        swiftSettings: strictWarnings
    ),
    .testTarget(
        name: "RunPlayEngineTests",
        dependencies: ["RunPlayEngine", "RunPlayEngineTestSupport"],
        path: "RunPlayEngine/Tests",
        swiftSettings: strictWarnings
    ),
    // Cross-platform core: Foundation (and conditional FoundationXML) only.
    // This target and its tests are the complete Swift-facing package graph on Linux.
    // RunPlayEngine is imported with `internal import`; engine types never
    // appear in public RunPlayCore APIs.
    .target(
        name: "RunPlayCore",
        dependencies: ["RunPlayEngine"],
        path: "RunPlayCore/Sources",
        resources: coreResources,
        swiftSettings: strictWarnings
    ),
    // Core-only tests (platform-neutral — builds on Linux).
    .testTarget(
        name: "RunPlayCoreTests",
        dependencies: ["RunPlayCore", "RunPlayEngineTestSupport"],
        path: "RunPlayCore/Tests/RunPlayCoreTests",
        resources: [
            .process("Fixtures")
        ],
        swiftSettings: strictWarnings
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
    // This target must not import RunPlayEngine.
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
        swiftSettings: strictWarnings
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
        swiftSettings: strictWarnings
    ),
    // macOS UI layer: owns the app lifecycle and all SwiftUI/Charts code.
    // This target must not import RunPlayEngine.
    .executableTarget(
        name: "RunPlayStudio",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayStudio/Sources",
        resources: [
            .process("../Resources"),
            .process("../Localization/Localizable.xcstrings")
        ],
        swiftSettings: strictWarnings
    ),
    .testTarget(
        name: "RunPlayStudioTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform", "RunPlayStudio"],
        path: "RunPlayStudio/Tests/RunPlayStudioTests",
        swiftSettings: strictWarnings
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
    swiftLanguageModes: [.v6]
)
