// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clamshell",
            path: "Sources/Clamshell"
        )
    ]
)
