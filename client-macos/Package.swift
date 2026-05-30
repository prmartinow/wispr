// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Whisper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Whisper",
            path: "Sources/Whisper"
        )
    ]
)
