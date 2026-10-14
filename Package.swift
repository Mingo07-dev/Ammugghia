// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ammugghia",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Ammugghia",
            path: "Sources/Ammugghia"
        )
    ],
    swiftLanguageVersions: [.v5]
)
