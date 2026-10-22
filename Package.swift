// swift-tools-version: 6.0

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
        .library(name: "CommunicationWebRTC", targets: ["CommunicationWebRTC"]),
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
        .target(
            name: "CommunicationWebRTC",
            dependencies: [
                "Communication",
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ]
        ),
        .testTarget(
            name: "CommunicationWebRTCTests",
            dependencies: ["CommunicationWebRTC"]
        ),
        // Examples/: small programs showing the package; not products.
        .executableTarget(
            name: "DataChannelEcho",
            dependencies: ["Communication", "CommunicationWebRTC"],
            path: "Examples/DataChannelEcho"
        ),
    ]
)
