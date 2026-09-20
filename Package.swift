// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrostFold",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrostFold",
            path: "Sources/FrostFold"
        )
    ]
)
