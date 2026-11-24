# TODO

Tabled on 2026-11-18, while Convo drops its blockchain parts. Done so far:
the Swift 6 settings, `CommunicationCore` over `WebRTCHost` (signaling and
data channels), and the Apple adapter, `LiveKitWebRTCHost`, tested over real
WebRTC. The plan and its reasons are in `Docs/platforms.md`.

## Platforms

- **Web adapter:** JavaScript over `RTCPeerConnection`, from Convo's
  `index.html` WebRTC code. It's injected through Isomer's swift_ffi
  dependencies: a JS module exporting `webRTCHost(Dependencies)`, with a
  dependency key the core reads on wasm.
- **Android adapter:** Kotlin over `org.webrtc` (`stream-webrtc-android`), from
  Convo's `AppServices.kt`. It goes through `isomer_android_app(services_kt =
  …, services_installer = "CommunicationHost.install()", services_deps = …)`.
- **The Isomer binding:** a swift_ffi `@ExportedInterface` mirror of
  `WebRTCHost`, plus the install function and the dependency key. It's Bazel
  only (swift_ffi isn't in Isomer's Swift package), so Communication becomes
  a Bazel module too, published to AttilaTheFun/bazel_registry, with
  filegroups for the JS and the Kotlin.
- **Linux and Windows adapter:** Swift over a small C shim (`CWebRTCShim`) over
  libwebrtc's C++ API, using LiveKit's prebuilt static libwebrtc
  (livekit/rust-sdks `webrtc-<commit>` releases: linux and win, x64 and
  arm64).
- **Builds:** cross-compile the core for wasm and Android in CI, as well as
  Linux and macOS.

## Media

- Track primitives in `WebRTCHost` (add and remove tracks, transceivers,
  senders and receivers, remote tracks as events). Then `WebRTCConnector`
  shrinks to `LiveKitWebRTCHost`, and the per-file
  `#if canImport(LiveKitWebRTC)` guards go with it.
- Capture and rendering per platform, in the adapters.

## Consumers and release

- Convo moves onto Communication when it moves to current Isomer, and
  `ConvoHost` drops its WebRTC calls (Convo's TODO.md).
- LiveKit's published xcframework again once a release includes
  webrtc-sdk/webrtc#318 (`Docs/README.md`, To do).
- The Apple backend's build and tests in CI (a macOS runner at release
  verification); Linux builds and tests on every pull request and push to
  main (.github/workflows/ci.yml).
