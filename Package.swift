// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoDucking",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AutoDucking", targets: ["AutoDucking"])
    ],
    targets: [
        .target(
            name: "AutoDuckingCore"
        ),
        .executableTarget(
            name: "AutoDucking",
            dependencies: ["AutoDuckingCore"]
        ),
        .testTarget(
            name: "AutoDuckingCoreTests",
            dependencies: ["AutoDuckingCore"]
        )
    ]
)
