# Changelog

Each release's notes, newest first, as its prepare pull request added them (`Docs/releasing.md`).

## 0.2.1

- `CommunicationNative` for Android (arm64 and x86_64, API 28 and later): the release's `CWebRTC.artifactbundle.zip` carries Android variants beside Linux's, LiveKit's Android libwebrtc with the shim compiled against the NDK's libc++, so `swift build --swift-sdk aarch64-unknown-linux-android28` (swift.org's Swift SDK for Android) links WebRTC with nothing to install. An app ships `libc++_shared.so` beside its own libraries, as Swift's Android runtime already asks.

## 0.1.1

- Data channels are named by label, one at a time, on every backend: opening one with a label in use fails, and a remote channel with such a label is closed unannounced, so a peer can't take over or close the app's channels.
- `CommunicationNative` for Linux (x64 and arm64): `NativeWebRTCHost` over CWebRTC, a C interface over LiveKit's prebuilt static libwebrtc, which SwiftPM downloads as this release's `CWebRTC.artifactbundle.zip` (SE-0482). Nothing to install. Android is proved and its variants come next; Windows waits on a libwebrtc built for Swift's C runtime.
- Communication on every platform with no dependency beyond WebRTC itself: `CommunicationCore` implements the API once over `WebRTCHost`, a small plain-Swift protocol, and each platform supplies a host.
- `CommunicationWeb` for the web (wasm): `WebWebRTCHost` over the browser's own `RTCPeerConnection`, through the `communication_webrtc` wasm imports and `Web/communication_webrtc.js`, with no dependency. A page passes the JavaScript's imports to its wasm loader and runs Swift's concurrency on the browser's event loop.
