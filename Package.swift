// swift-tools-version: 5.9
import PackageDescription

let sqliteLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L/lib/x86_64-linux-gnu"], .when(platforms: [.linux]))
]

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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3")
    ],
    targets: [
        .target(
            name: "SoundingKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            linkerSettings: sqliteLinkerSettings
        ),
        .executableTarget(
            name: "sounding",
            dependencies: [
                "SoundingKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            linkerSettings: sqliteLinkerSettings
        ),
        .testTarget(
            name: "SoundingKitTests",
            dependencies: [
                "SoundingKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Fixtures")
            ],
            linkerSettings: sqliteLinkerSettings
        )
    ]
)
