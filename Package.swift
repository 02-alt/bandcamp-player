// swift-tools-version:6.0
import PackageDescription
import Foundation

// Build flavor. `CABIN_APPSTORE=1 swift build …` (make-mas.sh) produces the Mac App Store build:
// no Sparkle (the store owns updates) and the APPSTORE compile flag, which also leaves out iPod
// sync (it mounts disks and writes raw volumes, which the App Sandbox forbids). Default = the
// Developer ID / DMG build, unchanged.
let appStore = ProcessInfo.processInfo.environment["CABIN_APPSTORE"] == "1"

let package = Package(
    name: "Cabin",
    platforms: [.macOS(.v14)],
    dependencies: appStore ? [] : [
        // Auto-update framework. package.sh embeds Sparkle.framework into the
        // .app bundle and signs its nested helpers for notarization.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Cabin",
            dependencies: appStore ? [] : [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Cabin",
            resources: [
                .process("Resources/AppIcon.png"),
                .process("Resources/yeezus-tape.png"),
                // Bundled so SwiftPM doesn't warn about an unhandled file; the app
                // bundle's copy (used by OSAScriptingDefinition) is placed directly
                // under Contents/Resources by package.sh.
                .copy("Resources/Cabin.sdef"),
                // Optional drop-in vinyl-crackle loop (see Resources/Audio/README.md).
                // Copied verbatim so a user-supplied clip ships without editing the manifest.
                .copy("Resources/Audio")
            ],
            swiftSettings: appStore ? [.define("APPSTORE")] : [],
            linkerSettings: [
                // So the bundled binary finds Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])
            ]
        ),
        // Unit tests. `swift test` builds these; package.sh only builds the executable product,
        // so shipping is unaffected. Exercises the brittle Bandcamp response parsers through a
        // fixture-backed HTTP fake — the first tests in the project.
        .testTarget(
            name: "CabinTests",
            dependencies: ["Cabin"],
            path: "Tests/CabinTests"
        )
    ]
)
