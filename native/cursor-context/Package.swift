// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "cursor-context",
    platforms: [.macOS(.v11)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "cursor-context",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
