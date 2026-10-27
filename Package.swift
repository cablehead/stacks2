// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "stacks2",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stacks2",
            exclude: ["datastar.js"],
            resources: [.copy("panel.html"), .copy("clipboard.nu")]
        )
    ]
)
