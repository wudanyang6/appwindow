// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppWindow",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 自动更新：Sparkle 2（首个第三方依赖，Package.resolved 需提交）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "AppWindow",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Context"
        ),
        .testTarget(
            name: "AppWindowTests",
            dependencies: ["AppWindow"],
            path: "Tests/AppWindowTests"
        )
    ]
)
