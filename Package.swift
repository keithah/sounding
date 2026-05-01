// swift-tools-version: 5.9
import Foundation
import PackageDescription

let sqliteLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L/lib/x86_64-linux-gnu"], .when(platforms: [.linux]))
]

let xcodeDeveloperPath = "/Applications/Xcode.app/Contents/Developer"
let xcodeMacOSPlatformPath = "\(xcodeDeveloperPath)/Platforms/MacOSX.platform/Developer"
let xcodeXCTestSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: xcodeDeveloperPath) ? [
    .unsafeFlags([
        "-I\(xcodeMacOSPlatformPath)/usr/lib",
        "-F\(xcodeMacOSPlatformPath)/Library/Frameworks"
    ], .when(platforms: [.macOS]))
] : []
let xcodeXCTestLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(atPath: xcodeDeveloperPath) ? [
    .unsafeFlags([
        "-F\(xcodeMacOSPlatformPath)/Library/Frameworks",
        "-L\(xcodeMacOSPlatformPath)/usr/lib",
        "-lXCTestSwiftSupport",
        "-framework", "XCTest",
        "-Xlinker", "-rpath", "-Xlinker", "\(xcodeMacOSPlatformPath)/usr/lib",
        "-Xlinker", "-rpath", "-Xlinker", "\(xcodeMacOSPlatformPath)/Library/Frameworks"
    ], .when(platforms: [.macOS]))
] : []

let package = Package(
    name: "Sounding",
    platforms: [
        .macOS(.v14)
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
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3"),
        .package(name: "argmax-oss-swift", url: "https://github.com/argmaxinc/WhisperKit", from: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.14.3")
    ],
    targets: [
        .target(
            name: "SoundingKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift", condition: .when(platforms: [.macOS])),
                .product(name: "FluidAudio", package: "FluidAudio", condition: .when(platforms: [.macOS]))
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
            swiftSettings: xcodeXCTestSwiftSettings,
            linkerSettings: sqliteLinkerSettings + xcodeXCTestLinkerSettings
        )
    ]
)
