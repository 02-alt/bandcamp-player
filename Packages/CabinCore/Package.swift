// swift-tools-version:6.0
import PackageDescription

/// Cabin's shared core: the platform-independent logic both the Mac and the iPhone app use
/// (service clients, parsers, the credit model). Foundation-only — no AppKit/UIKit/SwiftUI — so
/// it builds for both platforms. Each app depends on this package instead of keeping its own copy.
let package = Package(
    name: "CabinCore",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .library(name: "CabinCore", targets: ["CabinCore"])
    ],
    targets: [
        .target(name: "CabinCore", path: "Sources/CabinCore"),
        .testTarget(name: "CabinCoreTests", dependencies: ["CabinCore"], path: "Tests/CabinCoreTests")
    ]
)
