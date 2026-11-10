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
        // Quick Look 预览扩展。打包脚本把它装进 Silk.app/Contents/PlugIns/SilkQuickLook.appex。
        // 入口是系统的 _NSExtensionMain，不是 main.swift 里的代码。
        .executableTarget(
            name: "SilkQuickLook",
            path: "Sources/SilkQuickLook",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"]),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "SilkTests",
            dependencies: ["Silk"],
            path: "Tests/SilkTests"
        ),
    ]
)
