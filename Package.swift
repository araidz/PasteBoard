// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PasteBoard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PasteBoard",
            path: "Sources/PasteBoard"
        )
    ]
)
