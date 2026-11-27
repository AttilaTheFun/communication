// swift-tools-version: 6.2

// cwebrtc-bundle: builds CWebRTC's SE-0482 artifact bundle from LiveKit's
// prebuilt libwebrtc (Docs/platforms.md). A tool for this repository's CI,
// not part of the package.
import PackageDescription

let package = Package(
    name: "cwebrtc_bundle",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "cwebrtc-bundle",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources"
        ),
    ],
    swiftLanguageModes: [.v6]
)
