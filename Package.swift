// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppWindow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AppWindow", path: "Sources/Context"),
        .testTarget(
            name: "AppWindowTests",
            dependencies: ["AppWindow"],
            path: "Tests/AppWindowTests"
        )
    ]
)
