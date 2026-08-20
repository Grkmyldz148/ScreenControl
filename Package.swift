// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenControl",
            path: "Sources/ScreenControl",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
