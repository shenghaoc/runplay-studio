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
                // SwiftPM currently propagates the C++ module map through
                // RunPlayCore, so external Swift consumers must enable interop.
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
