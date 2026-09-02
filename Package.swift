// swift-tools-version: 6.0

// Communication: a consistent, idiomatic, async, strict-concurrency Swift
// API for WebRTC.
//
//   - `Communication` is the API: the currency types (configurations, ICE
//     servers and candidates, session descriptions, events, errors) and the
//     `CommunicationPeerConnection` / `CommunicationConnector` protocols.
//     It imports nothing but Foundation and compiles anywhere Swift does.
//   - `CommunicationWebRTC` is the Apple implementation (iOS, macOS),
//     backed by Google's WebRTC via the stasel/WebRTC binary distribution.
//
// Further platform implementations (Android, Linux, Windows) conform to the
// same API, either inside this package or by adapting a platform stack
// externally.
import PackageDescription

let package = Package(
    name: "communication",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Communication", targets: ["Communication"]),
        .library(name: "CommunicationWebRTC", targets: ["CommunicationWebRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", from: "152.0.0"),
    ],
    targets: [
        .target(name: "Communication"),
        .target(
            name: "CommunicationWebRTC",
            dependencies: [
                "Communication",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .testTarget(
            name: "CommunicationWebRTCTests",
            dependencies: ["CommunicationWebRTC"]
        ),
    ]
)
