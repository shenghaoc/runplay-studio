// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-neutral core library (no SwiftUI, AppKit, MapKit, Charts, CoreLocation)
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

// macOS-only targets (require SwiftUI, AppKit, MapKit, Charts)
#if os(macOS)
targets.append(contentsOf: [
    .executableTarget(
        name: "RunPlayStudio",
        dependencies: ["RunPlayCore"],
        path: "RunPlayStudio/Sources",
        resources: [
            .process("../Resources")
        ]
    ),
    .testTarget(
        name: "RunPlayStudioTests",
        dependencies: ["RunPlayStudio"],
        path: "RunPlayStudio/Tests/RunPlayStudioTests"
    ),
])
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
