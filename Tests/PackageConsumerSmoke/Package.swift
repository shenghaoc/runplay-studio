// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "RunPlayCoreConsumerSmoke",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "RunPlayCoreConsumerSmoke",
            targets: ["RunPlayCoreConsumerSmoke"]
        ),
    ],
    dependencies: [
        .package(name: "RunPlayStudio", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "RunPlayCoreConsumerSmoke",
            dependencies: [
                .product(name: "RunPlayCore", package: "RunPlayStudio"),
            ],
            swiftSettings: [
                // Our own target: warnings are errors, as in the main package.
                .treatAllWarnings(as: .error),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
