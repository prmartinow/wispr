// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wispr",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Wispr",
            path: "Sources/Wispr"
        )
    ]
)
