// swift-tools-version: 6.2

// The web backend's test (Docs/platforms.md): CommunicationWeb over a real
// browser's RTCPeerConnection, two connections in one page. A package of
// its own so that JavaScriptKit (its event loop, which runs Swift's
// concurrency on the browser's) is the test's dependency and not
// Communication's. Built with `swift package --swift-sdk <wasm> js` and run
// in headless Chromium (Page/run.mjs).
import PackageDescription

let package = Package(
    name: "web_loopback",
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", exact: "0.63.0"),
    ],
    targets: [
        .executableTarget(
            name: "WebLoopback",
            dependencies: [
                .product(name: "Communication", package: "communication"),
                .product(name: "CommunicationWeb", package: "communication"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
