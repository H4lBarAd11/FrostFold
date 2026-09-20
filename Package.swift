// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacGlass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacGlass",
            path: "Sources/MacGlass"
        )
    ]
)
