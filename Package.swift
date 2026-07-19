// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MiRemote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiRemote",
            path: "Sources/MiRemote"
        ),
    ]
)
