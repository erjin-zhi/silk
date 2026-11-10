// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silk",
    platforms: [.macOS("27.0")],
    dependencies: [
        // 自动更新。打包脚本把 Sparkle.framework 放进 Silk.app/Contents/Frameworks。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Silk",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Silk",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
