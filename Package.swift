// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PureRate",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "PureRate",
            path: "Sources/PureRate"
        )
    ]
)
