// swift-tools-version: 6.0
import Foundation
import PackageDescription

// xs is linked in as a static library built from xs-ffi/ by cargo, so
// build with ./build, which runs cargo first.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "stacks2",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CXs", path: "Sources/CXs"),
        .executableTarget(
            name: "Stacks2",
            dependencies: ["CXs"],
            exclude: ["datastar.js"],
            resources: [.copy("panel.html"), .copy("clipboard.nu")],
            linkerSettings: [
                .unsafeFlags(["-L", "\(root)/xs-ffi/target/release"]),
                .linkedLibrary("iconv"),
                .linkedLibrary("z"),
                .linkedFramework("CoreServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("OpenDirectory"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        )
    ]
)
