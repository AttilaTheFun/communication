# Communication, for agents

The async, strict-concurrency Swift API over WebRTC that Convo's clients
use: `CommunicationPeerConnection` (data channels, offer/answer, ICE,
events) and the Apple backend `CommunicationWebRTC` on stasel/WebRTC. It
will be open-sourced with the Convo whitepaper; keep it free of anything
that is not transport.

## Layout

`Package.swift`, `Package.resolved`, `README.md`, `AGENTS.md`, `.gitignore`
at the root and nothing else. `Sources/Communication` (the API, no WebRTC
import), `Sources/CommunicationWebRTC` (the backend), `Tests/`,
`Examples/` (small executables, not products), `Docs/`, `Tools/`.

## Rules

- No media here. Microphone, camera, playback and video views are the
  separate, private `CommunicationCalling` package, which reaches the raw
  WebRTC objects through `WebRTCPeerConnection.withUnderlying` and
  `setRemoteTrackHandler`. Do not add audio or video API to the protocol.
- The API module imports no WebRTC types; the backend imports WebRTC as
  `internal import` and converts at the boundary (`RTCConversions.swift`).
- Every public method is `async` or an actor member; events are an
  `AsyncStream`. Keep Swift 6 strict concurrency clean.
- No Bazel in this repo. Consumers that use Bazel take it through
  rules_swift_package_manager.

## Verifying

`swift build && swift test`. `swift run DataChannelEcho` exercises a
loopback negotiation on a Mac.
