// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Yoin",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update framework. package.sh embeds Sparkle.framework into the
        // .app bundle and signs its nested helpers for notarization.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Yoin",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Yoin",
            resources: [
                .process("Resources/AppIcon.png"),
                .process("Resources/yeezus-tape.png"),
                // Bundled so SwiftPM doesn't warn about an unhandled file; the app
                // bundle's copy (used by OSAScriptingDefinition) is placed directly
                // under Contents/Resources by package.sh.
                .copy("Resources/Yoin.sdef"),
                // Optional drop-in vinyl-crackle loop (see Resources/Audio/README.md).
                // Copied verbatim so a user-supplied clip ships without editing the manifest.
                .copy("Resources/Audio")
            ],
            linkerSettings: [
                // So the bundled binary finds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Unit tests. `swift test` builds these; package.sh only builds the executable product,
        // so shipping is unaffected. Exercises the brittle Bandcamp response parsers through a
        // fixture-backed HTTP fake — the first tests in the project.
        .testTarget(
            name: "YoinTests",
            dependencies: ["Yoin"],
            path: "Tests/YoinTests"
        )
    ]
)
