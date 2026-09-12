// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "verse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "verse",
            path: "Sources/verse"
        )
    ]
)
