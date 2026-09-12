// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DACSync",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DACSync",
            path: "Sources/DACSync"
        )
    ]
)
