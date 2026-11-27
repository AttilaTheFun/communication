# TODO

Resumed on 2026-11-27, with no Isomer dependency (Logan). Done so far: the
Swift 6 settings, `CommunicationCore` over `WebRTCHost` (signaling and data
channels), the Apple adapter, `LiveKitWebRTCHost`, tested over real WebRTC,
and the native route proved on Linux arm64. The plan and its reasons are in
`Docs/platforms.md`.

## Platforms

- **CWebRTC:** the C++ shim's C API for data channels (connections, offer
  and answer, descriptions, candidates, channels, events), compiled against
  LiveKit's prebuilt libwebrtc and merged into its `libwebrtc.a`.
- **The bundle:** a CI workflow that builds `CWebRTC.artifactbundle` from a
  pinned LiveKit release for every native triple (linux x64 and arm64,
  windows x64 and arm64, android arm, arm64 and x64), and attaches it to a
  release. `Package.swift` names it by URL and checksum.
- **`CommunicationNative`:** Swift over CWebRTC, conforming to `WebRTCHost`,
  with the core's real-WebRTC tests on Linux. Then prove Windows (its C
  runtime) and Android (a Swift SDK for Android).
- **`CommunicationWeb`:** Swift over the `communication_webrtc` wasm imports,
  and `communication_webrtc.js` over `RTCPeerConnection`, from P2PRC's
  `index.html` WebRTC code, tested in a headless browser.
- **Builds:** cross-compile for wasm and Android in CI, as well as Linux and
  macOS.

## Media

- Track primitives in `WebRTCHost` (add and remove tracks, transceivers,
  senders and receivers, remote tracks as events). Then `WebRTCConnector`
  shrinks to `LiveKitWebRTCHost`, and the per-file
  `#if canImport(LiveKitWebRTC)` guards go with it.
- Capture and rendering per platform, in the backends. Android's audio
  needs libwebrtc's JVM and context, which the app passes once.

## Consumers and release

- P2PRC moves onto Communication on the web and Android, and its own WebRTC
  glue (`ConvoHost`'s calls, `index.html`'s and `AppServices.kt`'s) goes.
- LiveKit's published xcframework again once a release includes
  webrtc-sdk/webrtc#318 (`Docs/README.md`, To do).
- The Apple backend's build and tests in CI (a macOS runner at release
  verification); Linux builds and tests on every pull request and push to
  main (.github/workflows/ci.yml).
