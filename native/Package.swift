// swift-tools-version:5.9
import PackageDescription

// No .xcodeproj on purpose: `swift build` + a hand-assembled .app keeps the whole thing
// scriptable and diffable, the same way the web version had no build step to hide behind.
let package = Package(
    name: "IntroPlayerNative",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "IntroPlayerNative",
            path: "Sources/IntroPlayerNative"
        ),
        // helper used by change-icon.sh; not part of the app bundle
        .executableTarget(
            name: "MakeIcon",
            path: "Sources/MakeIcon"
        )
    ]
)
