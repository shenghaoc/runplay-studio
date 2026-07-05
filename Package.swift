// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunPlayStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "RunPlayStudio", targets: ["RunPlayStudio"])
    ],
    targets: [
        .executableTarget(
            name: "RunPlayStudio",
            dependencies: [],
            path: "RunPlayStudio/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "RunPlayStudioTests",
            dependencies: ["RunPlayStudio"],
            path: "RunPlayStudio/Tests/RunPlayStudioTests"
        )
    ]
)
