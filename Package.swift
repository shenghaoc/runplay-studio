// swift-tools-version:6.3
import PackageDescription

var targets: [Target] = [
    // Cross-platform core: Foundation (and conditional FoundationXML) only.
    // This target and its tests are the complete package graph on Linux.
    .target(
        name: "RunPlayCore",
        dependencies: [],
        path: "RunPlayCore/Sources"
    ),
    // Core-only tests (platform-neutral — builds on Linux)
    .testTarget(
        name: "RunPlayCoreTests",
        dependencies: ["RunPlayCore"],
        path: "RunPlayCore/Tests/RunPlayCoreTests"
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
    .target(
        name: "RunPlayPlatform",
        dependencies: ["RunPlayCore"],
        path: "RunPlayPlatform/Sources"
    ),
    .testTarget(
        name: "RunPlayPlatformTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayPlatform/Tests/RunPlayPlatformTests"
    ),
    // macOS UI layer: owns the app lifecycle and all SwiftUI/Charts code.
    .executableTarget(
        name: "RunPlayStudio",
        dependencies: ["RunPlayCore", "RunPlayPlatform"],
        path: "RunPlayStudio/Sources",
        resources: [
            .process("../Resources")
        ]
    ),
    .testTarget(
        name: "RunPlayStudioTests",
        dependencies: ["RunPlayCore", "RunPlayPlatform", "RunPlayStudio"],
        path: "RunPlayStudio/Tests/RunPlayStudioTests"
    ),
])
products.append(.library(name: "RunPlayPlatform", targets: ["RunPlayPlatform"]))
products.append(.executable(name: "RunPlayStudio", targets: ["RunPlayStudio"]))
#endif

let package = Package(
    name: "RunPlayStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
