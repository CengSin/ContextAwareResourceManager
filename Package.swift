// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResourceSteward",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ResourceSteward", targets: ["ResourceSteward"]),
        .executable(name: "StewardChecks", targets: ["StewardChecks"]),
        .library(name: "ResourceStewardCore", targets: ["ResourceStewardCore"])
    ],
    targets: [
        .target(
            name: "ProcBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "ResourceStewardCore",
            dependencies: ["ProcBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ResourceSteward",
            dependencies: ["ResourceStewardCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "StewardChecks",
            dependencies: ["ResourceStewardCore"]
        )
    ]
)
