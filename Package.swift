// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenControl",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScreenControl",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ScreenControl",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework .app paketinin içinde Contents/Frameworks'te taşınıyor.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
