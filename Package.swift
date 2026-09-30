// swift-tools-version:6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "DigisensusRecorder",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Over-the-air updates: download, EdDSA and code-signature checks, install, relaunch.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "DigisensusRecorder",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                "COpusShim",
            ],
            path: "Sources/DigisensusRecorder",
            // Sparkle.framework is embedded in Contents/Frameworks by build.sh and package.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DigisensusRecorderTests",
            dependencies: ["DigisensusRecorder"],
            path: "Tests/DigisensusRecorderTests"
        ),
        // The CLI and MCP server agents run; it ships inside the app bundle.
        .executableTarget(
            name: "recorder",
            path: "Sources/recorder",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "\(packageRoot)/RecorderHelper-Info.plist"])]
        ),
        // Bundled Ogg Opus codec: libopus and libogg (BSD licensed; see Vendor/README.md) as
        // static universal libraries, so recordings don't depend on an ffmpeg install.
        .target(
            name: "COpusShim",
            path: "Sources/COpusShim",
            linkerSettings: [
                .unsafeFlags(["-L\(packageRoot)/Vendor/lib"]),
                .linkedLibrary("opus"),
                .linkedLibrary("ogg"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
