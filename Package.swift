// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "siliconcellar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SiliconCellarCore", targets: ["SiliconCellarCore"]),
        // Product name must differ in case from SiliconCellar: macOS APFS is
        // case-insensitive, so both would share one .build/.../binary path.
        .executable(name: "siliconcellar-cli", targets: ["siliconcellar"]),
        .executable(name: "SiliconCellar", targets: ["SiliconCellarApp"]),
    ],
    targets: [
        .target(name: "SiliconCellarCore", resources: [.copy("Fixes")]),
        .executableTarget(name: "siliconcellar", dependencies: ["SiliconCellarCore"]),
        .executableTarget(
            name: "SiliconCellarApp",
            dependencies: ["SiliconCellarCore"],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "SiliconCellarCoreTests", dependencies: ["SiliconCellarCore"]),
    ]
)
