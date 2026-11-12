# Communication docs

- The API surface is the `CommunicationPeerConnection` protocol
  (`Sources/Communication/CommunicationPeerConnection.swift`): data channels,
  offer/answer, ICE, events. `CommunicationConnector` makes connections.
- `CommunicationWebRTC` is the Apple backend on LiveKit's WebRTC build
  (`LiveKitWebRTC`, `LK`-prefixed classes).
- Media: the WebRTC media API (`CommunicationMedia.swift`) and, in the Apple
  backend, capture through `WebRTCMediaDevices` and Metal video views.

- Platforms: `platforms.md`, the plan for the same API on every platform Isomer
  supports (Apple, native libwebrtc for Linux, Windows and Android, the
  browser for the web).

## To do

- **Use LiveKit's published build again.** `Package.swift` takes
  LiveKitWebRTC from our fork, AttilaTheFun/webrtc-xcframework
  `150.7871.02-privacy-fix`. That's LiveKit's 150.7871.02 with the macOS and
  Mac Catalyst `PrivacyInfo.xcprivacy` moved out of a nested
  `Versions/A/Versions/A/Resources`, which breaks rules_apple's framework
  import; the binaries are unchanged. The source fix, webrtc-sdk/webrtc#318,
  merged on 2026-10-22, but LiveKit's latest release then (150.7871.03, built
  2026-10-05) predates it.
  - When livekit/webrtc-xcframework publishes a release built after
    2026-10-22, check that its macOS and Catalyst slices have
    `Versions/A/Resources/PrivacyInfo.xcprivacy` and no `Versions/A/Versions`:
    `unzip -l LiveKitWebRTC.xcframework.zip | grep PrivacyInfo`.
  - Then point the dependency back at
    `https://github.com/livekit/webrtc-xcframework` with that version, run
    `swift test`, and drop the fork.
