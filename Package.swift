// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silk",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Silk",
            path: "Sources/Silk"
        ),
        .testTarget(
            name: "SilkTests",
            dependencies: ["Silk"],
            path: "Tests/SilkTests"
        ),
    ]
)
