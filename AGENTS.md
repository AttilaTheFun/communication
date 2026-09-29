# Communication, for agents

The async, strict-concurrency Swift API over WebRTC that Convo's clients
use: `CommunicationPeerConnection` (data channels, offer/answer, ICE,
events) and the Apple backend `CommunicationWebRTC` on LiveKit's WebRTC build
(livekit/webrtc-xcframework, `LK`-prefixed classes; it has visionOS slices). It
will be open-sourced with the Convo whitepaper; keep it free of anything
that is not transport.

## Layout

`Package.swift`, `Package.resolved`, `README.md`, `AGENTS.md`, `.gitignore`
at the root and nothing else. `Sources/Communication` (the API, no WebRTC
import), `Sources/CommunicationWebRTC` (the backend), `Tests/`,
`Examples/` (small executables, not products), `Docs/`, `Tools/`.

## Rules

- Media is in scope when it is in the WebRTC or Media Capture specs (tracks,
  senders, receivers, transceivers, getUserMedia). Call semantics are not:
  those belong to the Convo Protocol package.
- The API module imports no WebRTC types; the backend imports WebRTC as
  `internal import` and converts at the boundary (`RTCConversions.swift`).
- Every public method is `async` or an actor member; events are an
  `AsyncStream`. Keep Swift 6 strict concurrency clean. The one exception is
  `CommunicationApplicationAudio`, whose render and capture calls are
  synchronous because they run on real-time audio threads.
- No Bazel in this repo. Consumers that use Bazel take it through
  rules_swift_package_manager.

## Verifying

`swift build && swift test` (the application-audio test sends a tone across
a loopback connection). `swift run DataChannelEcho` exercises a loopback
negotiation on a Mac. For the other Apple platforms:
`xcodebuild build -scheme CommunicationWebRTC -destination 'generic/platform=visionOS'`
(and `visionOS Simulator`, `iOS`, `iOS Simulator`).
