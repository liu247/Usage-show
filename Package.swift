// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "token_show",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "token_show",
            path: "Sources"
        ),
        .testTarget(
            name: "token_showTests",
            dependencies: ["token_show"],
            path: "Tests"
        ),
    ]
)
