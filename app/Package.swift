// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NXGameLibrary",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NXGameLibrary", path: "Sources/NXGameLibrary")
    ]
)
