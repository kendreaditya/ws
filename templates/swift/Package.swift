// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "{{name}}",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "{{name}}",
            path: "Sources"
        )
    ]
)
