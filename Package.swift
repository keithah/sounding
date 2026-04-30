// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sounding",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SoundingKit",
            targets: ["SoundingKit"]
        ),
        .executable(
            name: "sounding",
            targets: ["sounding"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SoundingKit"
        ),
        .executableTarget(
            name: "sounding",
            dependencies: [
                "SoundingKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SoundingKitTests",
            dependencies: ["SoundingKit"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
