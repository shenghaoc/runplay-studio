// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunPlayStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RunPlayCore", targets: ["RunPlayCore"]),
        .executable(name: "RunPlayStudio", targets: ["RunPlayStudio"])
    ],
    targets: [
        // Platform-neutral core library (no SwiftUI, AppKit, SceneKit, MapKit, Charts, CoreLocation)
        .target(
            name: "RunPlayCore",
            dependencies: [],
            path: "RunPlayCore/Sources"
        ),
        // macOS executable target
        .executableTarget(
            name: "RunPlayStudio",
            dependencies: ["RunPlayCore"],
            path: "RunPlayStudio/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        // Core-only tests (platform-neutral)
        .testTarget(
            name: "RunPlayCoreTests",
            dependencies: ["RunPlayCore"],
            path: "RunPlayCore/Tests/RunPlayCoreTests"
        ),
        // Full app tests (macOS only)
        .testTarget(
            name: "RunPlayStudioTests",
            dependencies: ["RunPlayStudio"],
            path: "RunPlayStudio/Tests/RunPlayStudioTests"
        )
    ]
)
