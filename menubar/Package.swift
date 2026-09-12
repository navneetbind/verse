// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lyra-menubar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "lyra-menubar",
            path: "Sources/lyra-menubar"
        )
    ]
)
