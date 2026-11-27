// swift-tools-version: 6.2

// Communication: a consistent, idiomatic, async, strict-concurrency Swift
// API for WebRTC.
//
//   - `Communication` is the API: the currency types (configurations, ICE
//     servers and candidates, session descriptions, events, errors) and the
//     `CommunicationPeerConnection` / `CommunicationConnector` protocols.
//     It imports nothing but Foundation and compiles anywhere Swift does.
//   - `CommunicationWebRTC` is the Apple implementation (iOS, macOS),
//     backed by Google's WebRTC via LiveKit's binary distribution
//     (livekit/webrtc-xcframework), which covers visionOS too.
//
// Further platform implementations (Android, Linux, Windows) conform to the
// same API, either inside this package or by adapting a platform stack
// externally.
import PackageDescription

let package = Package(
    name: "communication",
    platforms: [.iOS(.v16), .macOS(.v13), .visionOS("26.0")],
    products: [
        .library(name: "Communication", targets: ["Communication"]),
        .library(name: "CommunicationCore", targets: ["CommunicationCore"]),
        .library(name: "CommunicationWebRTC", targets: ["CommunicationWebRTC"]),
        .library(name: "CommunicationNative", targets: ["CommunicationNative"]),
        .library(name: "CommunicationWeb", targets: ["CommunicationWeb"]),
    ],
    dependencies: [
        // LiveKit's packaging of Google's WebRTC (class prefix LK): the same
        // Objective-C API as stasel's builds, with visionOS and tvOS slices.
        // TODO: back to LiveKit's release (Docs/README.md, To do). For now
        // our fork's 150.7871.02 with the macOS and Catalyst privacy
        // manifest moved out of a nested Versions/A/Versions directory (which
        // breaks rules_apple), binaries unchanged; back to
        // livekit/webrtc-xcframework once webrtc-sdk/webrtc#318 is released.
        .package(url: "https://github.com/AttilaTheFun/webrtc-xcframework", exact: "150.7871.02-privacy-fix"),
    ],
    targets: [
        .target(name: "Communication"),
        // The implementation every platform shares, over a WebRTCHost (the
        // platform's WebRTC, in W3C terms): plain Swift, no #if.
        .target(name: "CommunicationCore", dependencies: ["Communication"]),
        .testTarget(name: "CommunicationCoreTests", dependencies: ["Communication", "CommunicationCore"]),
        .target(
            name: "CommunicationWebRTC",
            dependencies: [
                "Communication",
                "CommunicationCore",
                // LiveKit's xcframework has Apple slices only; elsewhere the
                // target's files are empty (`#if canImport(LiveKitWebRTC)`).
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS, .tvOS, .macCatalyst])
                ),
            ]
        ),
        .testTarget(
            name: "CommunicationWebRTCTests",
            dependencies: ["CommunicationWebRTC", "CommunicationCore"]
        ),
        // Linux (Android and Windows to come): libwebrtc through CWebRTC,
        // the C interface over LiveKit's prebuilt static libwebrtc
        // (Docs/platforms.md), as an SE-0482 artifact bundle each release
        // builds and carries. A release commit names its own release's
        // bundle between the cwebrtc-bundle markers (Docs/releasing.md,
        // `cwebrtc-bundle pin`); where there's none yet, or the bundle has
        // no variant, the target's files are empty (`#if canImport(CWebRTC)`).
        .target(
            name: "CommunicationNative",
            dependencies: [
                "Communication",
                "CommunicationCore",
                // cwebrtc-bundle: dependency
                // cwebrtc-bundle: end
            ]
        ),
        // cwebrtc-bundle: target
        // cwebrtc-bundle: end
        .testTarget(
            name: "CommunicationNativeTests",
            dependencies: ["CommunicationNative", "CommunicationCore"]
        ),
        // The web (wasm): the browser's RTCPeerConnection through the
        // `communication_webrtc` imports (CCommunicationWeb, plain C), which
        // Web/communication_webrtc.js implements (Docs/platforms.md).
        // Elsewhere both targets are empty (`#if arch(wasm32)`).
        .target(name: "CCommunicationWeb"),
        .target(
            name: "CommunicationWeb",
            dependencies: ["Communication", "CommunicationCore", "CCommunicationWeb"]
        ),
        // Examples/: small programs showing the package; not products.
        .executableTarget(
            name: "DataChannelEcho",
            dependencies: ["Communication", "CommunicationWebRTC"],
            path: "Examples/DataChannelEcho"
        ),
    ],
    swiftLanguageModes: [.v6]
)

// Swift 6 (strict concurrency) everywhere, and no warnings left standing.
for target in package.targets where target.type != .binary {
    target.swiftSettings = (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
}
