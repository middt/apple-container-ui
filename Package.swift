// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppleContainerUI",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "AppleContainerUI", targets: ["AppleContainerUI"])
    ],
    targets: [
        .executableTarget(
            name: "AppleContainerUI",
            path: "Sources/AppleContainerUI"
        ),
        .testTarget(
            name: "AppleContainerUITests",
            dependencies: ["AppleContainerUI"],
            path: "Tests/AppleContainerUITests"
        )
    ]
)
