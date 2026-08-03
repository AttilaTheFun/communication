// swift-tools-version: 5.9
import PackageDescription

// Present so rules_swift_package_manager can resolve the WebRTC XCFramework.
// The library itself is built by Bazel, not SwiftPM.
let package = Package(
    name: "communication",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        // Forked for an M148 macOS header fix not yet upstream in stasel/WebRTC.
        .package(url: "https://github.com/AttilaTheFun/WebRTC", from: "148.0.0"),
    ]
)
